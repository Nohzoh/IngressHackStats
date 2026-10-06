import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/capture_channel.dart';
import '../data/hack_repository.dart';
import '../parsing/item_catalog.dart';
import 'captures_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _capture = const CaptureChannel();
  HackRepository? _repo;
  HackStats? _stats;
  bool _running = false;
  bool _debug = false;
  bool _busy = false;
  GlyphFilter _glyphFilter = GlyphFilter.all;
  int? _levelFilter;
  TransmuterFilter _transmuterFilter = TransmuterFilter.all;
  Map<String, Object?> _diag = const {};
  Map<String, int> _kinds = const {};
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
      _repo = await HackRepository.open();
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
      final stats = await repo.stats(
        glyph: _glyphFilter,
        portalLevel: _levelFilter,
        transmuter: _transmuterFilter,
      );
      if (!mounted) return;
      setState(() {
        _running = running;
        _stats = stats;
        _diag = diag;
        _kinds = kinds;
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
                  _filterBar(),
                  _transmuterFilterBar(),
                  _levelFilterBar(),
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
            subtitle: const Text("Lance la capture, puis passe sur Ingress et hacke normalement."),
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
          Text('Dernier texte lu :', style: small),
          SelectableText(
            lastText.isEmpty ? '—' : lastText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          for (final filter in GlyphFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(filter.label),
                selected: _glyphFilter == filter,
                onSelected: (_) {
                  setState(() => _glyphFilter = filter);
                  _sync();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _transmuterFilterBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SegmentedButton<TransmuterFilter>(
        segments: const [
          ButtonSegment(value: TransmuterFilter.all, label: Text('Ito En : tous')),
          ButtonSegment(value: TransmuterFilter.plus, label: Text('+')),
          ButtonSegment(value: TransmuterFilter.minus, label: Text('−')),
          ButtonSegment(value: TransmuterFilter.none, label: Text('Aucun')),
        ],
        selected: {_transmuterFilter},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          setState(() => _transmuterFilter = selection.first);
          _sync();
        },
      ),
    );
  }

  Widget _levelFilterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text('Portail'),
          ),
          for (final level in <int?>[null, 1, 2, 3, 4, 5, 6, 7, 8])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(level == null ? 'Tous' : 'P$level'),
                selected: _levelFilter == level,
                onSelected: (_) {
                  setState(() => _levelFilter = level);
                  _sync();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final stats = _stats;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _figure('${stats?.hacks ?? 0}', 'hacks', text),
            _figure('${stats?.totalItems ?? 0}', 'items', text),
            _figure((stats?.itemsPerHack ?? 0).toStringAsFixed(1), 'items / hack', text),
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
    if (stats == null || stats.hacks == 0) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aucun hack enregistré pour le moment.', textAlign: TextAlign.center),
        ),
      ];
    }
    return [
      for (final s in stats.items)
        ListTile(
          dense: true,
          title: Text(_label(s)),
          subtitle: Text(
            'dans ${(100 * s.hacksWith / stats.hacks).toStringAsFixed(1)} % des hacks'
            ' · ${(s.total / stats.hacks).toStringAsFixed(2)} / hack'
            '${s.bonusTotal > 0 ? ' · ${s.bonusTotal} en bonus' : ''}',
          ),
          trailing: Text('${s.total}', style: Theme.of(context).textTheme.titleMedium),
        ),
    ];
  }

  static String _label(ItemStat s) {
    final buf = StringBuffer(s.item);
    if (s.level != null) buf.write(' L${s.level}');
    if (s.rarity != null) buf.write(' · ${Rarity.label(s.rarity!)}');
    return buf.toString();
  }
}
