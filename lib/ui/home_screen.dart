import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/capture_channel.dart';
import '../data/reward_repository.dart';
import '../stats/reward_stats.dart';
import 'captures_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _capture = const CaptureChannel();
  RewardRepository? _repo;
  RewardStats? _stats;
  bool _running = false;
  bool _debug = false;
  bool _busy = false;
  RewardFilter _filter = const RewardFilter();
  Map<String, Object?> _diag = const {};
  Map<String, int> _kinds = const {};
  String _serviceLog = '';
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync();
  }

  Future<void> _init() async {
    try {
      _repo = await RewardRepository.open();
      _debug = await _capture.isDebug();
      await _sync();
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => _sync());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Pulls pending captures from the service and refreshes the stats.
  Future<void> _sync() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final pending = await _capture.drainPending();
      if (pending.isNotEmpty) await repo.ingest(pending);
      final running = await _capture.isRunning();
      final diag = await _capture.diagnostics();
      final kinds = await repo.countByKind();
      final serviceLog = await _capture.serviceLog();
      final stats = await repo.stats(_filter);
      if (!mounted) return;
      setState(() {
        _running = running;
        _stats = stats;
        _diag = diag;
        _kinds = kinds;
        _serviceLog = serviceLog;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _toggleCapture() async {
    setState(() => _busy = true);
    try {
      if (_running) {
        await _capture.stop();
      } else {
        final started = await _capture.start();
        if (!started && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Capture refusée')),
          );
        }
      }
      // The service needs a moment to report its state.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _sync();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDebug(bool value) async {
    await _capture.setDebug(value);
    setState(() => _debug = value);
  }

  @override
  Widget build(BuildContext context) {
    final repo = _repo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ingress Hack Stats'),
        actions: [
          IconButton(
            tooltip: 'Captures',
            icon: const Icon(Icons.list_alt),
            onPressed: repo == null
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => CapturesScreen(repository: repo)),
                    );
                    _sync();
                  },
          ),
        ],
      ),
      body: repo == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _sync,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                    ),
                  _captureCard(context),
                  _diagnosticsCard(context),
                  _typeBar(),
                  if (_filter.usesGlyph) _glyphBar(),
                  _transmuterBar(),
                  _levelBar(),
                  _summaryCard(context),
                  ..._itemTiles(context),
                ],
              ),
            ),
    );
  }

  Widget _captureCard(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              _running ? Icons.radio_button_checked : Icons.radio_button_off,
              color: _running ? Colors.redAccent : null,
            ),
            title: Text(_running ? 'Capture en cours' : 'Capture arrêtée'),
            subtitle: const Text(
              "Choisis « Écran entier » dans la fenêtre de partage, puis passe sur Ingress et hacke normalement.",
            ),
            trailing: FilledButton(
              onPressed: _busy ? null : _toggleCapture,
              child: Text(_running ? 'Arrêter' : 'Démarrer'),
            ),
          ),
          SwitchListTile(
            title: const Text('Mode calibration'),
            subtitle: const Text("Enregistre tout le texte lu à l'écran, même hors hack"),
            value: _debug,
            onChanged: _setDebug,
          ),
        ],
      ),
    );
  }

  /// Where frames stop in the pipeline: capture → OCR → filter → storage.
  Widget _diagnosticsCard(BuildContext context) {
    int n(String key) => (_diag[key] as num?)?.toInt() ?? 0;
    final lastText = (_diag['lastText'] as String?) ?? '';
    final lastError = (_diag['lastError'] as String?) ?? '';
    final kinds = _kinds.entries.map((e) => '${e.key} ${e.value}').join(' · ');
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      child: ExpansionTile(
        title: const Text('Diagnostic'),
        subtitle: Text(
          'images ${n('frames')} · OCR ${n('ocrRuns')} · avec texte ${n('textFrames')}'
          ' · gardées ${n('kept')}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ignorées (app au premier plan) : ${n('skippedAppVisible')}', style: small),
          Text('Erreurs OCR : ${n('ocrErrors')}', style: small),
          if (lastError.isNotEmpty) Text('Dernière erreur : $lastError', style: small),
          Text('En base : ${kinds.isEmpty ? 'rien' : kinds}', style: small),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Journal du service :', style: small)),
              TextButton(
                onPressed: () async {
                  await _capture.clearServiceLog();
                  _sync();
                },
                child: const Text('Effacer'),
              ),
            ],
          ),
          SelectableText(
            _serviceLog.trim().isEmpty
                ? '—'
                : _serviceLog.trim().split('\n').reversed.take(25).join('\n'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text('Dernier texte lu :', style: small),
          SelectableText(
            lastText.isEmpty ? '—' : lastText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _setFilter(RewardFilter filter) {
    setState(() => _filter = filter);
    _sync();
  }

  RewardFilter _copyFilter({
    RewardType? type,
    Object? portalLevel = _keep,
    TransmuterFilter? transmuter,
    GlyphFilter? glyph,
  }) =>
      RewardFilter(
        type: type ?? _filter.type,
        portalLevel: identical(portalLevel, _keep) ? _filter.portalLevel : portalLevel as int?,
        transmuter: transmuter ?? _filter.transmuter,
        glyph: glyph ?? _filter.glyph,
      );

  static const _keep = Object();

  Widget _chips<T>(String? title, List<T> values, T selected, String Function(T) label, void Function(T) onSelected) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (title != null)
            Padding(padding: const EdgeInsets.only(right: 8), child: Text(title)),
          for (final value in values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label(value)),
                selected: value == selected,
                onSelected: (_) => onSelected(value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _typeBar() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _chips<RewardType>(
          null,
          RewardType.values,
          _filter.type,
          (t) => t.label,
          (t) => _setFilter(_copyFilter(type: t)),
        ),
      );

  Widget _glyphBar() => _chips<GlyphFilter>(
        'Glyph',
        GlyphFilter.values,
        _filter.glyph,
        (g) => g.label,
        (g) => _setFilter(_copyFilter(glyph: g)),
      );

  Widget _transmuterBar() => _chips<TransmuterFilter>(
        'Ito En',
        TransmuterFilter.values,
        _filter.transmuter,
        (t) => switch (t) {
          TransmuterFilter.all => 'Tous',
          TransmuterFilter.plus => '+',
          TransmuterFilter.minus => '−',
          TransmuterFilter.none => 'Aucun',
        },
        (t) => _setFilter(_copyFilter(transmuter: t)),
      );

  Widget _levelBar() => _chips<int?>(
        'Portail',
        const [null, 1, 2, 3, 4, 5, 6, 7, 8],
        _filter.portalLevel,
        (l) => l == null ? 'Tous' : 'P$l',
        (l) => _setFilter(_copyFilter(portalLevel: l)),
      );

  Widget _summaryCard(BuildContext context) {
    final stats = _stats;
    final text = Theme.of(context).textTheme;
    final computed = _filter.type == RewardType.glyphHack;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _figure('${stats?.rewards ?? 0}', computed ? 'hacks (min.)' : 'récompenses', text),
                if (!computed) _figure('${stats?.totalItems ?? 0}', 'items', text),
                _figure(
                  (stats?.itemsPerReward ?? 0).toStringAsFixed(1),
                  computed ? 'items / hack' : 'items / récompense',
                  text,
                ),
              ],
            ),
            if (computed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Calculé : une récompense normale + une récompense bonus, tirages supposés indépendants.',
                  style: text.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _figure(String value, String label, TextTheme text) => Column(
        children: [
          Text(value, style: text.headlineMedium),
          Text(label, style: text.bodySmall),
        ],
      );

  List<Widget> _itemTiles(BuildContext context) {
    final stats = _stats;
    if (stats == null || stats.rewards == 0) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aucune récompense pour ces filtres.', textAlign: TextAlign.center),
        ),
      ];
    }
    final computed = _filter.type == RewardType.glyphHack;
    String pct(double v) => '${(100 * v).toStringAsFixed(1)} %';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(
          computed
              ? 'Chance d’obtenir l’item au moins une fois par hack'
              : 'Chance qu’une récompense contienne l’item',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
      for (final s in stats.items)
        ListTile(
          dense: true,
          title: Text(s.label),
          subtitle: Text([
            if (s.share != null) 'part ${pct(s.share!)}',
            '${s.perReward.toStringAsFixed(2)} / ${computed ? 'hack' : 'récompense'}',
          ].join(' · ')),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(pct(s.presence), style: Theme.of(context).textTheme.titleMedium),
              Text('± ${pct(s.presenceMargin)}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
    ];
  }
}
