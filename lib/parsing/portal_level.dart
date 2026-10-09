/// The hack popup does not show the portal level. Hack loot is centred on the
/// portal level (±2), so the most frequent item level is a good estimate.
///
/// [countsByLevel] maps an item level to the number of items of that level
/// (regular and bonus). Ties are broken pseudo-randomly from [seed] (the hack
/// id), so re-running the analysis gives the same answer.
///
/// Returns null when the hack gave no leveled item.
int? inferPortalLevel(Map<int, int> countsByLevel, {required int seed}) {
  if (countsByLevel.isEmpty) return null;
  final best = countsByLevel.values.reduce((a, b) => a > b ? a : b);
  final candidates = countsByLevel.entries
      .where((e) => e.value == best)
      .map((e) => e.key)
      .toList()
    ..sort();
  if (candidates.length == 1) return candidates.single;
  return candidates[_mix(seed) % candidates.length];
}

/// Small integer hash, so consecutive ids don't pick consecutive candidates.
int _mix(int x) {
  var h = x & 0x7fffffff;
  h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
  h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
  return (h >> 16) ^ h;
}

/// Only Power Cubes have this property: a cube in a reward is always at the
/// portal level (resonators and weapons spread ±2 around it).
const kExactLevelItem = 'Power Cube';

/// The portal level of a reward and how it was obtained.
class PortalLevel {
  const PortalLevel(this.level, {required this.fromCube});

  final int level;

  /// True when read from a Power Cube (certain), false when estimated
  /// from the other item levels.
  final bool fromCube;
}

/// Portal level of a reward: the Power Cube level when there is one
/// (several readings disagreeing: the most frequent), otherwise the most
/// frequent level among the other items.
///
/// [otherLevels]: levels of the items that are not Power Cubes.
/// [cubeLevels]: levels of the Power Cubes.
PortalLevel? portalLevelOf({
  required Map<int, int> otherLevels,
  Map<int, int> cubeLevels = const {},
  required int seed,
}) {
  final fromCube = inferPortalLevel(cubeLevels, seed: seed);
  if (fromCube != null) return PortalLevel(fromCube, fromCube: true);
  final estimated = inferPortalLevel(otherLevels, seed: seed);
  return estimated == null ? null : PortalLevel(estimated, fromCube: false);
}

/// How the level estimated without cubes compares with the real level given
/// by a cube, over the rewards that contain one.
class PortalLevelCheck {
  PortalLevelCheck(this.pairs);

  /// (real level from the cube, level estimated from the other items or
  /// null when they had no level).
  final List<(int, int?)> pairs;

  int get total => pairs.length;
  Iterable<(int, int)> get _estimated => [
        for (final (real, est) in pairs)
          if (est != null) (real, est),
      ];
  int get withEstimate => _estimated.length;
  int get exact => _estimated.where((p) => p.$1 == p.$2).length;
  int get offByOne => _estimated.where((p) => (p.$1 - p.$2).abs() == 1).length;
  int get offMore => _estimated.where((p) => (p.$1 - p.$2).abs() >= 2).length;

  /// Average of (estimated − real): above 0, the estimate is too high.
  double get bias {
    final e = _estimated.toList();
    if (e.isEmpty) return 0;
    return e.fold(0, (sum, p) => sum + (p.$2 - p.$1)) / e.length;
  }

  /// Number of rewards for each (real, estimated) pair.
  int count(int real, int estimated) => _estimated.where((p) => p.$1 == real && p.$2 == estimated).length;

  /// Real levels seen, ascending.
  List<int> get realLevels => ({for (final p in pairs) p.$1}.toList()..sort());

  /// Estimated levels seen, ascending.
  List<int> get estimatedLevels => ({for (final p in _estimated) p.$2}.toList()..sort());
}
