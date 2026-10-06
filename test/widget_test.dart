import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/parsing/item_catalog.dart';

void main() {
  test('catalog matches whole words only', () {
    final matcher = CatalogMatcher();
    expect(matcher.match('resonator l8')?.name, 'Resonator');
    expect(matcher.match('xmp burster l3')?.name, 'XMP Burster');
    expect(matcher.match('shieldwall'), isNull);
    expect(matcher.match('jarvis virus')?.name, 'JARVIS Virus');
  });
}
