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
}
