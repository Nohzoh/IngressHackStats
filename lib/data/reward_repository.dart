import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/ocr_capture.dart';
import '../parsing/hack_parser.dart';
import '../parsing/portal_level.dart';
import 'popup_linker.dart';
import '../stats/reward_stats.dart';

/// What a stored frame turned out to be.
abstract final class CaptureKind {
  /// A reward popup: regular (titled with the portal name) or glyph bonus
  /// ("Bonus items:"), see the `bonus` column.
  static const reward = 'reward';

  /// Glyph end screen ("HACKING BONUS / SPEED BONUS"), linked to the bonus
  /// reward that follows it.
  static const glyphResult = 'glyph_result';

  /// "+N AP" floating on the map.
  static const ap = 'ap';

  /// Same screen as the previous one, read on another frame.
  static const duplicate = 'duplicate';

  /// Matched the native pre-filter but nothing useful was recognized.
  static const ignored = 'ignored';

  /// Recorded in calibration mode without being recognized.
  static const raw = 'raw';
}

/// Which rewards the stats are computed on.
enum RewardType {
  regular,
  bonus,
  all,

  /// Computed: one regular + one bonus reward, as a player doing a glyph
  /// hack receives them.
  glyphHack;

  String get label => switch (this) {
        regular => 'Normale',
        bonus => 'Bonus glyph',
        all => 'Toutes',
        glyphHack => 'Hack + glyph',
      };
}

enum TransmuterFilter { all, plus, minus, none }

/// Quality of the glyph sequence, for bonus rewards.
enum GlyphFilter {
  all,
  perfect,
  partial,
  failed,
  unknown;

  String get label => switch (this) {
        all => 'Tous',
        perfect => 'Parfait',
        partial => 'Partiel',
        failed => 'Raté',
        unknown => 'Inconnu',
      };

  String? get status => switch (this) {
        all => null,
        perfect => GlyphStatus.perfect,
        partial => GlyphStatus.partial,
        failed => GlyphStatus.failed,
        unknown => GlyphStatus.unknown,
      };
}

class RewardFilter {
  const RewardFilter({
    this.type = RewardType.regular,
    this.portalLevel,
    this.transmuter = TransmuterFilter.all,
    this.glyph = GlyphFilter.all,
  });

  final RewardType type;

  /// Inferred portal level, null for all.
  final int? portalLevel;
  final TransmuterFilter transmuter;

  /// Only applies to bonus rewards.
  final GlyphFilter glyph;

  bool get usesGlyph => type == RewardType.bonus || type == RewardType.glyphHack;
}

class CaptureRow {
  const CaptureRow({
    required this.id,
    required this.timestamp,
    required this.kind,
    required this.rawText,
    required this.items,
    this.bonus = false,
    this.portalName,
    this.portalLevel,
    this.transmuter,
    this.glyphStatus,
    this.glyphCommand,
    this.glyphHackBonus,
    this.glyphSpeedBonus,
    this.ap,
    this.parentId,
    this.rejectReason,
    this.latitude,
    this.longitude,
  });

  final int id;
  final int timestamp;
  final String kind;
  final String rawText;

  /// For a reward: its items.
  final List<String> items;

  /// For a reward: glyph bonus reward.
  final bool bonus;
  final String? portalName;

  /// For a reward: portal level inferred from its item levels.
  final int? portalLevel;

  /// For a reward: Ito En announced in the popup ([Transmuter]).
  final String? transmuter;

  /// For a bonus reward: [GlyphStatus] value.
  final String? glyphStatus;
  final String? glyphCommand;
  final int? glyphHackBonus;
  final int? glyphSpeedBonus;
  final int? ap;

  /// For a glyph end screen: the bonus reward it was linked to.
  final int? parentId;
  final String? rejectReason;
  final double? latitude;
  final double? longitude;
}

class RewardRepository {
  RewardRepository(this._db, {HackParser? parser}) : _parser = parser ?? HackParser();

  final Database _db;
  final HackParser _parser;

  static const _schemaVersion = 7;

