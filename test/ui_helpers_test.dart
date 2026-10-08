import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/parsing/item_catalog.dart';
import 'package:ingress_hack_stats/ui/common.dart';

void main() {
  test('time ago', () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
    expect(timeAgo(ago(const Duration(seconds: 12)), now: now), 'il y a 12 s');
    expect(timeAgo(ago(const Duration(minutes: 5)), now: now), 'il y a 5 min');
    expect(timeAgo(ago(const Duration(hours: 2)), now: now), 'il y a 2 h');
    expect(timeAgo(ago(const Duration(days: 2)), now: now), '06/10 12:00');
  });

  test('durations', () {
    expect(formatDuration(const Duration(seconds: 40)), '40 s');
    expect(formatDuration(const Duration(minutes: 12)), '12 min');
    expect(formatDuration(const Duration(minutes: 65)), '1 h 05');
  });

  test('every catalog item has a family', () {
    expect(ItemFamily.of('XMP Burster'), ItemFamily.weapons);
    expect(ItemFamily.of('Multi-hack'), ItemFamily.mods);
    expect(ItemFamily.of('Portal Key'), ItemFamily.keys);
    expect(ItemFamily.of('JARVIS Virus'), ItemFamily.special);
    for (final t in kItemCatalog) {
      expect(ItemFamily.values, contains(ItemFamily.of(t.name)));
    }
  });
}
