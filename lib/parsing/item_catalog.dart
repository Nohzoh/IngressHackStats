/// Item names as they appear in the game (English UI).
///
/// Aliases are lower-case; the parser matches the longest alias first, so
/// "aegis shield" wins over "shield". If the OCR reads names differently on
/// your device, add the variant to the aliases (and to ITEM_KEYWORDS in
/// CaptureService.kt so the native pre-filter lets it through).
class ItemType {
  const ItemType(
    this.name,
    this.aliases, {
    this.leveled = false,
    this.hasRarity = false,
    this.defaultRarity,
  });

  final String name;
  final List<String> aliases;

  /// Resonators, bursters, strikes, cubes: shown with a level (L1–L8).
  final bool leveled;

  /// Mods available in several rarities (Common / Rare / Very Rare).
  final bool hasRarity;

  /// Rarity for items that only exist in one rarity.
  final String? defaultRarity;
}

abstract final class Rarity {
  static const common = 'common';
  static const rare = 'rare';
  static const veryRare = 'very_rare';

  static String label(String rarity) => switch (rarity) {
        common => 'Commun',
        rare => 'Rare',
        veryRare => 'Très rare',
        _ => rarity,
      };
}

const List<ItemType> kItemCatalog = [
  ItemType('Resonator', ['resonator'], leveled: true),
  ItemType('XMP Burster', ['xmp burster', 'xmp'], leveled: true),
  ItemType('Ultra Strike', ['ultra strike'], leveled: true),
  ItemType('Power Cube', ['power cube'], leveled: true),
  ItemType('Hypercube', ['hypercube', 'hyper cube'], defaultRarity: Rarity.veryRare),
  ItemType('Portal Key', ['portal key']),
  ItemType('Portal Shield', ['portal shield', 'shield'], hasRarity: true),
  ItemType('Aegis Shield', ['aegis shield', 'aegis'], defaultRarity: Rarity.veryRare),
  ItemType('Heat Sink', ['heat sink', 'heatsink'], hasRarity: true),
  ItemType('Multi-hack', ['multi-hack', 'multihack', 'multi hack'], hasRarity: true),
  ItemType('Link Amp', ['link amp'], hasRarity: true, defaultRarity: Rarity.rare),
  ItemType('SoftBank Ultra Link', ['softbank ultra link', 'ultra link'], defaultRarity: Rarity.veryRare),
  ItemType('Force Amp', ['force amp'], defaultRarity: Rarity.rare),
  ItemType('Turret', ['turret'], defaultRarity: Rarity.rare),
  ItemType('Ito En Transmuter', ['ito en transmuter', 'ito en', 'transmuter'], defaultRarity: Rarity.veryRare),
  ItemType('ADA Refactor', ['ada refactor'], defaultRarity: Rarity.veryRare),
  ItemType('JARVIS Virus', ['jarvis virus', 'jarvis'], defaultRarity: Rarity.veryRare),
  ItemType('Portal Fracker', ['portal fracker', 'fracker'], defaultRarity: Rarity.veryRare),
  ItemType('Beacon', ['beacon']),
  ItemType('Key Locker', ['key locker']),
  ItemType('Capsule', ['quantum capsule', 'kinetic capsule', 'capsule']),
];

/// Words that only appear on screens that are not a hack result (inventory,
/// recycling…). A frame containing one of them is ignored. To calibrate.
const List<String> kNonHackMarkers = [
  'inventory',
  'recycle',
];

class CatalogMatcher {
  CatalogMatcher([List<ItemType> catalog = kItemCatalog]) {
    for (final type in catalog) {
      for (final alias in type.aliases) {
        _entries.add(_Entry(type, alias, _wordPattern(alias)));
      }
    }
    _entries.sort((a, b) => b.alias.length.compareTo(a.alias.length));
  }

  final List<_Entry> _entries = [];

  /// Returns the item named in [normalizedText], if any.
  ItemType? match(String normalizedText) {
    for (final e in _entries) {
      if (e.pattern.hasMatch(normalizedText)) return e.type;
    }
    return null;
  }

  static RegExp _wordPattern(String alias) =>
      RegExp('(^|[^a-z])${RegExp.escape(alias)}(\$|[^a-z])');
}

class _Entry {
  _Entry(this.type, this.alias, this.pattern);
  final ItemType type;
  final String alias;
  final RegExp pattern;
}

/// Groups of items for the stats list, in display order.
enum ItemFamily {
  weapons('Armes'),
  resonators('Résonateurs'),
  cubes('Cubes'),
  mods('Mods'),
  keys('Clés'),
  special('Spéciaux');

  const ItemFamily(this.label);
  final String label;

  static ItemFamily of(String item) => switch (item) {
        'XMP Burster' || 'Ultra Strike' => weapons,
        'Resonator' => resonators,
        'Power Cube' || 'Hypercube' => cubes,
        'Portal Shield' ||
        'Aegis Shield' ||
        'Heat Sink' ||
        'Multi-hack' ||
        'Link Amp' ||
        'SoftBank Ultra Link' ||
        'Force Amp' ||
        'Turret' ||
        'Ito En Transmuter' =>
          mods,
        'Portal Key' => keys,
        _ => special,
      };
}
