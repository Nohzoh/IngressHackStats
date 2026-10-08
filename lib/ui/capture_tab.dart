import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import 'app_controller.dart';
import 'common.dart';
import 'history_screen.dart';

/// What the player needs in the field: start/stop, proof that rewards are
/// being captured, and alerts when something goes wrong.
class CaptureTab extends StatefulWidget {
  const CaptureTab({super.key, required this.controller});

  final AppController controller;

  @override
  State<CaptureTab> createState() => _CaptureTabState();
}

class _CaptureTabState extends State<CaptureTab> {
  AppController get c => widget.controller;

  List<CaptureRow> _recent = const [];
  ({int regular, int bonus, int? lastTs})? _session;
  bool _onboardingHidden = true;
  bool _busy = false;
  int _loadedVersion = -1;
  int _loadedStart = -1;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.capture.getFlag('onboardingHidden').then((v) {
      if (mounted) setState(() => _onboardingHidden = v);
    });
    _onChange();
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  /// Reloads the lists when new rewards arrived or a capture started.
  Future<void> _onChange() async {
    final repo = c.repository;
    if (repo == null) return;
    final start = c.captureStartedAt;
    if (c.dataVersion == _loadedVersion && start == _loadedStart) {
      if (mounted) setState(() {}); // refresh "il y a…"
      return;
    }
    _loadedVersion = c.dataVersion;
    _loadedStart = start;
    final recent = await repo.recentRewards(limit: 10);
    final session = start > 0 ? await repo.sessionSummary(start) : null;
    if (!mounted) return;
    setState(() {
      _recent = recent;
      _session = session;
    });
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      final ok = await c.toggleCapture();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Partage d’écran refusé')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ingress Hack Stats'), actions: [settingsAction(context, c)]),
      body: RefreshIndicator(
        onRefresh: c.sync,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            ..._alerts(context),
            if (!_onboardingHidden && !_setupDone) _onboarding(context),
            _statusCard(context),
            if (c.running || _session != null) _sessionCard(context),
            _recentCard(context),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- status

  Widget _statusCard(BuildContext context) {
    final theme = Theme.of(context);
    final start = c.captureStartedAt;
    final since = start > 0 ? DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(start)) : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              c.running ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 40,
              color: c.running ? Colors.redAccent : theme.hintColor,
            ),
            const SizedBox(height: 8),
            Text(c.running ? 'Capture en cours' : 'Capture arrêtée', style: theme.textTheme.titleLarge),
            if (since != null)
              Text('depuis ${formatDuration(since)}', style: theme.textTheme.bodyMedium),
            if (!c.running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Choisis « Écran entier » dans la fenêtre de partage.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _busy ? null : _toggle,
                icon: Icon(c.running ? Icons.stop : Icons.play_arrow),
                label: Text(c.running ? 'Arrêter' : 'Démarrer', style: const TextStyle(fontSize: 18)),
                style: c.running
                    ? FilledButton.styleFrom(backgroundColor: theme.colorScheme.error, foregroundColor: theme.colorScheme.onError)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- session

  Widget _sessionCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = _session;
    Widget figure(String value, String label) => Expanded(
          child: Column(children: [
            Text(value, style: text.headlineSmall),
            Text(label, style: text.bodySmall, textAlign: TextAlign.center),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          children: [
            Text(c.running ? 'Cette session' : 'Dernière session', style: text.labelLarge),
            const SizedBox(height: 8),
            Row(children: [
              figure('${s?.regular ?? 0}', 'récompenses'),
              figure('${s?.bonus ?? 0}', 'bonus glyph'),
              figure(s?.lastTs == null ? '—' : timeAgo(s!.lastTs!).replaceFirst('il y a ', ''), 'dernière'),
            ]),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- recent

  Widget _recentCard(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: const Text('Dernières récompenses'),
            trailing: TextButton(
              onPressed: c.repository == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => HistoryScreen(controller: c)),
                      ),
              child: const Text('Historique'),
            ),
          ),
          if (_recent.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('Aucune récompense captée pour l’instant.'),
            ),
          for (final r in _recent) RewardTile(reward: r),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- alerts

  List<Widget> _alerts(BuildContext context) {
    final alerts = <(IconData, String, String?, VoidCallback?)>[];
    final last = c.lastLogLine;
    if (!c.running && last.contains('arrêté par le système')) {
      alerts.add((Icons.warning_amber, 'La capture a été coupée par le système (écran verrouillé ?).', 'Relancer', _toggle));
    }
    if (c.running) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - c.diag('startedAt');
      if (c.diag('frames') == 0 && elapsed > 15000) {
        alerts.add((Icons.videocam_off_outlined, 'Aucune image reçue : le partage d’écran ne fonctionne pas.', null, null));
      }
      if (c.diag('ocrRuns') > 60 && c.diag('kept') == 0) {
        alerts.add((
          Icons.text_fields,
          'Aucun popup reconnu pour l’instant. Le jeu doit être en anglais.',
          null,
          null,
        ));
      }
      final speed = c.ocrSpeed;
      if (speed != null && c.diag('ocrRuns') > 20 && speed.avgMs > 700) {
        alerts.add((
          Icons.speed,
          'Analyse lente (${speed.avgMs} ms) : les popups fermés très vite peuvent être manqués.',
          null,
          null,
        ));
      }
    }
    if (c.error != null) alerts.add((Icons.error_outline, '${c.error}', null, null));

    final scheme = Theme.of(context).colorScheme;
    return [
      for (final (icon, message, action, onAction) in alerts)
        Card(
          color: scheme.errorContainer,
          child: ListTile(
            leading: Icon(icon, color: scheme.onErrorContainer),
            title: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            trailing: action == null ? null : TextButton(onPressed: _busy ? null : onAction, child: Text(action)),
          ),
        ),
    ];
  }

  // ----------------------------------------------------------- onboarding

  bool get _permissionsOk => c.permissions['notifications'] == true && c.permissions['location'] == true;
  bool get _firstReward => (c.kinds['reward'] ?? 0) + (c.kinds['bonus'] ?? 0) > 0;
  bool get _setupDone => _permissionsOk && c.tileAdded && _firstReward;

  Widget _onboarding(BuildContext context) {
    Widget step(bool done, String title, String subtitle, {String? action, VoidCallback? onAction}) => ListTile(
          dense: true,
          leading: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? Colors.green : null),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: done || action == null ? null : TextButton(onPressed: onAction, child: Text(action)),
        );
    return Card(
      child: Column(
        children: [
          ListTile(
            title: const Text('Pour bien démarrer'),
            trailing: TextButton(
              onPressed: () {
                c.capture.setFlag('onboardingHidden', true);
                setState(() => _onboardingHidden = true);
              },
              child: const Text('Masquer'),
            ),
          ),
          step(
            _permissionsOk,
            'Autorisations',
            'Notifications (capture en cours) et localisation (position des hacks).',
            action: 'Autoriser',
            onAction: c.requestPermissions,
          ),
          step(
            c.tileAdded,
            'Tuile des réglages rapides',
            c.canAddTile
                ? 'Démarre la capture depuis le jeu, sans revenir ici.'
                : 'Ajoute « Capture hacks » en modifiant les réglages rapides.',
            action: c.canAddTile ? 'Ajouter' : null,
            onAction: () => c.addTile(),
          ),
          step(
            _firstReward,
            'Première récompense',
            'Démarre, choisis « Écran entier », puis hacke un portail en jeu (interface en anglais).',
          ),
        ],
      ),
    );
  }
}
