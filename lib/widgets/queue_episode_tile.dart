import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/safe_int.dart';

class QueueEpisodeTile extends StatelessWidget {
  final MediaItem item;
  final int index;
  final bool isReorderingAllowed;
  final VoidCallback onTap;
  final VoidCallback? onMoveToTop;
  final VoidCallback? onMoveToBottom;
  final VoidCallback? onRemove;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectChanged;
  final bool isSelectionMode;

  const QueueEpisodeTile({
    super.key,
    required this.item,
    required this.index,
    this.isReorderingAllowed = true,
    required this.onTap,
    this.onMoveToTop,
    this.onMoveToBottom,
    this.onRemove,
    this.isSelected = false,
    this.onSelectChanged,
    this.isSelectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      onTap: isSelectionMode ? () => onSelectChanged?.call(!isSelected) : onTap,
      onLongPress: !isSelectionMode ? () => onSelectChanged?.call(true) : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelectionMode)
            Checkbox(
              value: isSelected,
              activeColor: Colors.deepPurpleAccent,
              checkColor: Colors.white,
              onChanged: onSelectChanged,
            ),
          Stack(
            alignment: Alignment.center,
            children: [
          Container(
             width: 50,
             height: 50,
             decoration: BoxDecoration(
               borderRadius: BorderRadius.circular(4),
               color: Colors.grey[800],
             ),
             child: item.artUri != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        item.artUri.toString(),
                        fit: BoxFit.cover,
                        cacheWidth: 100,
                        cacheHeight: 100,
                        errorBuilder: (c, o, s) => const Icon(Icons.music_note, color: Colors.white24),
                      ),
                    )
                  : const Icon(Icons.music_note, color: Colors.white24),
          ),
          Consumer<PlayerProvider>(
            builder: (context, player, child) {
              if (player.currentEpisode?.guid == item.id && player.isPlaying) {
                 return Container(
                     width: 50, height: 50,
                     color: Colors.black45,
                     child: const Icon(Icons.equalizer, color: Colors.deepPurpleAccent),
                 );
              }
              return const SizedBox.shrink();
            },
          ),
          ],
        ),
        ],
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.album ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Consumer2<SettingsProvider, PlayerProvider>(
              builder: (context, settings, player, _) {
                  final duration = item.duration ?? Duration.zero;
                  final isCurrent = player.currentEpisode?.guid == item.id;

                  if (isCurrent) {
                      return StreamBuilder<Duration>(
                          stream: player.player.positionStream,
                          builder: (context, snapshot) {
                              final position = snapshot.data ?? Duration.zero;
                              final progressText = PlayerProvider.formatProgress(
                                  position: position,
                                  duration: duration,
                                  showPercentListened: settings.showPercentListened,
                                  includeDuration: true,
                              );
                              
                              String subText = progressText;
                              if (item.extras?['pubDate'] != null) {
                                  try {
                                      final date = DateTime.parse(item.extras!['pubDate']);
                                      final dateStr = DateFormat('MMM d').format(date);
                                      subText = "$dateStr • $subText";
                                  } catch (e) {
                                      // ignore parse error
                                  }
                              }
                              
                              return Padding(
                                padding: const EdgeInsets.only(top: 2.0),
                                child: Text(
                                    subText, 
                                    style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 10),
                                ),
                              );
                          }
                      );
                  }

                  final savedPositionSeconds = safeInt(item.extras?['position_seconds']);
                  Duration savedPosition = Duration(seconds: savedPositionSeconds);

                  final progressText = PlayerProvider.formatProgress(
                      position: savedPosition,
                      duration: duration,
                      showPercentListened: settings.showPercentListened,
                      includeDuration: true,
                  );
                  
                  String subText = progressText;
                  if (item.extras?['pubDate'] != null) {
                      try {
                          final date = DateTime.parse(item.extras!['pubDate']);
                          final dateStr = DateFormat('MMM d').format(date);
                          subText = "$dateStr • $subText";
                      } catch (e) {
                          // ignore parse error
                      }
                  }
                  
                  return Padding(
                    padding: const EdgeInsets.only(top: 2.0),
                    child: Text(
                        subText, 
                        style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 10),
                    ),
                  );
              },
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
           PopupMenuButton<String>(
               icon: const Icon(Icons.more_vert, color: Colors.white60),
               color: const Color(0xFF2A2935),
               onSelected: (value) async {
                   final player = Provider.of<PlayerProvider>(context, listen: false);
                   final downloader = Provider.of<DownloadProvider>(context, listen: false);
                   final settings = Provider.of<SettingsProvider>(context, listen: false);
                   
                   switch (value) {
                       case 'play':
                           onTap();
                           break;
                       case 'played':
                           await player.markAsListened(item);
                           if (context.mounted) {
                               ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as played')));
                           }
                           break;
                       case 'download':
                           final url = item.extras?['url'] as String?;
                           if (url != null) downloader.downloadEpisode(url);
                           break;
                       case 'delete_download':
                           final url = item.extras?['url'] as String?;
                           if (url != null) downloader.deletedownload(url);
                           break;
                       case 'remove_queue':
                           await player.removeFromQueue(item);
                           break;
                       case 'toggle_percent':
                           settings.setShowPercentListened(!settings.showPercentListened);
                           break;
                       case 'move_top':
                           onMoveToTop?.call();
                           break;
                       case 'move_bottom':
                           onMoveToBottom?.call();
                           break;
                   }
               },
               itemBuilder: (context) {
                   final downloader = Provider.of<DownloadProvider>(context, listen: false);
                   final settings = Provider.of<SettingsProvider>(context, listen: false);
                   final downloadStatus = downloader.getStatus(item.extras?['url'] as String? ?? '');
                   
                   return [
                       const PopupMenuItem(
                           value: 'play',
                           child: Row(children: [Icon(Icons.play_arrow, color: Colors.white), SizedBox(width: 8), Text('Play', style: TextStyle(color: Colors.white))]),
                       ),
                       const PopupMenuItem(
                           value: 'played',
                           child: Row(children: [Icon(Icons.check, color: Colors.white), SizedBox(width: 8), Text('Mark as Played', style: TextStyle(color: Colors.white))]),
                       ),
                        if (downloadStatus == DownloadState.downloaded)
                            const PopupMenuItem(
                                value: 'delete_download',
                                child: Row(children: [Icon(Icons.delete_outline, color: Colors.redAccent), SizedBox(width: 8), Text('Remove Download', style: TextStyle(color: Colors.white))]),
                            )
                        else if (downloadStatus == DownloadState.downloading)
                             PopupMenuItem(
                                enabled: false, // Cannot interact while downloading, or maybe cancel?
                                child: Row(children: [
                                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, value: downloader.getProgress(item.extras?['url'] as String? ?? ''))), 
                                    const SizedBox(width: 8), 
                                    const Text('Downloading...', style: TextStyle(color: Colors.white))
                                ]),
                            )
                        else
                            const PopupMenuItem(
                                value: 'download',
                                child: Row(children: [Icon(Icons.download, color: Colors.white), SizedBox(width: 8), Text('Download', style: TextStyle(color: Colors.white))]),
                            ),
                       const PopupMenuItem(
                           value: 'remove_queue',
                           child: Row(children: [Icon(Icons.remove_circle_outline, color: Colors.white), SizedBox(width: 8), Text('Remove from Queue', style: TextStyle(color: Colors.white))]),
                       ),
                       if (isReorderingAllowed) ...[
                           const PopupMenuItem(
                               value: 'move_top',
                               child: Row(children: [Icon(Icons.vertical_align_top, color: Colors.white), SizedBox(width: 8), Text('Move to Top', style: TextStyle(color: Colors.white))]),
                           ),
                           const PopupMenuItem(
                               value: 'move_bottom',
                               child: Row(children: [Icon(Icons.vertical_align_bottom, color: Colors.white), SizedBox(width: 8), Text('Move to Bottom', style: TextStyle(color: Colors.white))]),
                           ),
                       ],
                       PopupMenuItem(
                           value: 'toggle_percent',
                           child: Row(children: [
                               Icon(settings.showPercentListened ? Icons.percent : Icons.timer, color: Colors.white), 
                               const SizedBox(width: 8), 
                               Text(settings.showPercentListened ? 'Show Time Left' : 'Show % Listened', style: const TextStyle(color: Colors.white))
                           ]),
                       ),
                   ];
               },
           ),
           if (isReorderingAllowed && index >= 0)
             ReorderableDragStartListener(
               index: index,
               child: const Padding(
                 padding: EdgeInsets.symmetric(horizontal: 4),
                 child: Icon(Icons.drag_handle, color: Colors.white38),
               ),
             ),
        ],
      ),
    );

    if (onRemove != null && !isSelectionMode) {
      return Dismissible(
        key: ValueKey('dismiss_${item.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: Colors.redAccent,
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        onDismissed: (_) => onRemove!(),
        child: tile,
      );
    }

    return tile;
  }


}
