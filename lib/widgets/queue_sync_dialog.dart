import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/queue_sync_change.dart';
import '../providers/settings_provider.dart';
import '../providers/player_provider.dart';

class QueueSyncDialog extends StatefulWidget {
  final List<QueueSyncChange> changes;

  const QueueSyncDialog({super.key, required this.changes});

  /// Show the dialog and return accepted changes, or null if cancelled.
  static Future<List<QueueSyncChange>?> show(BuildContext context, List<QueueSyncChange> changes) async {
    if (changes.isEmpty) return null;

    return showDialog<List<QueueSyncChange>?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => QueueSyncDialog(changes: changes),
    );
  }

  @override
  State<QueueSyncDialog> createState() => _QueueSyncDialogState();
}

class _QueueSyncDialogState extends State<QueueSyncDialog> {
  bool _setAsDefault = false;

  IconData _iconForType(QueueSyncChangeType type) {
    switch (type) {
      case QueueSyncChangeType.add:
        return Icons.add_circle_outline;
      case QueueSyncChangeType.remove:
        return Icons.remove_circle_outline;
      case QueueSyncChangeType.update:
        return Icons.sync;
    }
  }

  Color _colorForType(QueueSyncChangeType type) {
    switch (type) {
      case QueueSyncChangeType.add:
        return Colors.green;
      case QueueSyncChangeType.remove:
        return Colors.redAccent;
      case QueueSyncChangeType.update:
        return Colors.deepPurpleAccent;
    }
  }

  String _positionLabel(int? position, int? total) {
    if (position == null) return '';
    if (total != null && total > 0) {
      final pct = (position / total * 100).clamp(0, 100).toInt();
      return '$pct%';
    }
    final d = Duration(seconds: position);
    return PlayerProvider.formatDurationHuman(d);
  }

  /// Extract a human-readable name from a change.
  /// Falls back to parsing GUID as URL if no title is available.
  String _displayName(QueueSyncChange change) {
    if (change.episodeTitle != null && change.episodeTitle!.isNotEmpty) {
      return change.episodeTitle!;
    }
    final guid = change.episodeGuid;
    // If it looks like a URL, extract the last path segment
    if (guid.contains('/')) {
      try {
        final uri = Uri.parse(guid);
        var segment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : guid;
        segment = Uri.decodeComponent(segment);
        // Strip common audio extensions
        segment = segment.replaceAll(RegExp(r'\.(mp3|m4a|ogg|opus|wav|aac)$', caseSensitive: false), '');
        // Replace dashes/underscores with spaces
        segment = segment.replaceAll(RegExp(r'[-_]'), ' ').trim();
        if (segment.isNotEmpty) return segment;
      } catch (_) {}
    }
    return guid;
  }

  void _acceptAll() {
    setState(() {
      for (var c in widget.changes) {
        c.accepted = true;
      }
    });
  }

  void _rejectAll() {
    setState(() {
      for (var c in widget.changes) {
        c.accepted = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1E27),
      title: const Text('Queue Updates Available', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Episodes from other devices have updated progress. We recommend accepting server updates to stay in sync.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.changes.length,
                separatorBuilder: (c, i) => const Divider(color: Colors.white24),
                itemBuilder: (context, index) {
                  final change = widget.changes[index];
                  return InkWell(
                    onTap: () => setState(() => change.accepted = !change.accepted),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      decoration: BoxDecoration(
                        color: change.accepted 
                            ? _colorForType(change.type).withValues(alpha: 0.1) 
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _iconForType(change.type),
                            color: change.accepted
                                ? _colorForType(change.type)
                                : Colors.white30,
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _displayName(change),
                                  style: TextStyle(
                                    color: change.accepted ? Colors.white : Colors.white54,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (change.podcastTitle != null)
                                  Text(
                                    change.podcastTitle!,
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(
                                      change.summary,
                                      style: TextStyle(
                                        color: _colorForType(change.type),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (change.type == QueueSyncChangeType.update && 
                                        change.localPosition != null) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        '(was ${_positionLabel(change.localPosition, change.totalDuration)})',
                                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Checkbox(
                            value: change.accepted,
                            onChanged: (val) => setState(() => change.accepted = val ?? false),
                            activeColor: Colors.deepPurpleAccent,
                            side: const BorderSide(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // Bulk actions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: _rejectAll,
                  child: const Text('Reject All'),
                ),
                TextButton(
                  onPressed: _acceptAll,
                  child: const Text('Accept All (Recommended)', style: TextStyle(color: Colors.deepPurpleAccent)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Set as default checkbox
            Row(
              children: [
                Checkbox(
                  value: _setAsDefault,
                  onChanged: (val) => setState(() => _setAsDefault = val ?? false),
                  activeColor: Colors.deepPurpleAccent,
                  side: const BorderSide(color: Colors.white54),
                ),
                const Expanded(
                  child: Text(
                    'Always apply this choice automatically',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
        ),
        ElevatedButton(
          onPressed: () {
            if (_setAsDefault) {
              final allAccepted = widget.changes.every((c) => c.accepted);
              final allRejected = widget.changes.every((c) => !c.accepted);
              if (allAccepted || allRejected) {
                final strategy = allAccepted 
                    ? QueueSyncStrategy.serverWins 
                    : QueueSyncStrategy.deviceWins;
                Provider.of<SettingsProvider>(context, listen: false)
                    .setQueueSyncStrategy(strategy);
              }
            }
            Navigator.pop(context, widget.changes);
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
