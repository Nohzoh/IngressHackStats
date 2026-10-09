import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../parsing/item_catalog.dart';
import '../stats/item_detail.dart';
import '../stats/reward_stats.dart';
import 'app_controller.dart';
import 'common.dart';
import 'item_detail_screen.dart';
import 'level_check_screen.dart';

/// Chances per item, grouped by family, for one type of reward.
class StatsTab extends StatefulWidget {
  const StatsTab({super.key, required this.controller});

  final AppController controller;

  @override
  State<StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<StatsTab> {
  AppController get c => widget.controller;

  RewardFilter _filter = const RewardFilter();
  RewardStats? _stats;
  int _loadedVersion = -1;

  /// Below this many rewards the figures are only indicative.
  static const _reliableFrom = DetailCell.reliableFrom;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (c.dataVersion != _loadedVersion) _load();
  }

  Future<void> _load() async {
    final repo = c.repository;
    if (repo == null) return;
    _loadedVersion = c.dataVersion;
    final stats = await repo.stats(_filter);
    if (mounted) setState(() => _stats = stats);
  }

  void _setFilter(RewardFilter filter) {
    setState(() => _filter = filter);
    _load();
  }

  RewardFilter _with({RewardType? type, Object? portalLevel = _keep, TransmuterFilter? transmuter, GlyphFilter? glyph}) =>
      RewardFilter(
        type: type ?? _filter.type,
        portalLevel: identical(portalLevel, _keep) ? _filter.portalLevel : portalLevel as int?,
        transmuter: transmuter ?? _filter.transmuter,
        glyph: glyph ?? _filter.glyph,
      );

  static const _keep = Object();

