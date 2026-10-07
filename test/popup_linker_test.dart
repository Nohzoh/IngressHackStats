import 'package:flutter_test/flutter_test.dart';
import 'package:ingress_hack_stats/data/popup_linker.dart';
import 'package:ingress_hack_stats/parsing/hack_parser.dart';

ParseResult regular(String portal, List<ParsedItem> items) => ParseResult(items, portalName: portal);

ParseResult bonus(List<ParsedItem> items) => ParseResult(items, isBonusPopup: true);

const glyphScreen = ParseResult([], glyph: GlyphResult(hackBonus: 80, speedBonus: 40, command: 'MORE'));

/// Simulates the repository: stores new rewards with increasing ids.
class Harness {
  final linker = PopupLinker();
  var _nextId = 1;
  final kinds = <String>[];

  LinkDecision feed(int seconds, ParseResult result) {
    final ts = seconds * 1000;
    final d = linker.classify(timestamp: ts, result: result);
    kinds.add(d.kind);
    final id = _nextId++;
    if (d.kind == 'reward') linker.rewardStored(id, ts, result);
    if (d.kind == 'glyph_result') linker.glyphStored(id, ts, result.glyph!);
    return d;
  }
}

const l8Xmp = ParsedItem(item: 'XMP Burster', level: 8, quantity: 4);
const l7Xmp = ParsedItem(item: 'XMP Burster', level: 7);
const xmpNoLevel = ParsedItem(item: 'XMP Burster', quantity: 4);

void main() {
  test('same bonus popup read three times, one reading incomplete: one reward, best kept', () {
    final h = Harness();
    h.feed(0, glyphScreen);
    h.feed(3, regular('Szlama Ejzman', [l8Xmp]));
    final first = h.feed(4, bonus([l7Xmp, xmpNoLevel]));
    final second = h.feed(5, bonus([l7Xmp, l8Xmp]));
    final third = h.feed(6, bonus([l7Xmp, xmpNoLevel]));

    expect(first.kind, 'reward');
    expect(second.kind, 'duplicate');
    expect(second.target, 3);
    expect(second.replace, isTrue, reason: 'the L8 reading is more complete');
    expect(third.kind, 'duplicate');
    expect(third.replace, isFalse);
    expect(h.kinds.where((k) => k == 'reward').length, 2);
  });

  test('regular popup read again with a different content: same portal, same reward', () {
    final h = Harness();
    h.feed(0, regular('Szlama Ejzman', [l8Xmp]));
    final again = h.feed(2, regular('Szlama Ejzman', [xmpNoLevel]));
    expect(again.kind, 'duplicate');
    expect(again.replace, isFalse);
  });

  test('another portal is a new reward, even seconds later', () {
    final h = Harness();
    h.feed(0, regular('Portal A', [l8Xmp]));
    expect(h.feed(2, regular('Portal B', [l8Xmp])).kind, 'reward');
  });

  test('same portal after the window is a new hack', () {
    final h = Harness();
    h.feed(0, regular('Portal A', [l8Xmp]));
    expect(h.feed(200, regular('Portal A', [l8Xmp])).kind, 'reward');
  });

  test('a new regular reward means the next bonus is a new one', () {
    final h = Harness();
    h.feed(0, regular('Portal A', [l8Xmp]));
    h.feed(1, bonus([l8Xmp]));
    h.feed(10, regular('Portal B', [l7Xmp]));
    expect(h.feed(11, bonus([l8Xmp])).kind, 'reward');
  });

  test('a glyph end screen means the next bonus is a new one', () {
    final h = Harness();
    h.feed(0, bonus([l8Xmp]));
    h.feed(12, glyphScreen.withCommand('LESS'));
    expect(h.feed(20, bonus([l8Xmp])).kind, 'reward');
  });

  test('glyph end screen is linked to the bonus that follows', () {
    final h = Harness();
    h.feed(0, glyphScreen);
    expect(h.linker.takePendingGlyph(5000)?.result.hackBonus, 80);
    expect(h.linker.takePendingGlyph(6000), isNull);
  });

  test('state restored from storage matches a later reading', () {
    final linker = PopupLinker()..restoreReward(7, 0, bonus: true, score: 3);
    final d = linker.classify(timestamp: 4000, result: bonus([l7Xmp, l8Xmp]));
    expect(d.kind, 'duplicate');
    expect(d.target, 7);
    expect(d.replace, isTrue);
  });
}

extension on ParseResult {
  ParseResult withCommand(String command) => ParseResult(
        const [],
        glyph: GlyphResult(hackBonus: glyph!.hackBonus, speedBonus: glyph!.speedBonus, command: command),
      );
}
