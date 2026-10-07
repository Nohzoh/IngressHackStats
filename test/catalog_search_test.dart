import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/ui/catalog_screen.dart';

void main() {
  test('abbreviations and partial names find items', () {
    expect(matchesQuery('Multi-hack', 'MH'), isTrue);
    expect(matchesQuery('Multi-hack', 'multi'), isTrue);
    expect(matchesQuery('Heat Sink', 'hs'), isTrue);
    expect(matchesQuery('Ultra Strike', 'us'), isTrue);
    expect(matchesQuery('Portal Shield', 'ps'), isTrue);
    expect(matchesQuery('SoftBank Ultra Link', 'sbul'), isTrue);
    expect(matchesQuery('Multi-hack', 'multihack'), isTrue);
    expect(matchesQuery('Heat Sink', 'mh'), isFalse);
    expect(matchesQuery('Resonator', ''), isTrue);
  });
}
