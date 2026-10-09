import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/stats/item_detail.dart';

void main() {
  // XMP Burster studied; otherLevels = levels of the *other* items.
  final detail = ItemDetail.compute('XMP Burster', const [
    RewardObservation(id: 1, bonus: false, otherLevels: {8: 3}, itemQuantities: {'L8': 1}),
    RewardObservation(id: 2, bonus: false, otherLevels: {8: 2}, itemQuantities: {}),
    RewardObservation(id: 3, bonus: false, otherLevels: {7: 3}, itemQuantities: {'L7': 2}),
    RewardObservation(id: 4, bonus: false, otherLevels: {}, itemQuantities: {'L8': 1}),
    RewardObservation(id: 5, bonus: true, otherLevels: {8: 4}, itemQuantities: {'L8': 2, 'L7': 1}),
  ]);

  test('variants and rows found in the data', () {
    expect(detail.variants, ['L7', 'L8']);
    expect(detail.levelRows, [7, 8, ItemDetail.unknownRow]);
  });

  test('all portal levels, all variants', () {
    final all = detail.cell(null, DetailColumnType.regular, null);
    expect(all.rewards, 4);
    expect(all.rewardsWith, 3);
    expect(all.quantity, 4);
  });

  test('per portal level and variant, rewards without the item still count', () {
    final p8L8 = detail.cell(8, DetailColumnType.regular, 'L8');
    expect(p8L8.rewards, 2);
    expect(p8L8.rewardsWith, 1);
    expect(detail.cell(8, DetailColumnType.regular, 'L7').rewardsWith, 0);
    expect(detail.cell(ItemDetail.unknownRow, DetailColumnType.regular, 'L8').rewardsWith, 1);
  });

  test('portal level estimated without the studied item', () {
    // Reward 5 has two L8 XMP and one L7 XMP, but its other items are L8.
    expect(detail.cell(8, DetailColumnType.bonus, null).rewards, 1);
    expect(detail.cell(7, DetailColumnType.bonus, null).rewards, 0);
  });

  test('hack + glyph combines both reward types', () {
    const regular = DetailCell(rewards: 10, rewardsWith: 5, quantity: 6);
    const bonus = DetailCell(rewards: 8, rewardsWith: 4, quantity: 4);
    final combined = DetailCell.glyphHack(regular, bonus);
    expect(combined.presence, closeTo(0.75, 1e-9));
    expect(combined.perReward, closeTo(1.1, 1e-9));
    expect(combined.rewards, 8);
  });

  test('display: quantity when common, 1/N when rare', () {
    expect(const DetailCell(rewards: 100, rewardsWith: 60, quantity: 140).format(), '1,40 / réc.');
    expect(const DetailCell(rewards: 100, rewardsWith: 2, quantity: 2).format(), '1/50');
    expect(const DetailCell(rewards: 100, rewardsWith: 20, quantity: 25).format(), '1/5,0');
    expect(const DetailCell(rewards: 50, rewardsWith: 0, quantity: 0).format(), '0');
    expect(const DetailCell(rewards: 0, rewardsWith: 0, quantity: 0).format(), '—');
  });

  test('few rewards are flagged as unreliable', () {
    expect(const DetailCell(rewards: 12, rewardsWith: 3, quantity: 3).reliable, isFalse);
    expect(const DetailCell(rewards: 30, rewardsWith: 3, quantity: 3).reliable, isTrue);
  });

  test('a Power Cube in the reward fixes the portal level for other items', () {
    final d = ItemDetail.compute('Resonator', const [
      // Other items say L6, the cube says L7: the cube wins.
      RewardObservation(id: 1, bonus: false, otherLevels: {6: 4}, cubeLevels: {7: 1}, itemQuantities: {'L6': 2}),
    ]);
    expect(d.levelRows, [7]);
  });
}
