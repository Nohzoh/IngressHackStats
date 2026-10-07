import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../stats/item_detail.dart';
import '../stats/reward_stats.dart';

/// One item: chance to get it by portal level, item level (or rarity) and
/// reward type.
class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({
    super.key,
    required this.repository,
    required this.item,
    this.initialFilter = const RewardFilter(),
  });

  final RewardRepository repository;
  final String item;
  final RewardFilter initialFilter;

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  late RewardFilter _filter = RewardFilter(
    transmuter: widget.initialFilter.transmuter,
    glyph: widget.initialFilter.glyph,
  );
  ItemDetail? _detail;
  Object? _error;

  final _types = <DetailColumnType>{DetailColumnType.regular, DetailColumnType.bonus};

  /// Hidden variant columns; null stands for "all variants".
  final _hiddenVariants = <String?>{};

  static const _rowHeight = 52.0;
  static const _labelWidth = 64.0;
  static const _cellWidth = 92.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.repository.itemDetail(widget.item, _filter);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _setFilter(RewardFilter filter) {
    setState(() => _filter = filter);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(widget.item)),
      body: _error != null
          ? Center(child: Text('$_error'))
          : detail == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    _header(context, detail),
                    _filters(),
                    _columnChoices(detail),
                    const SizedBox(height: 8),
                    _grid(context, detail),
                    _legend(context),
                  ],
                ),
    );
  }

  // --------------------------------------------------------------- header

  Widget _header(BuildContext context, ItemDetail detail) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              for (final type in DetailColumnType.values)
                Expanded(
                  child: Builder(builder: (context) {
                    final cell = detail.cell(null, type, null);
                    return Column(
                      children: [
                        Text(type.label, style: text.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          cell.format(unit: _unit(type)),
                          style: text.titleLarge?.copyWith(color: cell.reliable ? null : Theme.of(context).disabledColor),
                        ),
                        Text(
                          cell.rewards == 0 ? 'pas de données' : '${_pct(cell.presence)} · n=${cell.rewards}',
                          style: text.bodySmall,
                        ),
                      ],
                    );
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- filters

  Widget _chipRow(String title, List<Widget> chips) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Row(children: [
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(title)),
          for (final c in chips) Padding(padding: const EdgeInsets.only(right: 6), child: c),
        ]),
      );

  Widget _filters() => Column(
        children: [
          _chipRow('Ito En', [
            for (final t in TransmuterFilter.values)
              ChoiceChip(
                label: Text(switch (t) {
                  TransmuterFilter.all => 'Tous',
                  TransmuterFilter.plus => '+',
                  TransmuterFilter.minus => '−',
                  TransmuterFilter.none => 'Aucun',
                }),
                selected: _filter.transmuter == t,
                onSelected: (_) => _setFilter(RewardFilter(transmuter: t, glyph: _filter.glyph)),
              ),
          ]),
          _chipRow('Glyph', [
            for (final g in GlyphFilter.values)
              ChoiceChip(
                label: Text(g.label),
                selected: _filter.glyph == g,
                onSelected: (_) => _setFilter(RewardFilter(transmuter: _filter.transmuter, glyph: g)),
              ),
          ]),
        ],
      );

  Widget _columnChoices(ItemDetail detail) => Column(
        children: [
          _chipRow('Colonnes', [
            for (final type in DetailColumnType.values)
              FilterChip(
                label: Text(type.label),
                selected: _types.contains(type),
                onSelected: (on) => setState(() => on ? _types.add(type) : _types.remove(type)),
              ),
          ]),
          if (_showVariants(detail))
            _chipRow('Niveaux', [
              for (final v in <String?>[null, ...detail.variants])
                FilterChip(
                  label: Text(v == null ? 'Tous' : ItemDetail.variantLabel(v)),
                  selected: !_hiddenVariants.contains(v),
                  onSelected: (on) => setState(() => on ? _hiddenVariants.remove(v) : _hiddenVariants.add(v)),
                ),
            ]),
        ],
      );

  /// An item read without level nor rarity has nothing to split on.
  static bool _showVariants(ItemDetail d) => !(d.variants.isEmpty || (d.variants.length == 1 && d.variants.single == ''));

  // ----------------------------------------------------------------- grid

  List<(String?, DetailColumnType)> _columns(ItemDetail detail) {
    final variants = _showVariants(detail) ? <String?>[null, ...detail.variants] : <String?>[null];
    return [
      for (final v in variants)
        if (!_hiddenVariants.contains(v) || variants.length == 1)
          for (final type in DetailColumnType.values)
            if (_types.contains(type)) (v, type),
    ];
  }

  Widget _grid(BuildContext context, ItemDetail detail) {
    final columns = _columns(detail);
    final rows = <int?>[null, ...detail.levelRows];
    if (columns.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Aucune colonne affichée.', textAlign: TextAlign.center),
      );
    }
    final divider = Theme.of(context).dividerColor;
    final small = Theme.of(context).textTheme.bodySmall;

    Widget box(Widget child, {double? width, bool header = false, bool strong = false}) => Container(
          width: width,
          height: header ? 44 : _rowHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: divider, width: strong ? 1.5 : 0.5)),
          ),
          child: child,
        );

    final labels = Column(children: [
      box(Text('Portail', style: small), width: _labelWidth, header: true, strong: true),
      for (final row in rows)
        box(
          Text(_rowLabel(row), style: TextStyle(fontWeight: row == null ? FontWeight.bold : null)),
          width: _labelWidth,
          strong: row == null,
        ),
    ]);

    final table = Column(children: [
      Row(children: [
        for (final (variant, type) in columns)
          box(
            Text(
              '${variant == null ? 'Tous' : ItemDetail.variantLabel(variant)}\n${type.label}',
              textAlign: TextAlign.center,
              style: small,
            ),
            width: _cellWidth,
            header: true,
            strong: true,
          ),
      ]),
      for (final row in rows)
        Row(children: [
          for (final (variant, type) in columns)
            box(
              _cellView(context, detail.cell(row, type, variant), type, row: row, variant: variant),
              width: _cellWidth,
              strong: row == null,
            ),
        ]),
    ]);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(left: 12), child: labels),
        Expanded(
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
        ),
      ],
    );
  }

  Widget _cellView(BuildContext context, DetailCell cell, DetailColumnType type, {int? row, String? variant}) {
    final theme = Theme.of(context);
    final faded = !cell.reliable;
    return InkWell(
      onTap: cell.rewards == 0 ? null : () => _explain(context, cell, type, row: row, variant: variant),
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              cell.format(unit: _unit(type)),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: faded ? theme.disabledColor : null,
              ),
            ),
            if (cell.rewards > 0)
              Text('n=${cell.rewards}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
          ],
        ),
      ),
    );
  }

  void _explain(BuildContext context, DetailCell cell, DetailColumnType type, {int? row, String? variant}) {
    final what = [
      _rowLabel(row) == 'Tous' ? 'tous portails' : _rowLabel(row),
      variant == null ? widget.item : '${widget.item} ${ItemDetail.variantLabel(variant)}',
      type.label,
    ].join(' · ');
    final detail = type == DetailColumnType.glyphHack
        ? 'Chance par hack avec glyph : ${_pct(cell.presence)}\n'
            'Quantité moyenne : ${cell.perReward.toStringAsFixed(2)} par hack\n'
            'Calculé sur au moins ${cell.rewards} hacks (normale + bonus)'
        : 'Chance par récompense : ${_pct(cell.presence)} ± ${_pct(RewardStats.margin95(cell.rewardsWith, cell.rewards))}\n'
            'Vu dans ${cell.rewardsWith} récompenses sur ${cell.rewards}\n'
            'Quantité moyenne : ${cell.perReward.toStringAsFixed(2)} par récompense';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(what, style: Theme.of(context).textTheme.titleMedium),
        content: Text(detail),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Widget _legend(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Text(
          '« x / réc. » : quantité moyenne, quand l’objet sort au moins une fois sur deux.\n'
          '« 1/N » : en moyenne une récompense sur N le contient.\n'
          'Grisé : moins de ${DetailCell.reliableFrom} récompenses, valeur peu fiable. '
          'Touchez une case pour le détail.\n'
          'Le niveau du portail est estimé à partir des autres objets de la récompense, '
          'sans tenir compte de celui-ci. « P ? » : niveau impossible à estimer.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );

  static String _rowLabel(int? row) => switch (row) {
        null => 'Tous',
        ItemDetail.unknownRow => 'P ?',
        _ => 'P$row',
      };

  static String _unit(DetailColumnType type) => type == DetailColumnType.glyphHack ? 'hack' : 'réc.';

  static String _pct(double v) => '${(100 * v).toStringAsFixed(1).replaceAll('.', ',')} %';
}
