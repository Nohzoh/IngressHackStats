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

  /// Glyph-hack bonus item (from the "Bonus items:" popup).
  final bool bonus;

  String get key => '$item|${level ?? ''}|${rarity ?? ''}';

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

/// Ito En transmuter installed on the hacked portal, as announced by the
/// "ITO EN (+) applied." / "ITO EN (-) applied." line of the popup.
abstract final class Transmuter {
  static const plus = 'plus';
  static const minus = 'minus';

  static String label(String value) => value == plus ? 'Ito En +' : 'Ito En −';
}

class ParseResult {
  const ParseResult(
    this.items, {
    this.portalName,
    this.isBonusPopup = false,
    this.transmuter,
  }) : rejectReason = null;
  const ParseResult.rejected(String reason)
      : items = const [],
        portalName = null,
        isBonusPopup = false,
        transmuter = null,
        rejectReason = reason;

  final List<ParsedItem> items;

  /// Title of the result popup: the portal name for a regular hack.
  final String? portalName;

  /// The second popup of a glyph hack, titled "Bonus items:".
  final bool isBonusPopup;

  /// [Transmuter.plus], [Transmuter.minus] or null.
  final String? transmuter;

  final String? rejectReason;

  bool get isHack => rejectReason == null && items.isNotEmpty;

  /// Identity of the popup, used to count the same popup read on several
  /// frames only once.
  String get signature {
    final parts = items.map((i) => '${i.key}x${i.quantity}').toList()..sort();
    return '${isBonusPopup ? 'BONUS' : portalName ?? ''}#${parts.join(';')}';
  }
}

/// Turns the OCR lines of a frame into the content of a hack result popup.
///
/// Popup layout (Ingress Prime, English UI):
///
///     Szlama Ejzman                          ← portal name, or "Bonus items:"
///     ITO EN (-) applied.                    ← only with a transmuter
///     [icon] L1 x1 Power Cube | [icon] L1 x1 Resonator
///     [icon] L2 x1 Resonator  | [icon] L1 x2 Resonator
///
/// Items sit in two columns, so a visual row can hold two items. Each item is
/// "[level] x<quantity> <name>"; the "x<quantity>" token is what separates
/// popup items from other text on screen (COMM, alerts).
class HackParser {
  HackParser({CatalogMatcher? matcher}) : _matcher = matcher ?? CatalogMatcher();

  final CatalogMatcher _matcher;

  /// More than this on one screen is an inventory-like list, not a hack.
  static const maxItemsPerHack = 40;

  static final _level = RegExp(r'(^|[^a-z0-9])l\s?([1-8])($|[^0-9])');
  static final _quantity = RegExp(r'(^|\s)x\s?(\d{1,3})($|\s)');
  static final _quantityToken = RegExp(r'^x\d{1,3}$');
  static final _levelToken = RegExp(r'^l[1-8]$');
  static const _rarityTokens = {'common', 'rare', 'vr'};
  static final _itoEn = RegExp(r'it[o0]\s?en\s*\(?\s*([+-])');

  ParseResult parse(List<OcrLine> lines, {double screenHeight = 0}) {
    final tolerance = screenHeight > 0 ? screenHeight * 0.012 : 12.0;
    final rawRows = groupRows(lines, tolerance: tolerance);
    final rows = rawRows.map(normalize).toList();

    final all = rows.join('\n');
    for (final marker in kNonHackMarkers) {
      if (all.contains(marker)) return ParseResult.rejected('marker:$marker');
    }

    final isBonusPopup = rows.any((r) => r.contains('bonus item'));
    final items = <ParsedItem>[];
    int? firstItemRow;
    for (var i = 0; i < rows.length; i++) {
      for (final segment in segments(rows[i])) {
        final item = _parseSegment(segment, bonus: isBonusPopup);
        if (item == null) continue;
        items.add(item);
        firstItemRow ??= i;
      }
    }

    if (items.isEmpty) return const ParseResult([]);
    if (items.length > maxItemsPerHack) return const ParseResult.rejected('too_many_items');

    final first = firstItemRow!;
    String? transmuter;
    String? portalName;
    // Header lines between the title and the items ("ITO EN (-) applied.").
    for (var k = first - 1; k >= 0; k--) {
      final row = rows[k];
      final ito = _itoEn.firstMatch(row);
      if (ito != null) {
        transmuter = ito.group(1) == '+' ? Transmuter.plus : Transmuter.minus;
        continue;
      }
      if (row.contains('applied')) continue;
      if (!isBonusPopup && rawRows[k].trim().isNotEmpty) portalName = rawRows[k].trim();
      break;
    }
    return ParseResult(
      items,
      portalName: portalName,
      isBonusPopup: isBonusPopup,
      transmuter: transmuter,
    );
  }

  ParsedItem? _parseSegment(String segment, {required bool bonus}) {
    final type = _matcher.match(segment);
    if (type == null) return null;
    final withoutLevel = segment.replaceAll(_level, ' ');
    return ParsedItem(
      item: type.name,
      level: type.leveled ? parseLevel(segment) : null,
      rarity: (type.hasRarity ? parseRarity(segment) : null) ?? type.defaultRarity,
      quantity: parseQuantity(withoutLevel) ?? 1,
      bonus: bonus,
    );
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

  /// Splits a normalized row into items, each starting at its optional
  /// level / rarity prefix followed by an "x<quantity>" token:
  /// "l1 x1 power cube l1 x1 resonator" → ["l1 x1 power cube", "l1 x1 resonator"].
  /// Rows without a quantity token yield nothing.
  static List<String> segments(String row) {
    final tokens = row.split(' ');
    final starts = <int>[];
    for (var i = 0; i < tokens.length; i++) {
      if (!_quantityToken.hasMatch(tokens[i])) continue;
      var start = i;
      if (start > 0 && _levelToken.hasMatch(tokens[start - 1])) {
        start--;
      } else if (start > 0 && _rarityTokens.contains(tokens[start - 1])) {
        start--;
        if (tokens[start] == 'rare' && start > 0 && tokens[start - 1] == 'very') start--;
      }
      if (starts.isNotEmpty && start <= starts.last) start = i;
      starts.add(start);
    }
    return [
      for (var k = 0; k < starts.length; k++)
        tokens.sublist(starts[k], k + 1 < starts.length ? starts[k + 1] : tokens.length).join(' '),
    ];
  }

  static int? parseLevel(String text) {
    final m = _level.firstMatch(text);
    return m == null ? null : int.parse(m.group(2)!);
  }

  static String? parseRarity(String text) {
    if (text.contains('very rare') || RegExp(r'(^|[^a-z])vr([^a-z]|$)').hasMatch(text)) {
      return Rarity.veryRare;
    }
    if (RegExp(r'(^|[^a-z])rare([^a-z]|$)').hasMatch(text)) return Rarity.rare;
    if (text.contains('common')) return Rarity.common;
    return null;
  }

  static int? parseQuantity(String text) {
    final m = _quantity.firstMatch(text);
    return m == null ? null : int.parse(m.group(2)!);
  }
}
