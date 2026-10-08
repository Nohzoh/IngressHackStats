import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import 'app_controller.dart';
import 'common.dart';

/// Every captured reward, newest first; a misread one can be deleted.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<CaptureRow>? _rewards;

  RewardRepository get _repo => widget.controller.repository!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rewards = await _repo.recentRewards(limit: 500);
    if (mounted) setState(() => _rewards = rewards);
  }

  Future<void> _delete(CaptureRow reward) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette récompense ?'),
        content: Text(
          '${reward.bonus ? 'Bonus de glyph' : reward.portalName ?? 'Portail non lu'}\n'
          '${reward.items.join(', ')}\n\n'
          'Elle ne comptera plus dans les stats, même après une ré-analyse.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteReward(reward.id);
    widget.controller.dataChanged();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rewards = _rewards;
    return Scaffold(
      appBar: AppBar(title: const Text('Historique')),
      body: rewards == null
          ? const Center(child: CircularProgressIndicator())
          : rewards.isEmpty
              ? const Center(child: Text('Aucune récompense.'))
              : ListView.separated(
                  itemCount: rewards.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => RewardTile(
                    reward: rewards[i],
                    relativeTime: false,
                    onDelete: () => _delete(rewards[i]),
                  ),
                ),
    );
  }
}