  static Future<RewardRepository> open() async {
    final path = p.join(await getDatabasesPath(), 'hacks.db');
    var needsReparse = false;
    final db = await openDatabase(
      path,
      version: _schemaVersion,
      onCreate: (db, version) => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 6) {
          await _migrateToRewards(db);
        } else if (oldVersion < 7) {
          await db.execute('ALTER TABLE captures ADD COLUMN read_score INTEGER');
        }
        // Linking rules changed with each version: rebuild from raw frames.
        needsReparse = true;
      },
    );
    final repo = RewardRepository(db);
    if (needsReparse) await repo.reparseAll();
    return repo;
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE captures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        bonus INTEGER NOT NULL DEFAULT 0,
        signature TEXT,
        reject_reason TEXT,
        portal_name TEXT,
        portal_level INTEGER,
        transmuter TEXT,
        glyph_hack_bonus INTEGER,
        glyph_speed_bonus INTEGER,
        glyph_command TEXT,
        glyph_status TEXT,
        ap INTEGER,
        parent_id INTEGER,
        read_score INTEGER,
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
      CREATE TABLE reward_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        capture_id INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
        item TEXT NOT NULL,
        level INTEGER,
        rarity TEXT,
        quantity INTEGER NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_captures_ts ON captures(ts)');
    await db.execute('CREATE INDEX idx_captures_kind ON captures(kind, bonus)');
    await db.execute('CREATE INDEX idx_items_capture ON reward_items(capture_id)');
  }

  /// From the hack-based schema: keep the raw frames, rebuild the rest.
  static Future<void> _migrateToRewards(Database db) async {
    await db.execute('ALTER TABLE captures RENAME TO captures_old');
    await db.execute('DROP INDEX IF EXISTS idx_captures_ts');
    await db.execute('DROP INDEX IF EXISTS idx_items_capture');
    await db.execute('DROP TABLE IF EXISTS hack_items');
    await _createSchema(db);
    await db.execute('''
      INSERT INTO captures (ts, kind, raw_text, lines_json, screen_w, screen_h, lat, lng, accuracy, debug)
      SELECT ts, '${CaptureKind.ignored}', raw_text, lines_json, screen_w, screen_h, lat, lng, accuracy, debug
      FROM captures_old ORDER BY ts, id''');
    await db.execute('DROP TABLE captures_old');
  }

  /// Stores the JSON captures drained from the native service.
  /// Returns the number of new rewards.
  Future<int> ingest(List<String> jsonLines) async {
    final captures = jsonLines.map(_decode).whereType<OcrCapture>().toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (captures.isEmpty) return 0;

    var newRewards = 0;
    await _db.transaction((txn) async {
      final linker = await _resumeLinker(txn);
      for (final capture in captures) {
        final result = _parser.parse(capture.lines, screenHeight: capture.screenHeight);
        final decision = linker.classify(timestamp: capture.timestamp, result: result, debug: capture.debug);
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
        if (await _apply(txn, id, capture, result, decision, linker)) newRewards++;
      }
    });
    return newRewards;
  }

  /// Runs the current parser again on every stored frame. Use after
  /// improving the parser or the item catalog.
  Future<int> reparseAll() async {
    var rewards = 0;
    await _db.transaction((txn) async {
      await txn.delete('reward_items');
      final rows = await txn.query(
        'captures',
        columns: ['id', 'ts', 'lines_json', 'screen_h', 'debug'],
        orderBy: 'ts ASC, id ASC',
      );
      final linker = PopupLinker();
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
        final decision = linker.classify(timestamp: capture.timestamp, result: result, debug: capture.debug);
        final id = row['id'] as int;
        await txn.update(
          'captures',
          {
            ..._frameColumns(result, decision),
            // Derived from links, recomputed by _apply.
            'portal_level': null,
            'glyph_status': null,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        if (await _apply(txn, id, capture, result, decision, linker)) rewards++;
      }
    });
    return rewards;
  }

  /// What a single frame shows, independently of the frames around it.
  static Map<String, Object?> _frameColumns(ParseResult result, LinkDecision decision) => {
        'kind': decision.kind,
        'parent_id': decision.target,
        'read_score': result.isHack ? PopupLinker.readScore(result) : null,
        'bonus': result.isBonusPopup ? 1 : 0,
        'signature': result.isHack ? result.signature : null,
        'reject_reason': result.rejectReason,
        'portal_name': result.portalName,
        'transmuter': result.transmuter,
        'glyph_hack_bonus': result.glyph?.hackBonus,
        'glyph_speed_bonus': result.glyph?.speedBonus,
        'glyph_command': result.glyph?.command,
        'ap': result.ap,
      };

  /// Stores a reward's items and links. Returns true for a new reward.
  Future<bool> _apply(
    Transaction txn,
    int id,
    OcrCapture capture,
    ParseResult result,
    LinkDecision decision,
    PopupLinker linker,
  ) async {
    switch (decision.kind) {
      case CaptureKind.glyphResult:
        linker.glyphStored(id, capture.timestamp, result.glyph!);
        return false;
      case CaptureKind.reward:
        linker.rewardStored(id, capture.timestamp, result);
        await _insertItems(txn, id, result.items);
        final columns = <String, Object?>{
          'portal_level': inferPortalLevel(_levelCounts(result.items), seed: id),
        };
        if (result.isBonusPopup) {
          final glyph = linker.takePendingGlyph(capture.timestamp);
          columns['glyph_status'] = GlyphStatus.compute(glyph?.result);
          if (glyph != null) {
            columns['glyph_hack_bonus'] = glyph.result.hackBonus;
            columns['glyph_speed_bonus'] = glyph.result.speedBonus;
            columns['glyph_command'] = glyph.result.command;
            await txn.update('captures', {'parent_id': id}, where: 'id = ?', whereArgs: [glyph.captureId]);
          }
        }
        await txn.update('captures', columns, where: 'id = ?', whereArgs: [id]);
        return true;
      case CaptureKind.duplicate:
        final target = decision.target;
        if (target != null && decision.replace) await _replaceReading(txn, target, result);
        return false;
      default:
        return false;
    }
  }

  /// A better reading of reward [target] was found: keep its items instead.
  Future<void> _replaceReading(Transaction txn, int target, ParseResult result) async {
    await txn.delete('reward_items', where: 'capture_id = ?', whereArgs: [target]);
    await _insertItems(txn, target, result.items);
    await txn.rawUpdate(
      'UPDATE captures SET signature = ?, read_score = ?, portal_level = ?, '
      'portal_name = COALESCE(?, portal_name), transmuter = COALESCE(?, transmuter) WHERE id = ?',
      [
        result.signature,
        PopupLinker.readScore(result),
        inferPortalLevel(_levelCounts(result.items), seed: target),
        result.portalName,
        result.transmuter,
        target,
      ],
    );
  }

  /// Linker state rebuilt from the last stored frames, so a batch drained
  /// later still matches the popups of the previous batch.
  static Future<PopupLinker> _resumeLinker(DatabaseExecutor db) async {
    final linker = PopupLinker();
    final rows = await db.query(
      'captures',
      columns: [
        'id', 'ts', 'kind', 'bonus', 'portal_name', 'read_score', 'parent_id', 'ap',
        'glyph_hack_bonus', 'glyph_speed_bonus', 'glyph_command',
      ],
      where: 'kind IN (?, ?, ?, ?)',
      whereArgs: [CaptureKind.reward, CaptureKind.duplicate, CaptureKind.glyphResult, CaptureKind.ap],
      orderBy: 'ts DESC, id DESC',
      limit: 60,
    );
    for (final r in rows.reversed) {
      final id = r['id'] as int;
      final ts = r['ts'] as int;
      switch (r['kind']) {
        case CaptureKind.reward:
          linker.restoreReward(
            id,
            ts,
            bonus: r['bonus'] == 1,
            portalName: r['portal_name'] as String?,
            score: r['read_score'] as int? ?? 0,
          );
        case CaptureKind.duplicate:
          final parent = r['parent_id'] as int?;
          if (parent != null) linker.restoreDuplicate(parent, ts);
        case CaptureKind.glyphResult:
          linker.restoreGlyph(
            id,
            ts,
            GlyphResult(
              hackBonus: r['glyph_hack_bonus'] as int,
              speedBonus: r['glyph_speed_bonus'] as int,
              command: r['glyph_command'] as String?,
            ),
            linked: r['parent_id'] != null,
          );
        case CaptureKind.ap:
          final ap = r['ap'] as int?;
          if (ap != null) linker.restoreAp(ap, ts);
      }
    }
    return linker;
  }

  static Map<int, int> _levelCounts(List<ParsedItem> items) {
    final counts = <int, int>{};
    for (final item in items) {
      final level = item.level;
      if (level != null) counts[level] = (counts[level] ?? 0) + item.quantity;
    }
    return counts;
  }

  // ------------------------------------------------------------------ stats

  Future<RewardStats> stats(RewardFilter filter) async {
    switch (filter.type) {
      case RewardType.regular:
        final c = await _counts(filter, bonus: false);
        return RewardStats.fromCounts(c.$1, c.$2);
      case RewardType.bonus:
        final c = await _counts(filter, bonus: true);
        return RewardStats.fromCounts(c.$1, c.$2);
      case RewardType.all:
        final c = await _counts(filter, bonus: null);
        return RewardStats.fromCounts(c.$1, c.$2);
      case RewardType.glyphHack:
        final regular = await _counts(filter, bonus: false);
        final bonus = await _counts(filter, bonus: true);
        return RewardStats.glyphHack(
          regularRewards: regular.$1,
          regular: regular.$2,
          bonusRewards: bonus.$1,
          bonus: bonus.$2,
        );
    }
  }

  /// Number of matching rewards and their item counts. [bonus]: null for both.
  Future<(int, List<ItemCount>)> _counts(RewardFilter filter, {required bool? bonus}) async {
    final conditions = ["c.kind = '${CaptureKind.reward}'"];
    final args = <Object>[];
    if (bonus != null) conditions.add('c.bonus = ${bonus ? 1 : 0}');
    switch (filter.transmuter) {
      case TransmuterFilter.all:
        break;
      case TransmuterFilter.plus:
        conditions.add("c.transmuter = '${Transmuter.plus}'");
      case TransmuterFilter.minus:
        conditions.add("c.transmuter = '${Transmuter.minus}'");
      case TransmuterFilter.none:
        conditions.add('c.transmuter IS NULL');
    }
    if (filter.portalLevel != null) {
      conditions.add('c.portal_level = ?');
      args.add(filter.portalLevel!);
    }
    final glyphStatus = filter.glyph.status;
    if (glyphStatus != null && bonus != false) {
      // Regular rewards have no glyph status: keep them when mixing types.
      conditions.add(bonus == true ? 'c.glyph_status = ?' : '(c.bonus = 0 OR c.glyph_status = ?)');
      args.add(glyphStatus);
    }
    final where = conditions.join(' AND ');

    final rewards = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM captures c WHERE $where', args),
        ) ??
        0;
    final rows = await _db.rawQuery('''
      SELECT i.item, i.level, i.rarity,
             COUNT(DISTINCT i.capture_id) AS rewards_with,
             SUM(i.quantity) AS quantity
      FROM reward_items i
      JOIN captures c ON c.id = i.capture_id
      WHERE $where
      GROUP BY i.item, i.level, i.rarity''', args);
    return (
      rewards,
      [
        for (final r in rows)
          ItemCount(
            item: r['item'] as String,
            level: r['level'] as int?,
            rarity: r['rarity'] as String?,
            rewardsWith: (r['rewards_with'] as num).toInt(),
            quantity: (r['quantity'] as num).toInt(),
          ),
      ],
    );
  }

  // ------------------------------------------------------------- captures

  Future<List<CaptureRow>> recentCaptures({int limit = 200}) async {
    final rows = await _db.query('captures', orderBy: 'ts DESC, id DESC', limit: limit);
    final itemRows = await _db.rawQuery('''
      SELECT capture_id, item, level, rarity, quantity FROM reward_items
      WHERE capture_id IN (SELECT id FROM captures ORDER BY ts DESC, id DESC LIMIT ?)
      ORDER BY id''', [limit]);
    final itemsByCapture = <int, List<String>>{};
    for (final r in itemRows) {
      final item = ParsedItem(
        item: r['item'] as String,
        level: r['level'] as int?,
        rarity: r['rarity'] as String?,
        quantity: r['quantity'] as int,
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
          bonus: r['bonus'] == 1,
          portalName: r['portal_name'] as String?,
          portalLevel: r['portal_level'] as int?,
          transmuter: r['transmuter'] as String?,
          glyphStatus: r['glyph_status'] as String?,
          glyphCommand: r['glyph_command'] as String?,
          glyphHackBonus: r['glyph_hack_bonus'] as int?,
          glyphSpeedBonus: r['glyph_speed_bonus'] as int?,
          ap: r['ap'] as int?,
          parentId: r['parent_id'] as int?,
          rejectReason: r['reject_reason'] as String?,
          latitude: (r['lat'] as num?)?.toDouble(),
          longitude: (r['lng'] as num?)?.toDouble(),
        ),
    ];
  }

  /// Number of stored frames per kind, for diagnostics.
  Future<Map<String, int>> countByKind() async {
    final rows = await _db.rawQuery(
      "SELECT CASE WHEN kind = '${CaptureKind.reward}' AND bonus = 1 THEN 'bonus' ELSE kind END AS k, "
      'COUNT(*) AS n FROM captures GROUP BY k',
    );
    return {for (final r in rows) r['k'] as String: (r['n'] as num).toInt()};
  }

  Future<void> deleteAll() async {
    await _db.transaction((txn) async {
      await txn.delete('reward_items');
      await txn.delete('captures');
    });
  }

  Future<void> _insertItems(DatabaseExecutor db, int captureId, List<ParsedItem> items) async {
    for (final item in items) {
      await db.insert('reward_items', {
        'capture_id': captureId,
        'item': item.item,
        'level': item.level,
        'rarity': item.rarity,
        'quantity': item.quantity,
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
