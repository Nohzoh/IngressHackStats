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