  bool get _computed => _filter.type == RewardType.glyphHack;
  String get _unit => _computed ? 'hack' : 'réc.';

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(title: const Text('Stats'), actions: [settingsAction(context, c)]),
      body: RefreshIndicator(
        onRefresh: () async {
          await c.sync();
          await _load();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _typeSelector(),
            const SizedBox(height: 8),
            _filterSummary(context),
            const SizedBox(height: 8),
            if (stats != null) _sampleCard(context, stats),
            if (stats != null) ..._groups(context, stats),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- filters

  Widget _typeSelector() => SegmentedButton<RewardType>(
        segments: const [
          ButtonSegment(value: RewardType.regular, label: Text('Normale')),
          ButtonSegment(value: RewardType.bonus, label: Text('Bonus')),
          ButtonSegment(value: RewardType.glyphHack, label: Text('Hack + glyph')),
        ],
        selected: {_filter.type == RewardType.all ? RewardType.regular : _filter.type},
        showSelectedIcon: false,
        onSelectionChanged: (s) => _setFilter(_with(type: s.first)),
      );

  List<String> get _activeFilters => [
        if (_filter.transmuter != TransmuterFilter.all) 'Ito En ${_transmuterLabel(_filter.transmuter)}',
        if (_filter.portalLevel != null) 'P${_filter.portalLevel}',
        if (_filter.usesGlyph && _filter.glyph != GlyphFilter.all) 'Glyph ${_filter.glyph.label.toLowerCase()}',
      ];

  Widget _filterSummary(BuildContext context) {
    final active = _activeFilters;
    return Row(
      children: [
        ActionChip(
          avatar: const Icon(Icons.tune, size: 18),
          label: Text(active.isEmpty ? 'Filtres' : active.join(' · ')),
          onPressed: () => _openFilters(context),
        ),
        if (active.isNotEmpty)
          IconButton(
            tooltip: 'Réinitialiser',
            icon: const Icon(Icons.close),
            onPressed: () => _setFilter(RewardFilter(type: _filter.type)),
          ),
      ],
    );
  }

  static String _transmuterLabel(TransmuterFilter t) => switch (t) {
        TransmuterFilter.all => 'tous',
        TransmuterFilter.plus => '+',
        TransmuterFilter.minus => '−',
        TransmuterFilter.none => 'aucun',
      };

  Future<void> _openFilters(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheet) {
            void apply(RewardFilter f) {
              _setFilter(f);
              setSheet(() {});
            }

            Widget section(String title, List<Widget> chips) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: chips),
                    ],
                  ),
                );

            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    section('Ito En sur le portail', [
                      for (final t in TransmuterFilter.values)
                        ChoiceChip(
                          label: Text(t == TransmuterFilter.all ? 'Tous' : _transmuterLabel(t)),
                          selected: _filter.transmuter == t,
                          onSelected: (_) => apply(_with(transmuter: t)),
                        ),
                    ]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Text(
                        'Le niveau du portail vient d’un Power Cube quand il y en a un (certain), '
                        'sinon il est estimé d’après les autres objets.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => LevelCheckScreen(repository: c.repository!)),
                        ),
                        child: const Text('Fiabilité de l’estimation'),
                      ),
                    ),
                    section('Niveau du portail', [
                      for (final l in <int?>[null, 1, 2, 3, 4, 5, 6, 7, 8])
                        ChoiceChip(
                          label: Text(l == null ? 'Tous' : 'P$l'),
                          selected: _filter.portalLevel == l,
                          onSelected: (_) => apply(_with(portalLevel: l)),
                        ),
                    ]),
                    if (_filter.usesGlyph)
                      section('Qualité du glyph (récompenses bonus)', [
                        for (final g in GlyphFilter.values)
                          ChoiceChip(
                            label: Text(g.label),
                            selected: _filter.glyph == g,
                            onSelected: (_) => apply(_with(glyph: g)),
                          ),
                      ]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => apply(RewardFilter(type: _filter.type)),
                            child: const Text('Réinitialiser'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

  // -------------------------------------------------------------- sample

  Widget _sampleCard(BuildContext context, RewardStats stats) {
    final text = Theme.of(context).textTheme;
    final what = switch (_filter.type) {
      RewardType.bonus => 'récompenses bonus',
      RewardType.glyphHack => 'hacks avec glyph (au moins)',
      _ => 'récompenses normales',
    };
    final weak = stats.rewards < _reliableFrom;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('${stats.rewards}', style: text.headlineMedium),
                const SizedBox(width: 8),
                Expanded(child: Text(what, style: text.bodyLarge)),
                Text('${stats.itemsPerReward.toStringAsFixed(1).replaceAll('.', ',')} objets / $_unit',
                    style: text.bodySmall),
              ],
            ),
            if (_computed)
              Text(
                'Calculé : une récompense normale + une bonus, tirages supposés indépendants.',
                style: text.bodySmall,
              ),
            if (weak && stats.rewards > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Échantillon encore faible (moins de $_reliableFrom) : valeurs indicatives.',
                  style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- items

  List<Widget> _groups(BuildContext context, RewardStats stats) {
    if (stats.rewards == 0) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aucune récompense pour ces filtres.', textAlign: TextAlign.center),
        ),
      ];
    }
    final faded = stats.rewards < _reliableFrom;
    final widgets = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(
          _computed
              ? 'Par hack avec glyph : quantité moyenne si fréquent, sinon 1 hack sur N'
              : 'Par récompense : quantité moyenne si fréquent, sinon 1 récompense sur N',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
    for (final family in ItemFamily.values) {
      final totals = [for (final t in stats.totals) if (ItemFamily.of(t.item) == family) t];
      if (totals.isEmpty) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(family.label, style: Theme.of(context).textTheme.titleSmall),
      ));
      widgets.add(Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            for (final total in totals) _itemTile(context, total, _sortedVariants(stats.variantsOf(total.item)), faded),
          ],
        ),
      ));
    }
    return widgets;
  }

  Widget _headline(BuildContext context, ItemStat s, bool faded, {bool small = false}) {
    final theme = Theme.of(context);
    final style = (small ? theme.textTheme.bodyMedium : theme.textTheme.titleMedium)?.copyWith(
      fontWeight: FontWeight.w600,
      color: faded ? theme.disabledColor : null,
    );
    return Text(formatChance(s.presence, s.perReward, unit: _unit), style: style);
  }

  String _details(ItemStat s) => [
        'chance ${formatPercent(s.presence)} ± ${formatPercent(s.presenceMargin)}',
        if (s.share != null) 'part ${formatPercent(s.share!)}',
      ].join(' · ');

  void _open(String item) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ItemDetailScreen(repository: c.repository!, item: item, initialFilter: _filter),
        ),
      );

  Widget _itemTile(BuildContext context, ItemStat total, List<ItemStat> variants, bool faded) {
    final split = variants.length > 1 || variants.any((v) => v.level != null);
    if (!split) {
      return ListTile(
        title: Text(total.item),
        subtitle: Text(_details(total)),
        trailing: _headline(context, total, faded),
        onTap: () => _open(total.item),
      );
    }
    return ExpansionTile(
      shape: const Border(),
      title: Text(total.item),
      subtitle: Text(_details(total)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [_headline(context, total, faded), const Icon(Icons.expand_more)],
      ),
      children: [
        for (final v in variants)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 40),
            title: Text(_variantLabel(v)),
            subtitle: Text(_details(v)),
            trailing: _headline(context, v, faded, small: true),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _open(total.item),
            icon: const Icon(Icons.grid_on, size: 18),
            label: const Text('Fiche par niveau de portail'),
          ),
        ),
      ],
    );
  }

  /// Highest level first, then rarities from common to very rare.
  static List<ItemStat> _sortedVariants(List<ItemStat> variants) {
    int rank(ItemStat v) => v.level != null
        ? 100 - v.level!
        : switch (v.rarity) {
            Rarity.common => 200,
            Rarity.rare => 201,
            Rarity.veryRare => 202,
            _ => 300,
          };
    return [...variants]..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  static String _variantLabel(ItemStat v) {
    if (v.level != null) return 'L${v.level}';
    if (v.rarity != null) return Rarity.label(v.rarity!);
    return 'Niveau non lu';
  }
}
