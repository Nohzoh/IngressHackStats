import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/parsing/portal_level.dart';

void main() {
  test('most frequent item level wins, weighted by quantity', () {
    // L1 x1 Power Cube, L1 x1 Resonator + bonus L1 XMP, L3, L2, L1 x2 Resonator
    expect(inferPortalLevel({1: 5, 2: 1, 3: 1}, seed: 1), 1);
  });

  test('no leveled item, no level', () {
    expect(inferPortalLevel({}, seed: 1), isNull);
  });

  test('ties pick one of the tied levels, always the same for a given hack', () {
    final picks = {for (var id = 0; id < 200; id++) inferPortalLevel({5: 2, 6: 2, 7: 1}, seed: id)};
    expect(picks, {5, 6});
    expect(inferPortalLevel({5: 2, 6: 2}, seed: 42), inferPortalLevel({6: 2, 5: 2}, seed: 42));
  });

  test('a Power Cube gives the portal level, whatever the other items say', () {
    final level = portalLevelOf(otherLevels: {7: 5, 6: 1}, cubeLevels: {8: 1}, seed: 1);
    expect(level?.level, 8);
    expect(level?.fromCube, isTrue);
  });

  test('without cube, the most frequent level is an estimate', () {
    final level = portalLevelOf(otherLevels: {7: 5, 6: 1}, seed: 1);
    expect(level?.level, 7);
    expect(level?.fromCube, isFalse);
    expect(portalLevelOf(otherLevels: {}, seed: 1), isNull);
  });

  test('check of the estimate against cubes', () {
    final check = PortalLevelCheck(const [(8, 8), (8, 7), (7, 7), (6, 8), (5, null)]);
    expect(check.total, 5);
    expect(check.withEstimate, 4);
    expect(check.exact, 2);
    expect(check.offByOne, 1);
    expect(check.offMore, 1);
    expect(check.bias, closeTo((0 - 1 + 0 + 2) / 4, 1e-9));
    expect(check.count(8, 7), 1);
    expect(check.realLevels, [5, 6, 7, 8]);
    expect(check.estimatedLevels, [7, 8]);
  });
}
