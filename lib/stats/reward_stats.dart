import 'dart:math' as math;

import '../parsing/item_catalog.dart';

/// Counts for one item (name + level + rarity) over a set of rewards.
class ItemCount {
  const ItemCount({
    required this.item,
    this.level,
    this.rarity,
    required this.rewardsWith,
    required this.quantity,
  });

  final String item;
  final int? level;
  final String? rarity;

  /// Rewards containing this item at least once.
  final int rewardsWith;

  /// Total quantity received.
  final int quantity;

  String get key => '$item|${level ?? ''}|${rarity ?? ''}';

  String get label {
    final buf = StringBuffer(item);
    if (level != null) buf.write(' L$level');
    if (rarity != null) buf.write(' · ${Rarity.label(rarity!)}');
    return buf.toString();
  }
}

/// One line of the stats screen.
class ItemStat {
  const ItemStat({
    required this.item,
    this.level,
    this.rarity,
    required this.presence,
    required this.presenceMargin,
    required this.share,
    required this.perReward,
  });

  final String item;
  final int? level;
  final String? rarity;

  /// Probability that a reward contains this item (0–1).
  final double presence;

  /// Half-width of the 95 % confidence interval on [presence].
  final double presenceMargin;

  /// Share of this item among all received items (0–1). Null for the
  /// computed "hack with glyph" view, where it has no direct meaning.
  final double? share;

  /// Average quantity per reward (per hack in the computed view).
  final double perReward;

  String get label {
    final buf = StringBuffer(item);
    if (level != null) buf.write(' L$level');
    if (rarity != null) buf.write(' · ${Rarity.label(rarity!)}');
    return buf.toString();
  }
}

class RewardStats {
  const RewardStats({required this.rewards, required this.totalItems, required this.items});

  /// Number of rewards (or of hacks, for the computed view).
  final int rewards;
  final int totalItems;
  final List<ItemStat> items;

  double get itemsPerReward => rewards == 0 ? 0 : totalItems / rewards;

  static const empty = RewardStats(rewards: 0, totalItems: 0, items: []);

  /// Stats over [rewards] rewards whose item counts are [counts].
  factory RewardStats.fromCounts(int rewards, List<ItemCount> counts) {
    final totalItems = counts.fold(0, (sum, c) => sum + c.quantity);
    final items = [
      for (final c in counts)
        ItemStat(
          item: c.item,
          level: c.level,
          rarity: c.rarity,
          presence: rewards == 0 ? 0 : c.rewardsWith / rewards,
          presenceMargin: margin95(c.rewardsWith, rewards),
          share: totalItems == 0 ? 0 : c.quantity / totalItems,
          perReward: rewards == 0 ? 0 : c.quantity / rewards,
        ),
    ]..sort(_byPresence);
    return RewardStats(rewards: rewards, totalItems: totalItems, items: items);
  }

  /// What a hack with glyph yields: one regular reward plus one bonus
  /// reward, assumed independent. Chance to get an item at least once:
  /// 1 − (1 − p_regular)(1 − p_bonus); expected quantity: sum of both.
  factory RewardStats.glyphHack({
    required int regularRewards,
    required List<ItemCount> regular,
    required int bonusRewards,
    required List<ItemCount> bonus,
  }) {
    if (regularRewards == 0 || bonusRewards == 0) return empty;
    final regularByKey = {for (final c in regular) c.key: c};
    final bonusByKey = {for (final c in bonus) c.key: c};
    final keys = {...regularByKey.keys, ...bonusByKey.keys};
    final items = <ItemStat>[];
    var expectedItems = 0.0;
    for (final key in keys) {
      final r = regularByKey[key];
      final b = bonusByKey[key];
      final ref = r ?? b!;
      final pr = (r?.rewardsWith ?? 0) / regularRewards;
      final pb = (b?.rewardsWith ?? 0) / bonusRewards;
      final mr = margin95(r?.rewardsWith ?? 0, regularRewards);
      final mb = margin95(b?.rewardsWith ?? 0, bonusRewards);
      final perHack = (r?.quantity ?? 0) / regularRewards + (b?.quantity ?? 0) / bonusRewards;
      expectedItems += perHack;
      items.add(ItemStat(
        item: ref.item,
        level: ref.level,
        rarity: ref.rarity,
        presence: 1 - (1 - pr) * (1 - pb),
        // Error propagation of 1 − (1 − pr)(1 − pb).
        presenceMargin: math.sqrt(math.pow((1 - pb) * mr, 2) + math.pow((1 - pr) * mb, 2)),
        share: null,
        perReward: perHack,
      ));
    }
    items.sort(_byPresence);
    final hacks = math.min(regularRewards, bonusRewards);
    return RewardStats(rewards: hacks, totalItems: (expectedItems * hacks).round(), items: items);
  }

  /// 95 % confidence half-width of a proportion (Wilson score interval).
  static double margin95(int successes, int n) {
    if (n == 0) return 0;
    const z = 1.96;
    final p = successes / n;
    final denom = 1 + z * z / n;
    return z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom;
  }

  /// Most likely first; at equal chance, the one received in larger numbers.
  static int _byPresence(ItemStat a, ItemStat b) {
    final byPresence = b.presence.compareTo(a.presence);
    if (byPresence != 0) return byPresence;
    final byQuantity = b.perReward.compareTo(a.perReward);
    return byQuantity != 0 ? byQuantity : a.label.compareTo(b.label);
  }
}

/// The headline figure for an item: "8,67 / réc." when it comes in at
/// least half the rewards, otherwise "1/N", N being the average number of
/// rewards needed to get it once.
String formatChance(double presence, double perReward, {String unit = 'réc.'}) {
  String decimal(double v, {int digits = 2}) => v.toStringAsFixed(digits).replaceAll('.', ',');
  if (presence <= 0) return '0';
  if (presence >= 0.5) return '${decimal(perReward)} / $unit';
  final n = 1 / presence;
  return '1/${n < 10 ? decimal(n, digits: 1) : n.round()}';
}

/// "33,3 %"
String formatPercent(double v) => '${(100 * v).toStringAsFixed(1).replaceAll('.', ',')} %';
