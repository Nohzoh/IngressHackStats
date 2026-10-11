import 'dart:math' as math;

/// One reward, as seen by the "effect on the rest of the loot" analysis.
class LootObservation {
  const LootObservation({required this.stratum, required this.items});

  /// Rewards are only compared within the same stratum (same reward type,
  /// glyph quality, glyph command, Ito En…), whose size may differ.
  final String stratum;

  /// Quantity received per item.
  final Map<String, int> items;

  int get total => items.values.fold(0, (a, b) => a + b);
}

enum LootVerdict {
  /// Too few rewards with the item to conclude.
  notEnoughData,

  /// No measurable difference: the item comes on top of the others.
  noEffect,

  /// Fewer other items when it comes: it takes the place of others.
  takesPlace,

  /// More other items when it comes: it tends to come with bigger rewards.
  biggerRewards;

  String get label => switch (this) {
        notEnoughData => 'pas assez de données',
        noEffect => 'aucun effet mesuré',
        takesPlace => 'prend la place d’autres objets',
        biggerRewards => 'sort dans les grosses récompenses',
      };
}

/// Does getting [item] change how many *other* items the reward contains?
///
/// Compares the number of other items (quantities, the item itself
/// excluded) between rewards with and without it, within each stratum, then
/// averages the stratum differences weighted by the rewards with the item.
/// If the item is drawn independently from the rest, the difference is 0.
/// If it takes a slot, it is negative (down to minus its own quantity when
/// the reward size is fixed).
class LootEffect {
  const LootEffect({
    required this.item,
    required this.rewardsWith,
    required this.rewardsWithout,
    required this.othersWith,
    required this.othersWithout,
    required this.quantityWhenPresent,
    required this.compared,
    required this.difference,
    required this.margin,
  });

  final String item;
  final int rewardsWith;
  final int rewardsWithout;

  /// Average number of other items, all strata mixed.
  final double othersWith;
  final double othersWithout;

  /// Average quantity of the item when it comes.
  final double quantityWhenPresent;

  /// Rewards with the item that had comparable rewards without it.
  final int compared;

  /// Difference of other items, at equal conditions (stratified).
  final double difference;

  /// 95 % margin of [difference].
  final double margin;

  /// Below this many compared rewards, no verdict.
  static const minCompared = 10;

  LootVerdict get verdict {
    if (compared < minCompared || margin.isNaN) return LootVerdict.notEnoughData;
    if (difference + margin < 0) return LootVerdict.takesPlace;
    if (difference - margin > 0) return LootVerdict.biggerRewards;
    return LootVerdict.noEffect;
  }

  /// Effect of every item seen in [rewards] (or only of [items]).
  static Map<String, LootEffect> computeAll(List<LootObservation> rewards, {Iterable<String>? items}) {
    final names = items?.toSet() ?? {for (final r in rewards) ...r.items.keys};
    return {for (final n in names) n: compute(n, rewards)};
  }

  static LootEffect compute(String item, List<LootObservation> rewards) {
    final withItem = <String, List<int>>{};
    final without = <String, List<int>>{};
    var quantity = 0;
    for (final r in rewards) {
      final q = r.items[item] ?? 0;
      final others = r.total - q;
      if (q > 0) {
        quantity += q;
        withItem.putIfAbsent(r.stratum, () => []).add(others);
      } else {
        without.putIfAbsent(r.stratum, () => []).add(others);
      }
    }
    final allWith = [for (final l in withItem.values) ...l];
    final allWithout = [for (final l in without.values) ...l];

    var weight = 0;
    var sum = 0.0;
    var variance = 0.0;
    for (final MapEntry(key: stratum, value: a) in withItem.entries) {
      final b = without[stratum];
      if (b == null || a.length + b.length < 3) continue;
      final ma = _mean(a), mb = _mean(b);
      // Pooled variance: lets a stratum with a single reward with the item count.
      final ss = a.fold(0.0, (s, x) => s + (x - ma) * (x - ma)) + b.fold(0.0, (s, x) => s + (x - mb) * (x - mb));
      final pooled = ss / (a.length + b.length - 2);
      final w = a.length;
      weight += w;
      sum += w * (ma - mb);
      variance += w * w * pooled * (1 / a.length + 1 / b.length);
    }
    return LootEffect(
      item: item,
      rewardsWith: allWith.length,
      rewardsWithout: allWithout.length,
      othersWith: _mean(allWith),
      othersWithout: _mean(allWithout),
      quantityWhenPresent: allWith.isEmpty ? 0 : quantity / allWith.length,
      compared: weight,
      difference: weight == 0 ? double.nan : sum / weight,
      margin: weight == 0 ? double.nan : 1.96 * math.sqrt(variance) / weight,
    );
  }

  static double _mean(List<int> l) => l.isEmpty ? double.nan : l.fold(0, (a, b) => a + b) / l.length;
}

/// "4,1", "−0,8" (French decimal comma, real minus sign).
String formatDecimal(double v, {bool signed = false}) {
  if (v.isNaN) return '—';
  final s = v.abs().toStringAsFixed(1).replaceAll('.', ',');
  if (s == '0,0') return '0,0';
  return v < 0 ? '−$s' : (signed ? '+$s' : s);
}
