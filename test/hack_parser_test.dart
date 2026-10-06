import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/models/ocr_capture.dart';
import 'package:ingress_hack_stats/parsing/hack_parser.dart';
import 'package:ingress_hack_stats/parsing/item_catalog.dart';

const screenHeight = 2000.0;

/// Text around the popup on a real screen (agent, COMM, alerts, inventory).
const surroundings = [
  OcrLine('Lappeau 14', x: 628, y: 235, h: 50),
  OcrLine('10:39 Giraff', x: 328, y: 298, h: 34),
  OcrLine('10:39 Exposition de Photos', x: 328, y: 345, h: 34),
  OcrLine('1,545', x: 88, y: 1773, h: 40),
  OcrLine('358', x: 280, y: 1773, h: 40),
  OcrLine('10:27', x: 645, y: 1758, h: 40),
  OcrLine('1,903 / 2,000', x: 125, y: 1828, h: 40),
  OcrLine('Portal under attack', x: 592, y: 1800, h: 36),
  OcrLine('Usine à gaz', x: 592, y: 1842, h: 36),
];

/// Regular hack popup (screenshot 1).
const regularPopup = [
  ...surroundings,
  OcrLine('Szlama Ejzman', x: 315, y: 657, h: 40),
  OcrLine('L1 x1 Power Cube', x: 118, y: 735, h: 38),
  OcrLine('L1 x1 Resonator', x: 528, y: 735, h: 38),
];

/// Glyph bonus popup (screenshot 2).
const bonusPopup = [
  ...surroundings,
  OcrLine('Bonus items:', x: 333, y: 657, h: 40),
  OcrLine('L1 x1 XMP Burster', x: 118, y: 735, h: 38),
  OcrLine('L3 x1 Resonator', x: 528, y: 735, h: 38),
  OcrLine('L2 x1 Resonator', x: 118, y: 805, h: 38),
  OcrLine('L1 x2 Resonator', x: 528, y: 805, h: 38),
];

/// Regular popup on a portal with an Ito En (−) (screenshot 3).
const itoEnPopup = [
  ...surroundings,
  OcrLine('Szlama Ejzman', x: 315, y: 657, h: 40),
  OcrLine('ITO EN (-) applied.', x: 310, y: 725, h: 34),
  OcrLine('L1 x1 Power Cube', x: 118, y: 798, h: 38),
  OcrLine('L2 x1 XMP Burster', x: 528, y: 798, h: 38),
  OcrLine('L1 x3 XMP Burster', x: 118, y: 868, h: 38),
];

/// Bonus popup of the same hack (screenshot 4).
const itoEnBonusPopup = [
  ...surroundings,
  OcrLine('Bonus items:', x: 333, y: 657, h: 40),
  OcrLine('ITO EN (-) applied.', x: 310, y: 725, h: 34),
  OcrLine('L3 x1 XMP Burster', x: 118, y: 798, h: 38),
  OcrLine('L1 x2 XMP Burster', x: 528, y: 798, h: 38),
];

