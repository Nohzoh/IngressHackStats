import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/models/ocr_capture.dart';
import 'package:ingress_hack_stats/parsing/hack_parser.dart';
import 'package:ingress_hack_stats/parsing/item_catalog.dart';

/// Lines placed one per row, 50 px apart.
List<OcrLine> rows(List<String> texts) => [
      for (var i = 0; i < texts.length; i++) OcrLine(texts[i], x: 100, y: 500.0 + i * 50, h: 30),
    ];

void main() {
  final parser = HackParser();

  test('parses leveled items, quantities and rarities', () {
    final result = parser.parse(rows([
      'L8 Resonator x2',
      'XMP Burster L7',
      'Very Rare Heat Sink',
      'Portal Key',
    ]));

    expect(result.isHack, isTrue);
    expect(result.items.map((i) => i.toString()), [
      'Resonator L8 ×2',
      'XMP Burster L7',
      'Heat Sink (Très rare)',
      'Portal Key',
    ]);
  });

  test('a quantity on its own line on the same row is merged', () {
    final result = parser.parse([
      const OcrLine('Power Cube L6', x: 100, y: 500, h: 30),
      const OcrLine('×3', x: 600, y: 504, h: 26),
    ]);
    expect(result.items.single.quantity, 3);
    expect(result.items.single.level, 6);
  });

  test('a quantity on the next row applies to the previous item', () {
    final result = parser.parse(rows(['Ultra Strike L5', 'x4']));
    expect(result.items.single.quantity, 4);
  });

  test('items after a bonus heading are flagged as bonus', () {
    final result = parser.parse(rows(['Resonator L8', 'Glyph Bonus', 'Resonator L8']));
    expect(result.items.map((i) => i.bonus), [false, true]);
  });

  test('longest alias wins', () {
    final result = parser.parse(rows(['Aegis Shield', 'Rare Portal Shield', 'SoftBank Ultra Link']));
    expect(result.items.map((i) => i.item), ['Aegis Shield', 'Portal Shield', 'SoftBank Ultra Link']);
    expect(result.items[1].rarity, Rarity.rare);
  });

  test('screens with non-hack markers are rejected', () {
    final result = parser.parse(rows(['INVENTORY', 'Resonator L8 x120']));
    expect(result.isHack, isFalse);
    expect(result.rejectReason, 'marker:inventory');
  });

  test('frames without any item are not hacks', () {
    expect(parser.parse(rows(['Hello world'])).isHack, isFalse);
  });

  test('the level is not mistaken for a quantity', () {
    final item = parser.parse(rows(['Resonator L8'])).items.single;
    expect(item.level, 8);
    expect(item.quantity, 1);
  });

  test('signature is order-independent', () {
    final a = parser.parse(rows(['Resonator L8', 'Portal Key']));
    final b = parser.parse(rows(['Portal Key', 'Resonator L8']));
    expect(a.signature, b.signature);
  });
}
