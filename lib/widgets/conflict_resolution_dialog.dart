import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/sync_conflict.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart'; // For formatProgress
import '../providers/settings_provider.dart';

class ConflictResolutionDialog extends StatefulWidget {
  final List<SyncConflict> conflicts;

  const ConflictResolutionDialog({super.key, required this.conflicts});

  /// Convenience method to show the dialog and handle resolution.
  /// Returns true if conflicts were resolved, false/null if cancelled.
  static Future<bool?> show(BuildContext context, List<SyncConflict> conflicts) async {
    if (conflicts.isEmpty) return null;
    
    final decisions = await showDialog<Map<String, bool>?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ConflictResolutionDialog(conflicts: conflicts),
    );
    
    if (decisions != null && context.mounted) {
      final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
      for (var conflict in conflicts) {
        final keepRemote = decisions[conflict.episodeGuid] ?? true;
        await podcastProvider.applyConflictResolution(conflict, keepRemote);
      }
      return true;
    }
    return false;
  }

  @override
  State<ConflictResolutionDialog> createState() => _ConflictResolutionDialogState();
}

class _ConflictResolutionDialogState extends State<ConflictResolutionDialog> {
  // Map of EpisodeGUID -> keepRemote (true = keep remote, false = keep local)
  final Map<String, bool> _decisions = {};
  bool _setAsDefault = false;

  @override
  void initState() {
    super.initState();
    for (var conflict in widget.conflicts) {
      _decisions[conflict.episodeGuid] = true; 
    }
  }

  /// Extract a human-readable name from an episode GUID.
  /// GUIDs are often URLs like "https://example.com/episodes/my-episode.mp3"
  /// This extracts "my episode" from such URLs.
  String _displayName(SyncConflict conflict) {
    if (conflict.episodeTitle != null && conflict.episodeTitle!.isNotEmpty) {
      return conflict.episodeTitle!;
    }
    final guid = conflict.episodeGuid;
    // If it looks like a URL, extract the last path segment
    if (guid.contains('/')) {
      try {
        final uri = Uri.parse(guid);
        var segment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : guid;
        // Decode percent-encoding
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

  void _resolveAll(bool keepRemote) {
      setState(() {
          for (var key in _decisions.keys) {
              _decisions[key] = keepRemote;
          }
      });
      if (_setAsDefault) {
          final strategy = keepRemote ? SyncStrategy.serverWins : SyncStrategy.deviceWins;
          Provider.of<SettingsProvider>(context, listen: false).setSyncConflictStrategy(strategy);
      }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1E27),
      title: const Text('Sync Conflicts', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The following episodes have different playback progress on the server.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.conflicts.length,
                separatorBuilder: (c, i) => const Divider(color: Colors.white24),
                itemBuilder: (context, index) {
                  final conflict = widget.conflicts[index];
                  final keepRemote = _decisions[conflict.episodeGuid] ?? true;
                  
                  // Formatters
                  final localPos = Duration(seconds: conflict.localAction?.position ?? 0);
                  final remotePos = Duration(seconds: conflict.remoteAction?.position ?? 0);
                  final total = Duration(seconds: conflict.localAction?.total ?? conflict.remoteAction?.total ?? 0);

                  final localText = PlayerProvider.formatProgress(position: localPos, duration: total, showPercentListened: false);
                  final remoteText = PlayerProvider.formatProgress(position: remotePos, duration: total, showPercentListened: false);
                  
                  final localDate = DateTime.fromMillisecondsSinceEpoch((conflict.localAction?.timestamp ?? 0) * 1000);
                  final remoteDate = DateTime.fromMillisecondsSinceEpoch((conflict.remoteAction?.timestamp ?? 0) * 1000);
                  final dateFmt = DateFormat('MMM d, HH:mm');

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       Text(
                         _displayName(conflict),
                         style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                         maxLines: 2, overflow: TextOverflow.ellipsis,
                       ),
                       if (conflict.podcastTitle != null)
                           Text(
                               conflict.podcastTitle!,
                               style: const TextStyle(color: Colors.white70, fontSize: 12),
                               maxLines: 1, overflow: TextOverflow.ellipsis,
                           ),
                       const SizedBox(height: 8),
                       Row(
                         children: [
                           // Local Option
                           Expanded(
                             child: InkWell(
                               onTap: () => setState(() => _decisions[conflict.episodeGuid] = false),
                               child: Container(
                                 padding: const EdgeInsets.all(8),
                                 decoration: BoxDecoration(
                                     color: !keepRemote ? Colors.deepPurple.withOpacity(0.3) : Colors.transparent,
                                     border: Border.all(color: !keepRemote ? Colors.deepPurpleAccent : Colors.grey),
                                     borderRadius: BorderRadius.circular(8),
                                 ),
                                 child: Column(
                                     children: [
                                         const Text('This Device', style: TextStyle(color: Colors.white70, fontSize: 11)),
                                         const SizedBox(height: 4),
                                         Text(localText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                         Text(dateFmt.format(localDate), style: const TextStyle(color: Colors.white54, fontSize: 10)),
                                     ],
                                 ),
                               ),
                             ),
                           ),
                           const SizedBox(width: 8),
                           // Remote Option
                           Expanded(
                               child: InkWell(
                                   onTap: () => setState(() => _decisions[conflict.episodeGuid] = true),
                                   child: Container(
                                     padding: const EdgeInsets.all(8),
                                     decoration: BoxDecoration(
                                         color: keepRemote ? Colors.deepPurple.withOpacity(0.3) : Colors.transparent,
                                         border: Border.all(color: keepRemote ? Colors.deepPurpleAccent : Colors.grey),
                                         borderRadius: BorderRadius.circular(8),
                                     ),
                                     child: Column(
                                         children: [
                                             const Text('Server', style: TextStyle(color: Colors.white70, fontSize: 11)),
                                             const SizedBox(height: 4),
                                             Text(remoteText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                             Text(dateFmt.format(remoteDate), style: const TextStyle(color: Colors.white54, fontSize: 10)),
                                         ],
                                     ),
                                   ),
                               ),
                           ),
                         ],
                       ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
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
                    'Set as default for future conflicts',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                    TextButton(onPressed: () => _resolveAll(false), child: const Text('Keep All Local')),
                    TextButton(onPressed: () => _resolveAll(true), child: const Text('Keep All Server')),
                ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null), // Cancel
          child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
        ),
        ElevatedButton(
          onPressed: () {
             // Save default if checkbox is checked
             if (_setAsDefault) {
               final allRemote = _decisions.values.every((v) => v);
               final allLocal = _decisions.values.every((v) => !v);
               if (allRemote || allLocal) {
                 final strategy = allRemote ? SyncStrategy.serverWins : SyncStrategy.deviceWins;
                 Provider.of<SettingsProvider>(context, listen: false).setSyncConflictStrategy(strategy);
               }
             }
             Navigator.pop(context, _decisions);
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
