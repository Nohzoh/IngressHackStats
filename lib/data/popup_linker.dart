import '../parsing/hack_parser.dart';

/// What a frame is, once compared with the frames before it.
class LinkDecision {
  const LinkDecision(this.kind, {this.target, this.replace = false});

  /// One of the CaptureKind values.
  final String kind;

  /// For a duplicate: the reward (or screen) it is another reading of.
  final int? target;

  /// For a duplicate reward: this reading is more complete than the stored
  /// one and should replace its items.
  final bool replace;
}

class _RewardRef {
  _RewardRef(this.id, this.lastTs, this.nameKey, this.score);
  final int id;
  int lastTs;
  String nameKey;
  int score;
}

class PendingGlyph {
  const PendingGlyph(this.captureId, this.timestamp, this.result);
  final int captureId;
  final int timestamp;
  final GlyphResult result;
}

/// Walks frames in time order and decides which ones are new screens.
///
/// A popup stays on screen for a few seconds and is read on many frames,
/// and OCR does not read it identically every time (a missed "L8" changes
/// the content). So a reward is recognised by its context, not by its exact
/// content:
///  - regular reward: same portal name as the previous one, read again
///    within [regularWindow];
///  - bonus reward: no new regular reward nor glyph end screen since the
///    previous bonus, read again within [bonusWindow].
/// Among several readings of one popup, the most complete one is kept.
///
/// It also links each glyph end screen to the bonus reward that follows it.
class PopupLinker {
  /// Same portal within this delay of its last reading: same popup. A
  /// portal cannot be hacked again that fast (cooldown of 3 to 5 minutes).
  static const regularWindow = Duration(seconds: 60);

  /// A new bonus needs a new glyph sequence, which takes longer than this.
  static const bonusWindow = Duration(seconds: 30);

  /// When one reading has no portal name, only very close readings match.
  static const unnamedWindow = Duration(seconds: 10);

  /// Glyph end screens and AP gains with the same content within this delay.
  static const duplicateWindow = Duration(seconds: 20);

  /// Delay between the glyph end screen ("Done") and the bonus popup.
  static const glyphWindow = Duration(seconds: 90);

  _RewardRef? _regular;
  _RewardRef? _bonus;

  /// A regular reward or a glyph end screen was seen since the last bonus:
  /// the next bonus popup belongs to a new hack.
  bool _newHackSinceBonus = true;

  final _lastSeen = <String, int>{};
  PendingGlyph? _pendingGlyph;

  /// How complete a reading is: items read, with their level and rarity.
  static int readScore(ParseResult result) {
    var score = 0;
    for (final item in result.items) {
      score += 2 * item.quantity;
      if (item.level != null) score++;
      if (item.rarity != null) score++;
    }
    if (result.portalName != null) score++;
    if (result.transmuter != null) score++;
    return score;
  }

  static String nameKey(String? name) =>
      (name ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  LinkDecision classify({
    required int timestamp,
    required ParseResult result,
    bool debug = false,
  }) {
    final glyph = result.glyph;
    if (glyph != null) {
      final duplicate = _seenRecently('glyph:${glyphKey(glyph)}', timestamp);
      if (duplicate) return const LinkDecision('duplicate');
      _newHackSinceBonus = true;
      return const LinkDecision('glyph_result');
    }
    if (result.isHack) {
      return result.isBonusPopup ? _classifyBonus(timestamp, result) : _classifyRegular(timestamp, result);
    }
    if (result.ap != null) {
      return LinkDecision(_seenRecently('ap:${result.ap}', timestamp) ? 'duplicate' : 'ap');
    }
    return LinkDecision(debug ? 'raw' : 'ignored');
  }

  LinkDecision _classifyRegular(int ts, ParseResult result) {
    final ref = _regular;
    final key = nameKey(result.portalName);
    if (ref != null) {
      final gap = ts - ref.lastTs;
      final sameName = key.isNotEmpty && key == ref.nameKey;
      final unnamed = (key.isEmpty || ref.nameKey.isEmpty) && gap < unnamedWindow.inMilliseconds;
      if (gap < regularWindow.inMilliseconds && (sameName || unnamed)) {
        return _duplicateOf(ref, ts, result, key);
      }
    }
    return const LinkDecision('reward');
  }

  LinkDecision _classifyBonus(int ts, ParseResult result) {
    final ref = _bonus;
    if (ref != null && !_newHackSinceBonus && ts - ref.lastTs < bonusWindow.inMilliseconds) {
      return _duplicateOf(ref, ts, result, '');
    }
    return const LinkDecision('reward');
  }

  LinkDecision _duplicateOf(_RewardRef ref, int ts, ParseResult result, String key) {
    ref.lastTs = ts;
    final score = readScore(result);
    final replace = score > ref.score;
    if (replace) {
      ref.score = score;
      if (key.isNotEmpty) ref.nameKey = key;
    }
    return LinkDecision('duplicate', target: ref.id, replace: replace);
  }

  bool _seenRecently(String key, int ts) {
    final last = _lastSeen[key];
    _lastSeen[key] = ts;
    return last != null && ts - last < duplicateWindow.inMilliseconds;
  }

  static String glyphKey(GlyphResult g) => '${g.hackBonus}/${g.speedBonus}/${g.command}';

  /// A new reward was stored with [id].
  void rewardStored(int id, int ts, ParseResult result) {
    final ref = _RewardRef(id, ts, nameKey(result.portalName), readScore(result));
    if (result.isBonusPopup) {
      _bonus = ref;
      _newHackSinceBonus = false;
    } else {
      _regular = ref;
      _newHackSinceBonus = true;
    }
  }

  /// A new glyph end screen was stored with [id].
  void glyphStored(int id, int ts, GlyphResult result) => _pendingGlyph = PendingGlyph(id, ts, result);

  /// The glyph end screen seen shortly before the bonus reward at [ts].
  PendingGlyph? takePendingGlyph(int ts) {
    final pending = _pendingGlyph;
    _pendingGlyph = null;
    if (pending == null || ts - pending.timestamp > glyphWindow.inMilliseconds) return null;
    return pending;
  }

  // ------------------------------------------------- resuming from storage

  /// Replays a stored reward, so a batch drained later still matches it.
  void restoreReward(int id, int ts, {required bool bonus, String? portalName, required int score}) {
    final ref = _RewardRef(id, ts, nameKey(portalName), score);
    if (bonus) {
      _bonus = ref;
      _newHackSinceBonus = false;
      _pendingGlyph = null;
    } else {
      _regular = ref;
      _newHackSinceBonus = true;
    }
  }

  /// Replays a stored duplicate reading of reward [target].
  void restoreDuplicate(int target, int ts) {
    for (final ref in [_regular, _bonus]) {
      if (ref != null && ref.id == target && ts > ref.lastTs) ref.lastTs = ts;
    }
  }

  void restoreGlyph(int id, int ts, GlyphResult result, {required bool linked}) {
    _lastSeen['glyph:${glyphKey(result)}'] = ts;
    _newHackSinceBonus = true;
    _pendingGlyph = linked ? null : PendingGlyph(id, ts, result);
  }

  void restoreAp(int ap, int ts) => _lastSeen['ap:$ap'] = ts;
}
