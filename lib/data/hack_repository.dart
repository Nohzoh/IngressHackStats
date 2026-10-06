import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/ocr_capture.dart';
import '../parsing/hack_parser.dart';
import '../parsing/portal_level.dart';

/// What a stored capture turned out to be.
abstract final class CaptureKind {
  /// Result popup of a hack (titled with the portal name).
  static const hack = 'hack';

  /// "Bonus items:" popup, attached to the hack just before it.
  static const bonus = 'bonus';

  /// Bonus popup with no recent hack to attach to.
  static const orphanBonus = 'bonus_orphan';

  /// Same popup as the previous one, read on another frame.
  static const duplicate = 'duplicate';

  /// Matched the native pre-filter but the parser found no popup.
  static const ignored = 'ignored';

  /// Recorded in calibration mode without being recognized as a popup.
  static const raw = 'raw';
}

enum GlyphFilter { all, glyph, noGlyph }

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
    this.portalName,
    this.parentId,
    this.glyph = false,
    this.portalLevel,
    this.rejectReason,
    this.latitude,
    this.longitude,
  });

  final int id;
  final int timestamp;
  final String kind;
  final String rawText;

  /// For a hack: its items, bonus ones included.
  final List<String> items;
  final String? portalName;

  /// For a bonus popup: the hack it belongs to.
  final int? parentId;

  /// For a hack: a bonus popup was attached (glyph hack).
  final bool glyph;

  /// For a hack: portal level inferred from the item levels.
  final int? portalLevel;
  final String? rejectReason;
  final double? latitude;
  final double? longitude;
}

class HackRepository {
  HackRepository(this._db, {HackParser? parser}) : _parser = parser ?? HackParser();

  final Database _db;
  final HackParser _parser;

  static Future<HackRepository> open() async {
    final path = p.join(await getDatabasesPath(), 'hacks.db');
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE captures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            kind TEXT NOT NULL,
            signature TEXT,
            reject_reason TEXT,
            portal_name TEXT,
            parent_id INTEGER,
            glyph INTEGER NOT NULL DEFAULT 0,
            portal_level INTEGER,
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE captures ADD COLUMN portal_name TEXT');
          await db.execute('ALTER TABLE captures ADD COLUMN parent_id INTEGER');
          await db.execute('ALTER TABLE captures ADD COLUMN glyph INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE captures ADD COLUMN portal_level INTEGER');
        }
      },
    );
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
      final linker = await _PopupLinker.resume(txn);
      for (final capture in captures) {
        final result = _parser.parse(capture.lines, screenHeight: capture.screenHeight);
        final decision = linker.classify(capture, result);
        final id = await txn.insert('captures', {
          'ts': capture.timestamp,
          'kind': decision.kind,
          'signature': result.isHack ? result.signature : null,
          'reject_reason': result.rejectReason,
          'portal_name': result.portalName,
          'parent_id': decision.parentId,
          'raw_text': capture.rawText,
          'lines_json': jsonEncode(capture.lines.map((l) => l.toJson()).toList()),
          'screen_w': capture.screenWidth,
          'screen_h': capture.screenHeight,
          'lat': capture.latitude,
          'lng': capture.longitude,
          'accuracy': capture.accuracy,
          'debug': capture.debug ? 1 : 0,
        });
        if (await _apply(txn, id, capture, result, decision, linker)) newHacks++;
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
      await txn.update('captures', {'glyph': 0, 'portal_level': null});
      final rows = await txn.query('captures', orderBy: 'ts ASC, id ASC');
      final linker = _PopupLinker();
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
        final decision = linker.classify(capture, result);
        final id = row['id'] as int;
        await txn.update(
          'captures',
          {
            'kind': decision.kind,
            'signature': result.isHack ? result.signature : null,
            'reject_reason': result.rejectReason,
            'portal_name': result.portalName,
            'parent_id': decision.parentId,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        if (await _apply(txn, id, capture, result, decision, linker)) hacks++;
      }
    });
    return hacks;
  }

  /// Stores the items of a hack or bonus popup. Returns true for a new hack.
  Future<bool> _apply(
    Transaction txn,
    int id,
    OcrCapture capture,
    ParseResult result,
    _Decision decision,
    _PopupLinker linker,
  ) async {
    switch (decision.kind) {
      case CaptureKind.hack:
        linker.registerHack(id, capture.timestamp, result.signature);
        await _insertItems(txn, id, result.items);
        await _updatePortalLevel(txn, id);
        return true;
      case CaptureKind.bonus:
        final parent = decision.parentId!;
        await _insertItems(txn, parent, result.items);
        await txn.update('captures', {'glyph': 1}, where: 'id = ?', whereArgs: [parent]);
        await _updatePortalLevel(txn, parent);
        return false;
      default:
        return false;
    }
  }

  /// Recomputes a hack's inferred portal level from all its items.
  Future<void> _updatePortalLevel(DatabaseExecutor db, int hackId) async {
    final rows = await db.rawQuery(
      'SELECT level, SUM(quantity) AS n FROM hack_items '
      'WHERE capture_id = ? AND level IS NOT NULL GROUP BY level',
      [hackId],
    );
    final counts = {for (final r in rows) r['level'] as int: (r['n'] as num).toInt()};
    await db.update(
      'captures',
      {'portal_level': inferPortalLevel(counts, seed: hackId)},
      where: 'id = ?',
      whereArgs: [hackId],
    );
  }

  /// [portalLevel]: inferred portal level, null for all.
  Future<HackStats> stats({GlyphFilter glyph = GlyphFilter.all, int? portalLevel}) async {
    final conditions = ["c.kind = '${CaptureKind.hack}'"];
    final args = <Object>[];
    switch (glyph) {
      case GlyphFilter.all:
        break;
      case GlyphFilter.glyph:
        conditions.add('c.glyph = 1');
      case GlyphFilter.noGlyph:
        conditions.add('c.glyph = 0');
    }
    if (portalLevel != null) {
      conditions.add('c.portal_level = ?');
      args.add(portalLevel);
    }
    final where = conditions.join(' AND ');
    final hacks = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM captures c WHERE $where', args),
        ) ??
        0;
    final rows = await _db.rawQuery('''
      SELECT i.item, i.level, i.rarity,
             SUM(i.quantity) AS total,
             SUM(CASE WHEN i.bonus = 1 THEN i.quantity ELSE 0 END) AS bonus_total,
             COUNT(DISTINCT i.capture_id) AS hacks_with
      FROM hack_items i
      JOIN captures c ON c.id = i.capture_id
      WHERE $where
      GROUP BY i.item, i.level, i.rarity
      ORDER BY total DESC''', args);
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
    final rows = await _db.query('captures', orderBy: 'ts DESC, id DESC', limit: limit);
    final itemRows = await _db.rawQuery('''
      SELECT capture_id, item, level, rarity, quantity, bonus FROM hack_items
      WHERE capture_id IN (SELECT id FROM captures ORDER BY ts DESC, id DESC LIMIT ?)
      ORDER BY bonus, id''', [limit]);
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
          portalName: r['portal_name'] as String?,
          parentId: r['parent_id'] as int?,
          glyph: r['glyph'] == 1,
          portalLevel: r['portal_level'] as int?,
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