void main() {
  final parser = HackParser();

  test('Ito En line: transmuter read, portal name still found above it', () {
    final result = parser.parse(itoEnPopup, screenHeight: screenHeight);

    expect(result.portalName, 'Szlama Ejzman');
    expect(result.transmuter, Transmuter.minus);
    expect(result.items.map((i) => i.toString()), [
      'Power Cube L1',
      'XMP Burster L2',
      'XMP Burster L1 ×3',
    ]);
  });

  test('Ito En line in the bonus popup', () {
    final result = parser.parse(itoEnBonusPopup, screenHeight: screenHeight);

    expect(result.isBonusPopup, isTrue);
    expect(result.transmuter, Transmuter.minus);
    expect(result.items.map((i) => i.toString()), [
      'XMP Burster L3 [bonus]',
      'XMP Burster L1 ×2 [bonus]',
    ]);
  });

  test('Ito En (+) and OCR variants of the dash', () {
    for (final text in ['ITO EN (+) applied.', 'ITO EN (—) applied.', 'IT0 EN (-) applied']) {
      final result = parser.parse([
        const OcrLine('Some Portal', y: 100, h: 30),
        OcrLine(text, y: 160, h: 30),
        const OcrLine('L5 x1 Resonator', y: 220, h: 30),
      ]);
      expect(result.transmuter, text.contains('+') ? Transmuter.plus : Transmuter.minus, reason: text);
      expect(result.portalName, 'Some Portal', reason: text);
    }
  });

  test('no Ito En line, no transmuter', () {
    expect(parser.parse(regularPopup, screenHeight: screenHeight).transmuter, isNull);
  });

  test('regular popup: two items on one row, portal name as title', () {
    final result = parser.parse(regularPopup, screenHeight: screenHeight);

    expect(result.isHack, isTrue);
    expect(result.isBonusPopup, isFalse);
    expect(result.portalName, 'Szlama Ejzman');
    expect(result.items.map((i) => i.toString()), ['Power Cube L1', 'Resonator L1']);
  });

  test('bonus popup: flagged as bonus, quantities and levels read', () {
    final result = parser.parse(bonusPopup, screenHeight: screenHeight);

    expect(result.isBonusPopup, isTrue);
    expect(result.portalName, isNull);
    expect(result.items.map((i) => i.toString()), [
      'XMP Burster L1 [bonus]',
      'Resonator L3 [bonus]',
      'Resonator L2 [bonus]',
      'Resonator L1 ×2 [bonus]',
    ]);
  });

  test('OCR merging both columns into one line still gives two items', () {
    final result = parser.parse(const [
      OcrLine('Szlama Ejzman', x: 315, y: 657, h: 40),
      OcrLine('L1 x1 Power Cube L1 x1 Resonator', x: 118, y: 735, h: 38),
    ], screenHeight: screenHeight);
    expect(result.items.map((i) => i.item), ['Power Cube', 'Resonator']);
  });

  test('"×" is read like "x"', () {
    final item = parser.parse(const [OcrLine('L8 ×3 Ultra Strike')]).items.single;
    expect(item.level, 8);
    expect(item.quantity, 3);
  });

  test('rarity before the quantity belongs to the item', () {
    final result = parser.parse(const [
      OcrLine('Very Rare x1 Heat Sink', x: 0, y: 100, h: 30),
      OcrLine('Rare x2 Portal Shield', x: 400, y: 100, h: 30),
    ]);
    expect(result.items.map((i) => i.toString()), [
      'Heat Sink (Très rare)',
      'Portal Shield (Rare) ×2',
    ]);
  });

  test('item names without a quantity token are ignored (COMM, alerts)', () {
    final result = parser.parse(const [
      ...surroundings,
      OcrLine('10:41 Agent deployed an L8 Resonator', x: 328, y: 392, h: 34),
    ], screenHeight: screenHeight);
    expect(result.isHack, isFalse);
  });

  test('screens with non-hack markers are rejected', () {
    final result = parser.parse(const [
      OcrLine('INVENTORY', y: 100, h: 30),
      OcrLine('L8 x120 Resonator', y: 200, h: 30),
    ]);
    expect(result.rejectReason, 'marker:inventory');
  });

  test('signature depends on the portal and is order-independent', () {
    final a = parser.parse(regularPopup, screenHeight: screenHeight);
    final b = parser.parse(const [
      OcrLine('Szlama Ejzman', x: 315, y: 657, h: 40),
      OcrLine('L1 x1 Resonator', x: 118, y: 735, h: 38),
      OcrLine('L1 x1 Power Cube', x: 528, y: 735, h: 38),
    ], screenHeight: screenHeight);
    final c = parser.parse(const [
      OcrLine('Another Portal', x: 315, y: 657, h: 40),
      OcrLine('L1 x1 Power Cube', x: 118, y: 735, h: 38),
      OcrLine('L1 x1 Resonator', x: 528, y: 735, h: 38),
    ], screenHeight: screenHeight);
    expect(a.signature, b.signature);
    expect(a.signature, isNot(c.signature));
  });

  test('segments split a row at each quantity token', () {
    expect(HackParser.segments('l1 x1 xmp burster l3 x1 resonator'), [
      'l1 x1 xmp burster',
      'l3 x1 resonator',
    ]);
    expect(HackParser.segments('very rare x1 heat sink'), ['very rare x1 heat sink']);
    expect(HackParser.segments('portal under attack'), isEmpty);
  });

  test('rarity labels', () {
    expect(HackParser.parseRarity('vr x1 heat sink'), Rarity.veryRare);
  });
}
