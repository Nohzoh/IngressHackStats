import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/ocr_capture.dart';
import '../parsing/hack_parser.dart';

/// What a stored capture turned out to be.
abstract final class CaptureKind {
  static const hack = 'hack';

  /// Same loot as the previous hack within [HackRepository.duplicateWindow].
  static const duplicate = 'duplicate';

  /// Matched the native pre-filter but the parser found no hack.
  static const ignored = 'ignored';

  /// Recorded in debug mode without being recognized as a hack.
  static const raw = 'raw';
}

class ItemStat {
  const ItemStat({
    required this.item,
    this.level,
    this.rarity,
    required this.total,
    required this.bonusTotal,
    required this.hacksWith,
  });

  final String item;
  final int? level;
  final String? rarity;
  final int total;
  final int bonusTotal;

  /// Number of hacks that yielded at least one of this item.
  final int hacksWith;
}

class HackStats {
  const HackStats({required this.hacks, required this.items});

  final int hacks;
  final List<ItemStat> items;

  int get totalItems => items.fold(0, (sum, s) => sum + s.total);
  double get itemsPerHack => hacks == 0 ? 0 : totalItems / hacks;
}

class CaptureRow {
  const CaptureRow({
    required this.id,
    required this.timestamp,
    required this.kind,
    required this.rawText,
    required this.items,
    this.rejectReason,
    this.latitude,
    this.longitude,
  });

  final int id;
  final int timestamp;
  final String kind;
  final String rawText;
  final List<String> items;
  final String? rejectReason;
  final double? latitude;
  final double? longitude;
}

class HackRepository {
  HackRepository(this._db, {HackParser? parser}) : _parser = parser ?? HackParser();

  final Database _db;
  final HackParser _parser;

  static const duplicateWindow = Duration(seconds: 20);

