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
      final stats = await repo.stats(glyph: _glyphFilter, portalLevel: _levelFilter);
      if (!mounted) return;
      setState(() {
        _running = running;
        _stats = stats;
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
                  _filterBar(),
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

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<GlyphFilter>(
        segments: const [
          ButtonSegment(value: GlyphFilter.all, label: Text('Tous')),
          ButtonSegment(value: GlyphFilter.glyph, label: Text('Avec glyph')),
          ButtonSegment(value: GlyphFilter.noGlyph, label: Text('Sans glyph')),
        ],
        selected: {_glyphFilter},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          setState(() => _glyphFilter = selection.first);
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
