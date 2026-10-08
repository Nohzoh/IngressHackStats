import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../parsing/hack_parser.dart';
import 'app_controller.dart';
import 'settings_screen.dart';

/// "il y a 12 s", "il y a 5 min", "il y a 2 h", or the date.
String timeAgo(int ts, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(ts));
  if (d.inSeconds < 60) return 'il y a ${d.inSeconds < 0 ? 0 : d.inSeconds} s';
  if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
  if (d.inHours < 24) return 'il y a ${d.inHours} h';
  return formatDateTime(ts);
}

/// "07/10 23:55"
String formatDateTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
}

/// "12 min", "1 h 05"
String formatDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')}';
}

/// App bar button to the settings screen.
Widget settingsAction(BuildContext context, AppController controller) => IconButton(
      tooltip: 'Réglages',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SettingsScreen(controller: controller)),
      ),
    );

/// One reward, as shown in the capture tab and the history.
class RewardTile extends StatelessWidget {
  const RewardTile({super.key, required this.reward, this.onDelete, this.relativeTime = true});

  final CaptureRow reward;
  final VoidCallback? onDelete;
  final bool relativeTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = [
      if (reward.bonus) 'Bonus glyph',
      if (reward.bonus && reward.glyphStatus != null && reward.glyphStatus != GlyphStatus.unknown)
        GlyphStatus.label(reward.glyphStatus!),
      if (reward.transmuter != null) Transmuter.label(reward.transmuter!),
      if (reward.portalLevel != null) 'P${reward.portalLevel} estimé',
    ];
    final title = reward.bonus ? 'Bonus de glyph' : (reward.portalName ?? 'Portail non lu');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: reward.bonus ? theme.colorScheme.tertiaryContainer : theme.colorScheme.secondaryContainer,
        child: Icon(reward.bonus ? Icons.auto_awesome : Icons.hexagon_outlined, size: 20),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (tags.isNotEmpty) tags.join(' · '),
          reward.items.isEmpty ? 'aucun objet lu' : reward.items.join(', '),
        ].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: tags.isNotEmpty,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            relativeTime ? timeAgo(reward.timestamp) : formatDateTime(reward.timestamp),
            style: theme.textTheme.bodySmall,
          ),
          if (onDelete != null)
            InkWell(
              onTap: onDelete,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.delete_outline, size: 20, color: theme.hintColor),
              ),
            ),
        ],
      ),
    );
  }
}