  static Future<HackRepository> open() async {
    final path = p.join(await getDatabasesPath(), 'hacks.db');
    final db = await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE captures (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL,
          kind TEXT NOT NULL,
          signature TEXT,
          reject_reason TEXT,
          raw_text TEXT NOT NULL,
          lines_json TEXT NOT NULL,
          screen_w REAL,
          screen_h REAL,
          lat REAL,
          lng REAL,
          accuracy REAL,
          debug INTEGER NOT NULL DEFAULT 0
        )''');
      await db.execute('''
        CREATE TABLE hack_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          capture_id INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
          item TEXT NOT NULL,
          level INTEGER,
          rarity TEXT,
          quantity INTEGER NOT NULL,
          bonus INTEGER NOT NULL DEFAULT 0
        )''');
      await db.execute('CREATE INDEX idx_captures_ts ON captures(ts)');
      await db.execute('CREATE INDEX idx_items_capture ON hack_items(capture_id)');
    });
    return HackRepository(db);
  }

  /// Stores the JSON captures drained from the native service.
  /// Returns the number of new hacks.
  Future<int> ingest(List<String> jsonLines) async {
    final captures = jsonLines.map(_decode).whereType<OcrCapture>().toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (captures.isEmpty) return 0;

    var newHacks = 0;
    await _db.transaction((txn) async {
      var previous = await _lastHack(txn);
      for (final capture in captures) {
        final result = _parser.parse(capture.lines, screenHeight: capture.screenHeight);
        final kind = _classify(capture, result, previous);
        final id = await txn.insert('captures', {
          'ts': capture.timestamp,
          'kind': kind,
          'signature': result.isHack ? result.signature : null,
          'reject_reason': result.rejectReason,
          'raw_text': capture.rawText,
          'lines_json': jsonEncode(capture.lines.map((l) => l.toJson()).toList()),
          'screen_w': capture.screenWidth,
          'screen_h': capture.screenHeight,
          'lat': capture.latitude,
          'lng': capture.longitude,
          'accuracy': capture.accuracy,
          'debug': capture.debug ? 1 : 0,
        });
        if (kind == CaptureKind.hack || kind == CaptureKind.duplicate) {
          previous = _HackRef(capture.timestamp, result.signature);
        }
        if (kind == CaptureKind.hack) {
          await _insertItems(txn, id, result.items);
          newHacks++;
        }
      }
    });
    return newHacks;
  }

  /// Runs the current parser again on every stored capture. Use after
  /// improving the parser or the item catalog.
  Future<int> reparseAll() async {
    var hacks = 0;
    await _db.transaction((txn) async {
      await txn.delete('hack_items');
      final rows = await txn.query('captures', orderBy: 'ts ASC');
      _HackRef? previous;
      for (final row in rows) {
        final lines = (jsonDecode(row['lines_json'] as String) as List<dynamic>)
            .map((e) => OcrLine.fromJson(e as Map<String, dynamic>))
            .toList();
        final capture = OcrCapture(
          timestamp: row['ts'] as int,
          lines: lines,
          screenHeight: (row['screen_h'] as num?)?.toDouble() ?? 0,
          debug: row['debug'] == 1,
        );
        final result = _parser.parse(lines, screenHeight: capture.screenHeight);
        final kind = _classify(capture, result, previous);
        await txn.update(
          'captures',
          {
            'kind': kind,
            'signature': result.isHack ? result.signature : null,
            'reject_reason': result.rejectReason,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        if (kind == CaptureKind.hack || kind == CaptureKind.duplicate) {
          previous = _HackRef(capture.timestamp, result.signature);
        }
        if (kind == CaptureKind.hack) {
          await _insertItems(txn, row['id'] as int, result.items);
          hacks++;
        }
      }
    });
    return hacks;
  }

  Future<HackStats> stats() async {
    final hacks = Sqflite.firstIntValue(await _db.rawQuery(
          "SELECT COUNT(*) FROM captures WHERE kind = '${CaptureKind.hack}'",
        )) ??
        0;
    final rows = await _db.rawQuery('''
      SELECT i.item, i.level, i.rarity,
             SUM(i.quantity) AS total,
             SUM(CASE WHEN i.bonus = 1 THEN i.quantity ELSE 0 END) AS bonus_total,
             COUNT(DISTINCT i.capture_id) AS hacks_with
      FROM hack_items i
      JOIN captures c ON c.id = i.capture_id
      WHERE c.kind = '${CaptureKind.hack}'
      GROUP BY i.item, i.level, i.rarity
      ORDER BY total DESC''');
    return HackStats(
      hacks: hacks,
      items: [
        for (final r in rows)
          ItemStat(
            item: r['item'] as String,
            level: r['level'] as int?,
            rarity: r['rarity'] as String?,
            total: (r['total'] as num).toInt(),
            bonusTotal: (r['bonus_total'] as num).toInt(),
            hacksWith: (r['hacks_with'] as num).toInt(),
          ),
      ],
    );
  }

  Future<List<CaptureRow>> recentCaptures({int limit = 200}) async {
    final rows = await _db.query('captures', orderBy: 'ts DESC', limit: limit);
    final itemRows = await _db.rawQuery('''
      SELECT capture_id, item, level, rarity, quantity, bonus FROM hack_items
      WHERE capture_id IN (SELECT id FROM captures ORDER BY ts DESC LIMIT ?)''', [limit]);
    final itemsByCapture = <int, List<String>>{};
    for (final r in itemRows) {
      final item = ParsedItem(
        item: r['item'] as String,
        level: r['level'] as int?,
        rarity: r['rarity'] as String?,
        quantity: r['quantity'] as int,
        bonus: r['bonus'] == 1,
      );
      itemsByCapture.putIfAbsent(r['capture_id'] as int, () => []).add(item.toString());
    }
    return [
      for (final r in rows)
        CaptureRow(
          id: r['id'] as int,
          timestamp: r['ts'] as int,
          kind: r['kind'] as String,
          rawText: r['raw_text'] as String,
          items: itemsByCapture[r['id'] as int] ?? const [],
          rejectReason: r['reject_reason'] as String?,
          latitude: (r['lat'] as num?)?.toDouble(),
          longitude: (r['lng'] as num?)?.toDouble(),
        ),
    ];
  }

  Future<void> deleteAll() async {
    await _db.transaction((txn) async {
      await txn.delete('hack_items');
      await txn.delete('captures');
    });
  }

  // ------------------------------------------------------------------ helpers

  String _classify(OcrCapture capture, ParseResult result, _HackRef? previous) {
    if (!result.isHack) return capture.debug ? CaptureKind.raw : CaptureKind.ignored;
    if (previous != null &&
        previous.signature == result.signature &&
        capture.timestamp - previous.timestamp < duplicateWindow.inMilliseconds) {
      return CaptureKind.duplicate;
    }
    return CaptureKind.hack;
  }

  Future<_HackRef?> _lastHack(DatabaseExecutor db) async {
    final rows = await db.query(
      'captures',
      columns: ['ts', 'signature'],
      where: 'kind IN (?, ?)',
      whereArgs: [CaptureKind.hack, CaptureKind.duplicate],
      orderBy: 'ts DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _HackRef(rows.first['ts'] as int, rows.first['signature'] as String? ?? '');
  }

  Future<void> _insertItems(DatabaseExecutor db, int captureId, List<ParsedItem> items) async {
    for (final item in items) {
      await db.insert('hack_items', {
        'capture_id': captureId,
        'item': item.item,
        'level': item.level,
        'rarity': item.rarity,
        'quantity': item.quantity,
        'bonus': item.bonus ? 1 : 0,
      });
    }
  }

  static OcrCapture? _decode(String line) {
    try {
      return OcrCapture.fromJson(jsonDecode(line) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

class _HackRef {
  const _HackRef(this.timestamp, this.signature);
  final int timestamp;
  final String signature;
}
