import 'package:flutter/material.dart';

import '../data/hack_repository.dart';

/// Raw captures with what the parser made of them: the place to check and
/// calibrate the parser against real screens.
class CapturesScreen extends StatefulWidget {
  const CapturesScreen({super.key, required this.repository});

  final HackRepository repository;

  @override
  State<CapturesScreen> createState() => _CapturesScreenState();
}

class _CapturesScreenState extends State<CapturesScreen> {
  late Future<List<CaptureRow>> _captures = widget.repository.recentCaptures();

  void _reload() => setState(() => _captures = widget.repository.recentCaptures());

  Future<void> _reparse() async {
    final hacks = await widget.repository.reparseAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ré-analyse terminée : $hacks hacks')),
    );
    _reload();
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tout effacer ?'),
        content: const Text('Toutes les captures et statistiques seront supprimées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Effacer')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.deleteAll();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Captures'),
        actions: [
          IconButton(tooltip: 'Ré-analyser', icon: const Icon(Icons.refresh), onPressed: _reparse),
          IconButton(tooltip: 'Tout effacer', icon: const Icon(Icons.delete_outline), onPressed: _deleteAll),
        ],
      ),
      body: FutureBuilder<List<CaptureRow>>(
        future: _captures,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          final captures = snapshot.data;
          if (captures == null) return const Center(child: CircularProgressIndicator());
          if (captures.isEmpty) return const Center(child: Text('Aucune capture.'));
          return ListView.builder(
            itemCount: captures.length,
            itemBuilder: (context, i) => _CaptureTile(captures[i]),
          );
        },
      ),
    );
  }
}

class _CaptureTile extends StatelessWidget {
  const _CaptureTile(this.capture);

  final CaptureRow capture;

  @override
  Widget build(BuildContext context) {
    final summary = switch (capture.kind) {
      _ when capture.items.isNotEmpty => capture.items.join(', '),
      CaptureKind.bonus => 'Bonus rattaché au hack #${capture.parentId}',
      _ => capture.rejectReason ?? '—',
    };
    final title = [
      _formatTime(capture.timestamp),
      capture.kind,
      if (capture.portalLevel != null) 'P${capture.portalLevel}',
      if (capture.glyph) 'glyph',
      if (capture.portalName != null) capture.portalName!,
    ].join(' · ');
    return ExpansionTile(
      leading: Icon(_icon(capture.kind)),
      title: Text('#${capture.id} · $title'),
      subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (capture.latitude != null)
          Text('GPS : ${capture.latitude!.toStringAsFixed(5)}, ${capture.longitude!.toStringAsFixed(5)}'),
        const SizedBox(height: 8),
        SelectableText(capture.rawText, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ],
    );
  }

  static IconData _icon(String kind) => switch (kind) {
        CaptureKind.hack => Icons.check_circle_outline,
        CaptureKind.bonus => Icons.add_circle_outline,
        CaptureKind.duplicate => Icons.copy_all,
        CaptureKind.raw => Icons.text_snippet_outlined,
        _ => Icons.block,
      };

  static String _formatTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
