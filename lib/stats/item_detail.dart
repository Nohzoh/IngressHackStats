import 'dart:math' as math;

import '../parsing/item_catalog.dart';
import '../parsing/portal_level.dart';

/// What one reward tells about the studied item.
class RewardObservation {
  const RewardObservation({
    required this.id,
    required this.bonus,
    required this.otherLevels,
    required this.itemQuantities,
  });

  final int id;
  final bool bonus;

  /// Item levels of the reward *without* the studied item (level → quantity),
  /// used to estimate the portal level without circularity.
  final Map<int, int> otherLevels;

  /// Studied item received, by variant key (see [ItemDetail.variantKey]).
  final Map<String, int> itemQuantities;
}

enum DetailColumnType {
  regular,
  bonus,
  glyphHack;

  String get label => switch (this) {
        regular => 'Normale',
        bonus => 'Bonus',
        glyphHack => 'Hack + glyph',
      };
}

/// Counts behind one cell of the grid.
class DetailCell {
  const DetailCell({required this.rewards, required this.rewardsWith, required this.quantity})
      : combinedPresence = null,
        combinedPerReward = null;

  /// Regular + bonus reward of the same hack, assumed independent.
  factory DetailCell.glyphHack(DetailCell regular, DetailCell bonus) {
    if (regular.rewards == 0 || bonus.rewards == 0) {
      return const DetailCell(rewards: 0, rewardsWith: 0, quantity: 0);
    }
    return DetailCell._combined(
      rewards: math.min(regular.rewards, bonus.rewards),
      presence: 1 - (1 - regular.presence) * (1 - bonus.presence),
      perReward: regular.perReward + bonus.perReward,
    );
  }

  const DetailCell._combined({required this.rewards, required double presence, required double perReward})
      : rewardsWith = 0,
        quantity = 0,
        combinedPresence = presence,
        combinedPerReward = perReward;

  /// Rewards observed in this cell (hacks for the combined column).
  final int rewards;

  /// Rewards containing the item at least once.
  final int rewardsWith;
  final int quantity;
  final double? combinedPresence;
  final double? combinedPerReward;

  double get presence => combinedPresence ?? (rewards == 0 ? 0 : rewardsWith / rewards);
  double get perReward => combinedPerReward ?? (rewards == 0 ? 0 : quantity / rewards);

  /// Below this many rewards a value is shown but flagged as unreliable.
  static const reliableFrom = 30;

  bool get reliable => rewards >= reliableFrom;

  /// "1,4 / réc." when the item is common (in at least half the rewards),
  /// "1/N" when rare, N being the average number of rewards needed to get it.
  String format({String unit = 'réc.'}) {
    if (rewards == 0) return '—';
    final p = presence;
    if (p <= 0) return '0';
    if (p >= 0.5) return '${_decimal(perReward)} / $unit';
    final n = 1 / p;
    return '1/${n < 10 ? _decimal(n, digits: 1) : n.round()}';
  }

  static String _decimal(double v, {int digits = 2}) => v.toStringAsFixed(digits).replaceAll('.', ',');
}

/// Grid for one item: portal level (rows) × item variant × reward type.
class ItemDetail {
  ItemDetail._(this.item, this.variants, this._cells);

  /// Builds the grid from per-reward observations.
  factory ItemDetail.compute(String item, List<RewardObservation> rewards) {
    final variants = <String>{for (final r in rewards) ...r.itemQuantities.keys};
    final cells = <String, _Acc>{};
    _Acc acc(int? row, bool bonus, String? variant) =>
        cells.putIfAbsent(_key(row, bonus, variant), _Acc.new);

    for (final r in rewards) {
      final level = inferPortalLevel(r.otherLevels, seed: r.id) ?? unknownRow;
      final total = r.itemQuantities.values.fold(0, (a, b) => a + b);
      for (final row in [null, level]) {
        acc(row, r.bonus, null).add(total);
        for (final v in variants) {
          acc(row, r.bonus, v).add(r.itemQuantities[v] ?? 0);
        }
      }
    }
    final sorted = variants.toList()..sort(_compareVariants);
    return ItemDetail._(item, sorted, {for (final e in cells.entries) e.key: e.value.toCell()});
  }

  /// Row of the rewards whose portal level could not be estimated.
  static const unknownRow = 0;

  final String item;

  /// Variant keys seen for this item, in display order.
  final List<String> variants;
  final Map<String, DetailCell> _cells;

  /// Rows present in the data: 1–8, then [unknownRow] if any.
  List<int> get levelRows {
    final rows = <int>{};
    for (final key in _cells.keys) {
      final row = key.split('|').first;
      if (row.isNotEmpty) rows.add(int.parse(row));
    }
    return [for (var l = 1; l <= 8; l++) if (rows.contains(l)) l, if (rows.contains(unknownRow)) unknownRow];
  }

  /// [row]: portal level, null for all levels. [variant]: null for all.
  DetailCell cell(int? row, DetailColumnType type, String? variant) {
    const empty = DetailCell(rewards: 0, rewardsWith: 0, quantity: 0);
    DetailCell get(bool bonus) => _cells[_key(row, bonus, variant)] ?? empty;
    return switch (type) {
      DetailColumnType.regular => get(false),
      DetailColumnType.bonus => get(true),
      DetailColumnType.glyphHack => DetailCell.glyphHack(get(false), get(true)),
    };
  }

  /// Key of an item reading: "L8", a rarity, or "" when neither was read.
  static String variantKey({int? level, String? rarity}) =>
      level != null ? 'L$level' : rarity ?? '';

  static String variantLabel(String key) => switch (key) {
        '' => 'Sans niv.',
        _ when key.startsWith('L') => key,
        _ => Rarity.label(key),
      };

  static String _key(int? row, bool bonus, String? variant) => '${row ?? ''}|${bonus ? 1 : 0}|${variant ?? '*'}';

  static int _compareVariants(String a, String b) => _variantRank(a).compareTo(_variantRank(b));

  static int _variantRank(String v) {
    if (v.startsWith('L')) return int.tryParse(v.substring(1)) ?? 9;
    return switch (v) {
      Rarity.common => 20,
      Rarity.rare => 21,
      Rarity.veryRare => 22,
      '' => 99,
      _ => 50,
    };
  }
}

class _Acc {
  int rewards = 0;
  int rewardsWith = 0;
  int quantity = 0;

  /// Counts one reward that gave [q] of the item (0 when it gave none).
  void add(int q) {
    rewards++;
    if (q > 0) rewardsWith++;
    quantity += q;
  }

  DetailCell toCell() => DetailCell(rewards: rewards, rewardsWith: rewardsWith, quantity: quantity);
}
