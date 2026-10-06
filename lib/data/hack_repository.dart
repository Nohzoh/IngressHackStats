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

  /// Glyph end screen ("HACKING BONUS / SPEED BONUS"), attached to the next hack.
  static const glyphResult = 'glyph_result';

  /// "+N AP" floating on the map, attached to the hack it follows or precedes.
  static const ap = 'ap';

  /// Same popup as the previous one, read on another frame.
  static const duplicate = 'duplicate';

  /// Matched the native pre-filter but the parser found no popup.
  static const ignored = 'ignored';

  /// Recorded in calibration mode without being recognized as a popup.
  static const raw = 'raw';
}

enum GlyphFilter {
  all,
  none,
  any,
  perfect,
  partial,
  failed;

  String get label => switch (this) {
        all => 'Tous',
        none => 'Sans glyph',
        any => 'Avec glyph',
        perfect => 'Parfait',
        partial => 'Partiel',
        failed => 'Raté',
      };
}

enum TransmuterFilter { all, plus, minus, none }

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
    this.transmuter,
    this.glyphStatus,
    this.glyphCommand,
    this.ap,
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

  /// For a hack: Ito En transmuter announced in the popup ([Transmuter]).
  final String? transmuter;

  /// For a hack: [GlyphStatus] value.
  final String? glyphStatus;
  final String? glyphCommand;
  final int? ap;
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
      version: 5,
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
            transmuter TEXT,
            glyph_hack_bonus INTEGER,
            glyph_speed_bonus INTEGER,
            glyph_command TEXT,
            ap INTEGER,
            glyph_status TEXT,
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
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE captures ADD COLUMN transmuter TEXT');
        }
        if (oldVersion < 5) {
          for (final column in [
            'glyph_hack_bonus INTEGER',
            'glyph_speed_bonus INTEGER',
            'glyph_command TEXT',
            'ap INTEGER',
            'glyph_status TEXT',
          ]) {
            await db.execute('ALTER TABLE captures ADD COLUMN $column');
          }
        }
      },
    );
    final repo = HackRepository(db);
    // Hacks stored before glyph statuses existed: compute them.
    final missing = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM captures WHERE kind = '${CaptureKind.hack}' AND glyph_status IS NULL",
    ));
    if ((missing ?? 0) > 0) await repo.reparseAll();
    return repo;
  }

  /// Columns describing what a single frame shows, besides its items.
  static Map<String, Object?> _frameColumns(ParseResult result, _Decision decision) => {
        'kind': decision.kind,
        'signature': result.isHack ? result.signature : null,
        'reject_reason': result.rejectReason,
        'portal_name': result.portalName,
        'parent_id': decision.parentId,
        'transmuter': result.transmuter,
        'glyph_hack_bonus': result.glyph?.hackBonus,
        'glyph_speed_bonus': result.glyph?.speedBonus,
        'glyph_command': result.glyph?.command,
        'ap': result.ap,
      };

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
          ..._frameColumns(result, decision),
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
      await txn.update('captures', {'glyph': 0, 'portal_level': null, 'glyph_status': null});
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
        await txn.update('captures', _frameColumns(result, decision), where: 'id = ?', whereArgs: [id]);
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
      case CaptureKind.hack: {
        linker.registerHack(id, capture.timestamp, result.signature, hasAp: result.ap != null);
        await _insertItems(txn, id, result.items);
        await _updatePortalLevel(txn, id);
        final glyph = linker.takePendingGlyph(capture.timestamp);
        if (glyph != null) {
          await txn.update(
            'captures',
            {
              'glyph_hack_bonus': glyph.result.hackBonus,
              'glyph_speed_bonus': glyph.result.speedBonus,
              'glyph_command': glyph.result.command,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          await txn.update('captures', {'parent_id': id}, where: 'id = ?', whereArgs: [glyph.captureId]);
        }
        final ap = result.ap == null ? linker.takePendingAp(capture.timestamp) : null;
        if (ap != null) await _attachAp(txn, id, ap.captureId, ap.value);
        await _updateGlyphStatus(txn, id);
        return true;
      }
      case CaptureKind.glyphResult: {
        linker.setPendingGlyph(id, capture.timestamp, result.glyph!);
        return false;
      }
      case CaptureKind.ap: {
        final parent = decision.parentId;
        if (parent != null) {
          await _attachAp(txn, parent, id, result.ap!);
          await _updateGlyphStatus(txn, parent);
        } else {
          linker.setPendingAp(id, capture.timestamp, result.ap!);
        }
        return false;
      }
      case CaptureKind.bonus: {
        final parent = decision.parentId!;
        await _insertItems(txn, parent, result.items);
        await txn.update('captures', {'glyph': 1}, where: 'id = ?', whereArgs: [parent]);
        if (result.transmuter != null) {
          // The regular popup may have been missed or misread: the bonus one
          // carries the same "ITO EN applied" line.
          await txn.rawUpdate(
            'UPDATE captures SET transmuter = COALESCE(transmuter, ?) WHERE id = ?',
            [result.transmuter, parent],
          );
        }
        await _updatePortalLevel(txn, parent);
        await _updateGlyphStatus(txn, parent);
        return false;
      }
      default: {
        return false;
      }
    }
  }

  Future<void> _attachAp(DatabaseExecutor db, int hackId, int apCaptureId, int ap) async {
    await db.update('captures', {'ap': ap}, where: 'id = ?', whereArgs: [hackId]);
    await db.update('captures', {'parent_id': hackId}, where: 'id = ?', whereArgs: [apCaptureId]);
  }

  /// Recomputes a hack's glyph status from everything attached to it.
  Future<void> _updateGlyphStatus(DatabaseExecutor db, int hackId) async {
    final rows = await db.query(
      'captures',
      columns: ['glyph', 'glyph_hack_bonus', 'glyph_speed_bonus', 'glyph_command', 'ap'],
      where: 'id = ?',
      whereArgs: [hackId],
    );
    if (rows.isEmpty) return;
    final r = rows.first;
    final hackBonus = r['glyph_hack_bonus'] as int?;
    final speedBonus = r['glyph_speed_bonus'] as int?;
    final status = GlyphStatus.compute(
      result: hackBonus == null || speedBonus == null
          ? null
          : GlyphResult(hackBonus: hackBonus, speedBonus: speedBonus),
      hasBonusPopup: r['glyph'] == 1,
      ap: r['ap'] as int?,
    );
    await db.update('captures', {'glyph_status': status}, where: 'id = ?', whereArgs: [hackId]);
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
  Future<HackStats> stats({
    GlyphFilter glyph = GlyphFilter.all,
    int? portalLevel,
    TransmuterFilter transmuter = TransmuterFilter.all,
  }) async {
    final conditions = ["c.kind = '${CaptureKind.hack}'"];
    final args = <Object>[];
    switch (glyph) {
      case GlyphFilter.all:
        break;
      case GlyphFilter.none:
        conditions.add("c.glyph_status = '${GlyphStatus.none}'");
      case GlyphFilter.any:
        conditions.add("c.glyph_status <> '${GlyphStatus.none}'");
      case GlyphFilter.perfect:
        conditions.add("c.glyph_status = '${GlyphStatus.perfect}'");
      case GlyphFilter.partial:
        conditions.add("c.glyph_status = '${GlyphStatus.partial}'");
      case GlyphFilter.failed:
        conditions.add("c.glyph_status = '${GlyphStatus.failed}'");
    }
    switch (transmuter) {
      case TransmuterFilter.all:
        break;
      case TransmuterFilter.plus:
        conditions.add("c.transmuter = '${Transmuter.plus}'");
      case TransmuterFilter.minus:
        conditions.add("c.transmuter = '${Transmuter.minus}'");
      case TransmuterFilter.none:
        conditions.add('c.transmuter IS NULL');
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
          transmuter: r['transmuter'] as String?,
          glyphStatus: r['glyph_status'] as String?,
          glyphCommand: r['glyph_command'] as String?,
          ap: r['ap'] as int?,
          rejectReason: r['reject_reason'] as String?,
          latitude: (r['lat'] as num?)?.toDouble(),
          longitude: (r['lng'] as num?)?.toDouble(),
        ),
    ];
  }

  /// Number of stored captures per kind, for diagnostics.
  Future<Map<String, int>> countByKind() async {
    final rows = await _db.rawQuery('SELECT kind, COUNT(*) AS n FROM captures GROUP BY kind');
    return {for (final r in rows) r['kind'] as String: (r['n'] as num).toInt()};
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

class _PendingGlyph {
  const _PendingGlyph(this.captureId, this.timestamp, this.result);
  final int captureId;
  final int timestamp;
  final GlyphResult result;
}

class _PendingAp {
  const _PendingAp(this.captureId, this.timestamp, this.value);
  final int captureId;
  final int timestamp;
  final int value;
}

/// Walks captures in time order: drops screens read on several frames and
/// links what belongs to one hack:
///  - the glyph end screen, shown before the popups, goes to the next hack;
///  - the "Bonus items:" popup goes to the hack shown just before it;
///  - the "+N AP" floating text goes to the closest hack in time.
class _PopupLinker {
  _PopupLinker();

  /// A screen with the same content within this delay is the same screen.
  static const duplicateWindow = Duration(seconds: 20);

  /// A bonus popup appears right after the regular one.
  static const bonusWindow = Duration(seconds: 60);

  /// Delay between the glyph end screen ("Done") and the popup.
  static const glyphWindow = Duration(seconds: 90);

  /// The AP gain floats on the map around the time of the popup.
  static const apWindow = Duration(seconds: 15);

  int? _hackId;
  int _hackTs = 0;
  String _hackSignature = '';
  bool _hackHasBonus = false;
  bool _hackHasAp = false;
  int _bonusTs = 0;
  String _bonusSignature = '';
  int _glyphTs = 0;
  String _glyphKey = '';
  int _apTs = 0;
  int? _apValue;
  _PendingGlyph? _pendingGlyph;
  _PendingAp? _pendingAp;

  /// Restores the state from the last stored hack, so a bonus popup or an AP
  /// gain drained in a later batch still finds its hack.
  static Future<_PopupLinker> resume(DatabaseExecutor db) async {
    final linker = _PopupLinker();
    final rows = await db.query(
      'captures',
      columns: ['id', 'ts', 'signature', 'glyph', 'ap'],
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
      linker._hackHasAp = r['ap'] != null;
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
    final ts = capture.timestamp;
    bool sameAsLast(int lastTs) => ts - lastTs < duplicateWindow.inMilliseconds;

    final glyph = result.glyph;
    if (glyph != null) {
      final key = '${glyph.hackBonus}/${glyph.speedBonus}/${glyph.command}';
      final duplicate = key == _glyphKey && sameAsLast(_glyphTs);
      _glyphKey = key;
      _glyphTs = ts;
      return _Decision(duplicate ? CaptureKind.duplicate : CaptureKind.glyphResult);
    }

    if (!result.isHack) {
      final ap = result.ap;
      if (ap == null) return _Decision(capture.debug ? CaptureKind.raw : CaptureKind.ignored);
      final duplicate = ap == _apValue && sameAsLast(_apTs);
      _apValue = ap;
      _apTs = ts;
      if (duplicate) return const _Decision(CaptureKind.duplicate);
      final hackId = _hackId;
      if (hackId != null && !_hackHasAp && ts - _hackTs < apWindow.inMilliseconds) {
        _hackHasAp = true;
        return _Decision(CaptureKind.ap, hackId);
      }
      return const _Decision(CaptureKind.ap);
    }

    final sig = result.signature;
    if (result.isBonusPopup) {
      final duplicate = sig == _bonusSignature && sameAsLast(_bonusTs);
      _bonusTs = ts;
      _bonusSignature = sig;
      if (duplicate) return const _Decision(CaptureKind.duplicate);
      final hackId = _hackId;
      if (hackId != null && !_hackHasBonus && ts - _hackTs < bonusWindow.inMilliseconds) {
        _hackHasBonus = true;
        return _Decision(CaptureKind.bonus, hackId);
      }
      return const _Decision(CaptureKind.orphanBonus);
    }

    if (sig == _hackSignature && sameAsLast(_hackTs)) {
      _hackTs = ts;
      return const _Decision(CaptureKind.duplicate);
    }
    return const _Decision(CaptureKind.hack);
  }

  void registerHack(int id, int ts, String signature, {required bool hasAp}) {
    _hackId = id;
    _hackTs = ts;
    _hackSignature = signature;
    _hackHasBonus = false;
    _hackHasAp = hasAp;
    _bonusSignature = '';
  }

  void setPendingGlyph(int captureId, int ts, GlyphResult result) =>
      _pendingGlyph = _PendingGlyph(captureId, ts, result);

  void setPendingAp(int captureId, int ts, int value) =>
      _pendingAp = _PendingAp(captureId, ts, value);

  /// The glyph end screen seen shortly before the hack at [ts], if any.
  _PendingGlyph? takePendingGlyph(int ts) {
    final pending = _pendingGlyph;
    _pendingGlyph = null;
    if (pending == null || ts - pending.timestamp > glyphWindow.inMilliseconds) return null;
    return pending;
  }

  /// An AP gain seen shortly before the hack at [ts], if any.
  _PendingAp? takePendingAp(int ts) {
    final pending = _pendingAp;
    _pendingAp = null;
    if (pending == null || ts - pending.timestamp > apWindow.inMilliseconds) return null;
    _hackHasAp = true;
    return pending;
  }
}
