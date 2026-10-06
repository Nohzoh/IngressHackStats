import '../models/ocr_capture.dart';
import 'item_catalog.dart';

class ParsedItem {
  const ParsedItem({
    required this.item,
    this.level,
    this.rarity,
    this.quantity = 1,
    this.bonus = false,
  });

  final String item;
  final int? level;
  final String? rarity;
  final int quantity;

  /// Glyph-hack bonus items (listed after a "bonus" heading).
  final bool bonus;

  String get key => '$item|${level ?? ''}|${rarity ?? ''}';

  ParsedItem withQuantity(int q) =>
      ParsedItem(item: item, level: level, rarity: rarity, quantity: q, bonus: bonus);

  @override
  String toString() {
    final buf = StringBuffer(item);
    if (level != null) buf.write(' L$level');
    if (rarity != null) buf.write(' (${Rarity.label(rarity!)})');
    if (quantity != 1) buf.write(' ×$quantity');
    if (bonus) buf.write(' [bonus]');
    return buf.toString();
  }
}

class ParseResult {
  const ParseResult(this.items) : rejectReason = null;
  const ParseResult.rejected(String reason)
      : items = const [],
        rejectReason = reason;

  final List<ParsedItem> items;
  final String? rejectReason;

  bool get isHack => rejectReason == null && items.isNotEmpty;

  /// Stable identity of the loot, used to drop the same popup read twice.
  String get signature {
    final parts = items
        .map((i) => '${i.key}x${i.quantity}${i.bonus ? 'b' : ''}')
        .toList()
      ..sort();
    return parts.join(';');
  }
}

/// Turns the OCR lines of a frame into a list of hacked items.
///
/// Lines are first grouped into visual rows (same height on screen), so an
/// item name and its "x2" counter end up on the same row even when ML Kit
/// returns them as separate lines.
class HackParser {
  HackParser({CatalogMatcher? matcher}) : _matcher = matcher ?? CatalogMatcher();

  final CatalogMatcher _matcher;

  /// More than this on one screen is an inventory-like list, not a hack.
  static const maxItemsPerHack = 40;

  static final _level = RegExp(r'(^|[^a-z0-9])l\s?([1-8])($|[^0-9])');
  static final _quantity = RegExp(r'(^|\s)x\s?(\d{1,3})($|\s)|(^|\s)(\d{1,3})\s?x($|\s)');
  static final _quantityOnly = RegExp(r'^(?:x\s?(\d{1,3})|(\d{1,3})\s?x)$');

  ParseResult parse(List<OcrLine> lines, {double screenHeight = 0}) {
    final tolerance = screenHeight > 0 ? screenHeight * 0.012 : 12.0;
    final rows = groupRows(lines, tolerance: tolerance).map(normalize).toList();

    final all = rows.join('\n');
    for (final marker in kNonHackMarkers) {
      if (all.contains(marker)) return ParseResult.rejected('marker:$marker');
    }

    final items = <ParsedItem>[];
    var bonus = false;
    for (final row in rows) {
      if (row.contains('bonus')) bonus = true;
      final type = _matcher.match(row);
      if (type == null) {
        final q = quantityOnly(row);
        if (q != null && items.isNotEmpty) {
          items[items.length - 1] = items.last.withQuantity(q);
        }
        continue;
      }
      final level = type.leveled ? parseLevel(row) : null;
      final withoutLevel = row.replaceAll(_level, ' ');
      items.add(ParsedItem(
        item: type.name,
        level: level,
        rarity: (type.hasRarity ? parseRarity(row) : null) ?? type.defaultRarity,
        quantity: parseQuantity(withoutLevel) ?? 1,
        bonus: bonus,
      ));
    }

    if (items.length > maxItemsPerHack) return const ParseResult.rejected('too_many_items');
    return ParseResult(items);
  }

  static String normalize(String text) => text
      .toLowerCase()
      .replaceAll('×', 'x')
      .replaceAll(RegExp(r'[–—]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<String> groupRows(List<OcrLine> lines, {required double tolerance}) {
    final sorted = [...lines]..sort((a, b) => a.centerY.compareTo(b.centerY));
    final rows = <List<OcrLine>>[];
    for (final line in sorted) {
      if (rows.isNotEmpty && (line.centerY - rows.last.first.centerY).abs() <= tolerance) {
        rows.last.add(line);
      } else {
        rows.add([line]);
      }
    }
    return [
      for (final row in rows)
        (row..sort((a, b) => a.x.compareTo(b.x))).map((l) => l.text).join(' '),
    ];
  }

  static int? parseLevel(String row) {
    final m = _level.firstMatch(row);
    return m == null ? null : int.parse(m.group(2)!);
  }

  static String? parseRarity(String row) {
    if (row.contains('very rare') || RegExp(r'(^|[^a-z])vr([^a-z]|$)').hasMatch(row)) {
      return Rarity.veryRare;
    }
    if (RegExp(r'(^|[^a-z])rare([^a-z]|$)').hasMatch(row)) return Rarity.rare;
    if (row.contains('common')) return Rarity.common;
    return null;
  }

  static int? parseQuantity(String row) {
    final m = _quantity.firstMatch(row);
    if (m == null) return null;
    return int.parse(m.group(2) ?? m.group(5)!);
  }

  static int? quantityOnly(String row) {
    final m = _quantityOnly.firstMatch(row.trim());
    if (m == null) return null;
    return int.parse(m.group(1) ?? m.group(2)!);
  }
}
