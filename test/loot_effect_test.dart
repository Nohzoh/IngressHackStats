import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/stats/loot_effect.dart';

LootObservation reward(int others, {int key = 0, String stratum = 's'}) => LootObservation(
      stratum: stratum,
      items: {'Resonator': others, if (key > 0) 'Portal Key': key},
    );

void main() {
  test('a key on top of the others has no effect', () {
    final rewards = [
      for (var i = 0; i < 40; i++) reward(4 + i % 3),
      for (var i = 0; i < 20; i++) reward(4 + i % 3, key: 1),
    ];
    final e = LootEffect.compute('Portal Key', rewards);
    expect(e.difference, closeTo(0, 0.2));
    expect(e.verdict, LootVerdict.noEffect);
    expect(e.rewardsWith, 20);
    expect(e.quantityWhenPresent, 1);
  });

  test('a key taking a slot of a fixed-size reward', () {
    final rewards = [
      for (var i = 0; i < 40; i++) reward(5),
      for (var i = 0; i < 15; i++) reward(4, key: 1),
    ];
    final e = LootEffect.compute('Portal Key', rewards);
    expect(e.difference, closeTo(-1, 1e-9));
    expect(e.verdict, LootVerdict.takesPlace);
  });

  test('rewards are compared within their stratum', () {
    // Keys mostly in big bonus rewards: no effect once compared at equal size.
    final rewards = [
      for (var i = 0; i < 30; i++) reward(2 + i % 2, stratum: 'small'),
      for (var i = 0; i < 3; i++) reward(2 + i % 2, key: 1, stratum: 'small'),
      for (var i = 0; i < 10; i++) reward(10 + i % 2, stratum: 'big'),
      for (var i = 0; i < 20; i++) reward(10 + i % 2, key: 1, stratum: 'big'),
    ];
    final e = LootEffect.compute('Portal Key', rewards);
    expect(e.othersWith, greaterThan(e.othersWithout + 4));
    expect(e.difference, closeTo(0, 0.2));
    expect(e.verdict, LootVerdict.noEffect);
  });

  test('a stratum without comparison is ignored', () {
    final rewards = [
      for (var i = 0; i < 5; i++) reward(4, key: 1, stratum: 'alone'),
      for (var i = 0; i < 5; i++) reward(4),
    ];
    final e = LootEffect.compute('Portal Key', rewards);
    expect(e.compared, 0);
    expect(e.verdict, LootVerdict.notEnoughData);
  });

  test('few rewards with the item give no verdict', () {
    final rewards = [for (var i = 0; i < 40; i++) reward(5), for (var i = 0; i < 3; i++) reward(4, key: 1)];
    expect(LootEffect.compute('Portal Key', rewards).verdict, LootVerdict.notEnoughData);
  });

  test('computeAll covers every item seen', () {
    final all = LootEffect.computeAll([reward(3), reward(3, key: 1)]);
    expect(all.keys.toSet(), {'Resonator', 'Portal Key'});
  });

  test('formatDecimal', () {
    expect(formatDecimal(4.06), '4,1');
    expect(formatDecimal(-0.84, signed: true), '−0,8');
    expect(formatDecimal(0.3, signed: true), '+0,3');
    expect(formatDecimal(-0.01, signed: true), '0,0');
    expect(formatDecimal(double.nan), '—');
  });
}
