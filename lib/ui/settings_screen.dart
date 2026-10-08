import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'captures_screen.dart';
import 'history_screen.dart';

/// Rarely used settings and troubleshooting, out of the main screens.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Réglages')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _section(context, 'Capture'),
            ListTile(
              title: const Text('Fréquence d’analyse'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Plus rapide : moins de popups manqués, plus de batterie'),
                  const SizedBox(height: 6),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 250, label: Text('¼ s')),
                      ButtonSegment(value: 500, label: Text('½ s')),
                      ButtonSegment(value: 1000, label: Text('1 s')),
                    ],
                    selected: {controller.ocrInterval},
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      if (s.isNotEmpty) controller.setOcrInterval(s.first);
                    },
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('Tuile des réglages rapides'),
              subtitle: Text(controller.tileAdded
                  ? 'Ajoutée : démarre ou arrête la capture depuis le jeu'
                  : 'Démarre ou arrête la capture sans quitter le jeu'),
              trailing: controller.canAddTile && !controller.tileAdded
                  ? TextButton(onPressed: () => _addTile(context), child: const Text('Ajouter'))
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Autorisations'),
              subtitle: Text(
                'Notifications : ${controller.permissions['notifications'] == true ? 'oui' : 'non'}'
                ' · Localisation : ${controller.permissions['location'] == true ? 'oui' : 'non'}',
              ),
              trailing: controller.permissions.values.every((v) => v)
                  ? null
                  : TextButton(onPressed: controller.requestPermissions, child: const Text('Autoriser')),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.tune),
              title: const Text('Mode calibration'),
              subtitle: const Text('Lit tout l’écran et enregistre tout le texte, même hors hack'),
              value: controller.debug,
              onChanged: controller.setDebug,
            ),
            _section(context, 'Données'),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Historique des récompenses'),
              subtitle: const Text('Supprimer une récompense mal lue'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => HistoryScreen(controller: controller)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('Images brutes'),
              subtitle: const Text('Texte lu par l’OCR, ré-analyse, effacement'),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => CapturesScreen(repository: controller.repository!)),
                );
                controller.dataChanged();
              },
            ),
            _section(context, 'Dépannage'),
            _diagnostics(context),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            )),
      );

  Future<void> _addTile(BuildContext context) async {
    final result = await controller.addTile();
    if (!context.mounted) return;
    final message = switch (result) {
      'added' => 'Tuile ajoutée aux réglages rapides',
      'already' => 'La tuile est déjà dans les réglages rapides',
      'refused' => 'Tuile non ajoutée',
      _ => 'Impossible d’ajouter la tuile : ajoute « Capture hacks » en modifiant les réglages rapides',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _speedLine() {
    final speed = controller.ocrSpeed;
    if (speed == null) return 'Analyse OCR : —';
    return 'Analyse OCR : ${speed.avgMs} ms en moyenne · ${speed.perSecond.toStringAsFixed(1)} / s'
        ' (réglage : ${controller.diag('ocrIntervalMs')} ms)';
  }

  Widget _diagnostics(BuildContext context) {
    int n(String key) => controller.diag(key);
    final lastText = (controller.diagnostics['lastText'] as String?) ?? '';
    final lastError = (controller.diagnostics['lastError'] as String?) ?? '';
    final kinds = controller.kinds.entries.map((e) => '${e.key} ${e.value}').join(' · ');
    final small = Theme.of(context).textTheme.bodySmall;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Images ${n('frames')} · OCR ${n('ocrRuns')} · avec texte ${n('textFrames')} · gardées ${n('kept')}',
          ),
          Text('Ignorées (app au premier plan) : ${n('skippedAppVisible')}', style: small),
          Text('Erreurs OCR : ${n('ocrErrors')}', style: small),
          Text(_speedLine(), style: small),
          if (lastError.isNotEmpty) Text('Dernière erreur : $lastError', style: small),
          Text('En base : ${kinds.isEmpty ? 'rien' : kinds}', style: small),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Journal du service', style: Theme.of(context).textTheme.labelLarge)),
              TextButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copier'),
              ),
              TextButton(
                onPressed: () async {
                  await controller.capture.clearServiceLog();
                  await controller.sync();
                },
                child: const Text('Effacer'),
              ),
            ],
          ),
          SelectableText(
            controller.serviceLog.trim().isEmpty
                ? '—'
                : controller.serviceLog.trim().split('\n').reversed.take(30).join('\n'),
            style: mono,
          ),
          const SizedBox(height: 12),
          Text('Dernier texte lu', style: Theme.of(context).textTheme.labelLarge),
          SelectableText(lastText.isEmpty ? '—' : lastText, style: mono),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Counters and the whole journal, to paste in a message.
  Future<void> _copy(BuildContext context) async {
    int n(String key) => controller.diag(key);
    final kinds = controller.kinds.entries.map((e) => '${e.key} ${e.value}').join(' · ');
    final text = [
      'Ingress Hack Stats — diagnostic',
      'Capture : ${controller.running ? 'en cours' : 'arrêtée'}',
      'Images ${n('frames')} · OCR ${n('ocrRuns')} · avec texte ${n('textFrames')} · gardées ${n('kept')}',
      'Erreurs OCR : ${n('ocrErrors')}',
      _speedLine(),
      'En base : ${kinds.isEmpty ? 'rien' : kinds}',
      '',
      'Journal du service :',
      controller.serviceLog.trim().isEmpty ? '—' : controller.serviceLog.trim(),
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostic copié dans le presse-papiers')),
    );
  }
}
