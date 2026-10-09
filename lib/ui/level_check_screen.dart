import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../parsing/portal_level.dart';
import '../stats/reward_stats.dart';

/// How reliable the portal level estimate is: on rewards containing a
/// Power Cube (whose level is the portal level), compares the real level
/// with what the other items alone would have given.
class LevelCheckScreen extends StatefulWidget {
  const LevelCheckScreen({super.key, required this.repository});

  final RewardRepository repository;

  @override
  State<LevelCheckScreen> createState() => _LevelCheckScreenState();
}

class _LevelCheckScreenState extends State<LevelCheckScreen> {
  late final Future<PortalLevelCheck> _check = widget.repository.portalLevelCheck();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Niveau du portail')),
      body: FutureBuilder<PortalLevelCheck>(
        future: _check,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          final check = snapshot.data;
          if (check == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Le popup n’indique pas le niveau du portail. Quand une récompense contient un Power Cube, '
                'son niveau est celui du portail : c’est alors certain. Sinon, le niveau est estimé comme '
                'le plus fréquent parmi les objets reçus.\n\n'
                'Ici, sur les récompenses avec un cube, on compare le vrai niveau à ce que l’estimation '
                'aurait donné sans le cube : c’est la fiabilité de l’estimation pour les récompenses sans cube.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (check.total == 0)
                const Text('Aucune récompense avec un Power Cube pour l’instant.')
              else ...[
                _summary(context, check),
                const SizedBox(height: 16),
                if (check.withEstimate > 0) _matrix(context, check),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summary(BuildContext context, PortalLevelCheck check) {
    final text = Theme.of(context).textTheme;
    final n = check.withEstimate;
    String pct(int k) => n == 0 ? '—' : formatPercent(k / n);
    Widget line(String label, String value, {String? hint}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (hint != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text(hint, style: text.bodySmall)),
            ],
          ),
        );
    final bias = check.bias;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${check.total} récompenses avec un cube', style: text.titleMedium),
            if (check.total > n)
              Text('dont ${check.total - n} sans autre objet à niveau (pas d’estimation possible)',
                  style: text.bodySmall),
            const Divider(height: 24),
            line('Estimation exacte', pct(check.exact), hint: '${check.exact}/$n'),
            line('Décalée d’un niveau', pct(check.offByOne), hint: '${check.offByOne}/$n'),
            line('Décalée de 2 ou plus', pct(check.offMore), hint: '${check.offMore}/$n'),
            const Divider(height: 24),
            Text(
              bias.abs() < 0.05
                  ? 'Pas de tendance : l’estimation n’est ni trop haute ni trop basse en moyenne.'
                  : 'En moyenne, l’estimation est trop ${bias > 0 ? 'haute' : 'basse'} de '
                      '${bias.abs().toStringAsFixed(2).replaceAll('.', ',')} niveau.',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// Rows: real level (cube). Columns: estimated level.
  Widget _matrix(BuildContext context, PortalLevelCheck check) {
    final theme = Theme.of(context);
    final real = check.realLevels;
    final est = check.estimatedLevels;
    const cell = 40.0;
    Widget box(Widget child, {Color? color}) => Container(
          width: cell,
          height: cell,
          alignment: Alignment.center,
          color: color,
          child: child,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Détail : niveau réel (lignes) et niveau estimé (colonnes)', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            children: [
              Row(children: [
                box(Text('réel', style: theme.textTheme.labelSmall)),
                for (final e in est) box(Text('P$e', style: theme.textTheme.labelMedium)),
              ]),
              for (final r in real)
                Row(children: [
                  box(Text('P$r', style: theme.textTheme.labelMedium)),
                  for (final e in est)
                    Builder(builder: (context) {
                      final k = check.count(r, e);
                      final color = k == 0
                          ? null
                          : (r == e ? theme.colorScheme.primaryContainer : theme.colorScheme.errorContainer)
                              .withValues(alpha: (0.4 + 0.6 * (k / check.withEstimate)).clamp(0.0, 1.0).toDouble());
                      return box(Text(k == 0 ? '·' : '$k'), color: color);
                    }),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}
