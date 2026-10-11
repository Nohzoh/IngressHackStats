import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../stats/loot_effect.dart';
import 'item_detail_screen.dart';

const _explanation =
    'On compare le nombre d’autres objets (l’objet lui-même exclu) entre les récompenses qui '
    'contiennent l’objet et celles qui ne le contiennent pas, à conditions égales : même type de '
    'récompense, même Ito En et, pour les bonus, même qualité de glyph et même commande.\n'
    '• Écart proche de 0 : l’objet s’ajoute aux autres.\n'
    '• Écart négatif : il prend la place d’autres objets (jusqu’à −1 par exemplaire si la taille '
    'de la récompense est fixe).\n'
    '• Écart positif : il sort plutôt dans les grosses récompenses.\n'
    'La marge (±) est à 95 % ; elle se resserre avec le nombre de hacks. '
    'Un objet manqué par l’OCR fausse le compte : supprime les récompenses mal lues dans l’historique.';

/// Color of a verdict.
Color? _verdictColor(BuildContext context, LootVerdict v) {
  final scheme = Theme.of(context).colorScheme;
  return switch (v) {
    LootVerdict.takesPlace => scheme.error,
    LootVerdict.biggerRewards => scheme.primary,
    LootVerdict.noEffect => null,
    LootVerdict.notEnoughData => Theme.of(context).disabledColor,
  };
}

/// "−0,8 ± 0,3"
String _differenceText(LootEffect e) =>
    e.difference.isNaN ? '—' : '${formatDecimal(e.difference, signed: true)} ± ${formatDecimal(e.margin)}';

/// Card of the item sheet: effect of the item on the rest of its reward.
class LootEffectCard extends StatelessWidget {
  const LootEffectCard({super.key, required this.regular, required this.bonus});

  final LootEffect? regular;
  final LootEffect? bonus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text('Effet sur le reste de la récompense', style: text.titleSmall)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.info_outline, size: 20),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Effet sur le reste'),
                      content: const SingleChildScrollView(child: Text(_explanation)),
                      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                    ),
                  ),
                ),
              ]),
              _line(context, 'Normale', regular),
              const SizedBox(height: 8),
              _line(context, 'Bonus', bonus),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, LootEffect? e) {
    final text = Theme.of(context).textTheme;
    if (e == null || e.rewardsWith == 0) {
      return Text('$label : jamais obtenu', style: text.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: '$label : ', style: text.labelLarge),
          TextSpan(
            text: e.verdict.label,
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: _verdictColor(context, e.verdict)),
          ),
        ])),
        Text(
          'Avec : ${formatDecimal(e.othersWith)} autres objets (n=${e.rewardsWith}) · '
          'sans : ${formatDecimal(e.othersWithout)} (n=${e.rewardsWithout})',
          style: text.bodySmall,
        ),
        Text('Écart à conditions égales : ${_differenceText(e)}', style: text.bodySmall),
      ],
    );
  }
}

/// Every item, sorted by its effect on the rest of the reward.
class LootEffectScreen extends StatefulWidget {
  const LootEffectScreen({super.key, required this.repository});

  final RewardRepository repository;

  @override
  State<LootEffectScreen> createState() => _LootEffectScreenState();
}

class _LootEffectScreenState extends State<LootEffectScreen> {
  late final _effects = widget.repository.lootEffects(const RewardFilter());
  bool _bonus = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Effet sur le reste')),
      body: FutureBuilder(
        future: _effects,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final list = (_bonus ? data.bonus : data.regular).values.where((e) => e.rewardsWith > 0).toList()
            ..sort(_compare);
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Quand un objet sort, y a-t-il moins d’autres objets dans la récompense ?',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Normale')),
                    ButtonSegment(value: true, label: Text('Bonus')),
                  ],
                  selected: {_bonus},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _bonus = s.first),
                ),
              ),
              if (list.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('Pas encore de données.')),
              for (final e in list) _tile(context, e),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Text(_explanation, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Conclusive results first, most negative difference first.
  static int _compare(LootEffect a, LootEffect b) {
    final ua = a.verdict == LootVerdict.notEnoughData, ub = b.verdict == LootVerdict.notEnoughData;
    if (ua != ub) return ua ? 1 : -1;
    if (ua) return b.rewardsWith.compareTo(a.rewardsWith);
    return a.difference.compareTo(b.difference);
  }

  Widget _tile(BuildContext context, LootEffect e) {
    final text = Theme.of(context).textTheme;
    final color = _verdictColor(context, e.verdict);
    return ListTile(
      title: Text(e.item),
      subtitle: Text(
        '${e.verdict.label} · avec ${formatDecimal(e.othersWith)} / sans ${formatDecimal(e.othersWithout)} '
        'autres objets · n=${e.rewardsWith}',
      ),
      trailing: Text(
        e.difference.isNaN ? '—' : _differenceText(e),
        style: text.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ItemDetailScreen(repository: widget.repository, item: e.item)),
      ),
    );
  }
}
