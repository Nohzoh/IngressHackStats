import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/stats/reward_stats.dart';

void main() {
  test('presence, share and quantity per reward', () {
    final stats = RewardStats.fromCounts(4, const [
      ItemCount(item: 'Resonator', level: 8, rewardsWith: 4, quantity: 6),
      ItemCount(item: 'Heat Sink', rarity: 'very_rare', rewardsWith: 1, quantity: 1),
      ItemCount(item: 'XMP Burster', level: 8, rewardsWith: 2, quantity: 3),
    ]);

    expect(stats.rewards, 4);
    expect(stats.totalItems, 10);
    expect(stats.itemsPerReward, 2.5);
    expect(stats.items.map((i) => i.item), ['Resonator', 'XMP Burster', 'Heat Sink']);
    final reso = stats.items.first;
    expect(reso.presence, 1.0);
    expect(reso.share, 0.6);
    expect(reso.perReward, 1.5);
    expect(stats.items.last.presence, 0.25);
  });

  test('hack with glyph combines both rewards as independent draws', () {
    final stats = RewardStats.glyphHack(
      regularRewards: 10,
      regular: const [ItemCount(item: 'Heat Sink', rewardsWith: 1, quantity: 1)],
      bonusRewards: 10,
      bonus: const [
        ItemCount(item: 'Heat Sink', rewardsWith: 2, quantity: 2),
        ItemCount(item: 'Resonator', level: 8, rewardsWith: 5, quantity: 7),
      ],
    );

    final heatSink = stats.items.firstWhere((i) => i.item == 'Heat Sink');
    expect(heatSink.presence, closeTo(1 - 0.9 * 0.8, 1e-9));
    expect(heatSink.perReward, closeTo(0.3, 1e-9));
    expect(heatSink.share, isNull);
    final reso = stats.items.firstWhere((i) => i.item == 'Resonator');
    expect(reso.presence, closeTo(0.5, 1e-9));
  });

  test('no bonus reward, no computed glyph view', () {
    final stats = RewardStats.glyphHack(
      regularRewards: 3,
      regular: const [ItemCount(item: 'Resonator', rewardsWith: 3, quantity: 3)],
      bonusRewards: 0,
      bonus: const [],
    );
    expect(stats.rewards, 0);
  });

  test('confidence margin shrinks with sample size', () {
    final small = RewardStats.margin95(5, 10);
    final large = RewardStats.margin95(500, 1000);
    expect(small, greaterThan(large));
    expect(large, closeTo(0.031, 0.002));
    expect(RewardStats.margin95(0, 0), 0);
  });
}