class _Decision {
  const _Decision(this.kind, [this.parentId]);
  final String kind;
  final int? parentId;
}

/// Walks captures in time order: drops popups read on several frames and
/// attaches each "Bonus items:" popup to the hack shown just before it.
class _PopupLinker {
  _PopupLinker();

  /// A popup with the same content within this delay is the same popup.
  static const duplicateWindow = Duration(seconds: 20);

  /// A bonus popup appears right after the regular one.
  static const bonusWindow = Duration(seconds: 60);

  int? _hackId;
  int _hackTs = 0;
  String _hackSignature = '';
  bool _hackHasBonus = false;
  int _bonusTs = 0;
  String _bonusSignature = '';

  /// Restores the state from the last stored hack, so a bonus popup drained
  /// in a later batch still finds its hack.
  static Future<_PopupLinker> resume(DatabaseExecutor db) async {
    final linker = _PopupLinker();
    final rows = await db.query(
      'captures',
      columns: ['id', 'ts', 'signature', 'glyph'],
      where: 'kind = ?',
      whereArgs: [CaptureKind.hack],
      orderBy: 'ts DESC, id DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final r = rows.first;
      linker._hackId = r['id'] as int;
      linker._hackTs = r['ts'] as int;
      linker._hackSignature = r['signature'] as String? ?? '';
      linker._hackHasBonus = r['glyph'] == 1;
    }
    final lastSeen = await db.query(
      'captures',
      columns: ['ts', 'signature'],
      where: 'kind IN (?, ?, ?)',
      whereArgs: [CaptureKind.hack, CaptureKind.duplicate, CaptureKind.bonus],
      orderBy: 'ts DESC, id DESC',
      limit: 20,
    );
    for (final r in lastSeen.reversed) {
      final sig = r['signature'] as String? ?? '';
      final ts = r['ts'] as int;
      if (sig.startsWith('BONUS#')) {
        linker._bonusTs = ts;
        linker._bonusSignature = sig;
      } else if (sig == linker._hackSignature) {
        linker._hackTs = ts;
      }
    }
    return linker;
  }

  _Decision classify(OcrCapture capture, ParseResult result) {
    if (!result.isHack) {
      return _Decision(capture.debug ? CaptureKind.raw : CaptureKind.ignored);
    }
    final ts = capture.timestamp;
    final sig = result.signature;

    if (result.isBonusPopup) {
      if (sig == _bonusSignature && ts - _bonusTs < duplicateWindow.inMilliseconds) {
        _bonusTs = ts;
        return const _Decision(CaptureKind.duplicate);
      }
      _bonusTs = ts;
      _bonusSignature = sig;
      final hackId = _hackId;
      if (hackId != null && !_hackHasBonus && ts - _hackTs < bonusWindow.inMilliseconds) {
        _hackHasBonus = true;
        return _Decision(CaptureKind.bonus, hackId);
      }
      return const _Decision(CaptureKind.orphanBonus);
    }

    if (sig == _hackSignature && ts - _hackTs < duplicateWindow.inMilliseconds) {
      _hackTs = ts;
      return const _Decision(CaptureKind.duplicate);
    }
    return const _Decision(CaptureKind.hack);
  }

  void registerHack(int id, int ts, String signature) {
    _hackId = id;
    _hackTs = ts;
    _hackSignature = signature;
    _hackHasBonus = false;
    _bonusSignature = '';
  }
}
