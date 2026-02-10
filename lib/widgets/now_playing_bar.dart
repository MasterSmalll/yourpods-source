import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/download_provider.dart';
import '../screens/player_screen.dart';
import '../screens/playlist_screen.dart';
import '../services/log_service.dart';

class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  void _showSleepTimerDialog(BuildContext context, PlayerProvider player) {
      showDialog(
          context: context,
          builder: (context) {
              return AlertDialog(
                  title: const Text('Sleep Timer', style: TextStyle(color: Colors.white)),
                  backgroundColor: const Color(0xFF1F1E27),
                  content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                          if (player.isSleepTimerActive)
                              ListTile(
                                  leading: const Icon(Icons.timer_off, color: Colors.deepPurpleAccent),
                                  title: const Text('Cancel Timer', style: TextStyle(color: Colors.deepPurpleAccent)),
                                  onTap: () {
                                      player.cancelSleepTimer();
                                      Navigator.pop(context);
                                  },
                              ),
                          ...[15, 30, 45, 60].map((minutes) => ListTile(
                              title: Text('$minutes minutes', style: const TextStyle(color: Colors.white)),
                              onTap: () {
                                  player.setSleepTimer(Duration(minutes: minutes));
                                  Navigator.pop(context);
                              },
                          )),
                          ListTile(
                              title: const Text('End of Episode', style: TextStyle(color: Colors.white)),
                              onTap: () {
                                  // Calculate remaining duration
                                  final remaining = (player.player.duration ?? Duration.zero) - player.player.position;
                                  if (remaining.inSeconds > 0) {
                                      player.setSleepTimer(remaining);
                                  }
                                  Navigator.pop(context);
                              },
                          ),
                      ],
                  ),
                  actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                      ),
                  ],
              );
          }
      );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
        final hours = d.inHours;
        final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        return '$hours:$minutes:$seconds';
    }
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final episode = playerProvider.currentEpisode;
    Log.d('NowPlayingBar', 'rebuild. Episode: ${episode?.title}, Playing: ${playerProvider.isPlaying}');

    if (episode == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const PlayerScreen()),
        );
      },
      child: Container(
        height: 78, 
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E27),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: episode.imageUrl != null
                  ? Image.network(episode.imageUrl!, width: 56, height: 56, fit: BoxFit.cover)
                  : const Icon(Icons.podcasts, size: 56, color: Colors.white24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    episode.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    playerProvider.currentPodcast?.title ?? '',
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Progress Line
                  StreamBuilder<Duration>(
                      stream: playerProvider.player.positionStream,
                      builder: (context, snapshot) {
                          final position = snapshot.data ?? Duration.zero;
                          final duration = playerProvider.player.duration ?? Duration.zero; 
                          
                          if (duration.inSeconds == 0) return const SizedBox.shrink();

                          final posStr = _formatDuration(position);
                          final durStr = _formatDuration(duration);
                          
                          return Consumer<SettingsProvider>(
                              builder: (context, settings, _) {
                                  String label = PlayerProvider.formatProgress(
                                      position: position,
                                      duration: duration,
                                      showPercentListened: settings.showPercentListened,
                                  );

                                  return GestureDetector(
                                      onLongPress: () => settings.setShowPercentListened(!settings.showPercentListened),
                                      child: Text(
                                          '$posStr / $durStr • $label',
                                          style: const TextStyle(fontSize: 11, color: Colors.deepPurpleAccent),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                      ),
                                  );
                              }
                          );
                      }
                  ),
                ],
              ),
            ),
            // Menu Button (Replaces Queue Button)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white70, size: 26),
              color: const Color(0xFF2A2935),
              onSelected: (value) async {
                  final settings = Provider.of<SettingsProvider>(context, listen: false);
                  final downloader = Provider.of<DownloadProvider>(context, listen: false);
                  // playerProvider is already available in build scope
                  
                  switch (value) {
                      case 'show_queue':
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const PlaylistScreen()),
                          );
                          break;
                      case 'speed':
                          await playerProvider.cycleSpeed();
                          break;
                      case 'sleep_timer':
                          _showSleepTimerDialog(context, playerProvider);
                          break;
                      case 'played':
                         if (episode != null) {
                             await playerProvider.markAsListened(
                                 MediaItem(id: episode.guid, title: episode.title, album: episode.title, duration: episode.duration, artUri: Uri.parse(episode.imageUrl ?? ''))
                             ); // Construct minimal media item if needed or use current
                             // Better: Use playerProvider.markAsListened with the actual current media item if possible
                             if (playerProvider.player.audioSource != null && playerProvider.queue.isNotEmpty) {
                                 // Finding the item in queue to remove it? 
                                 // markAsListened takes a MediaItem. 
                                 // We should try to find it in the queue or construct one.
                                 // If it's the current item, we might not have the full MediaItem object handy here easily without looking at queue or audioHandler.mediaItem.
                                 // Let's rely on constructing one or finding it.
                                 final item = playerProvider.queue.firstWhere((i) => i.id == episode.guid, orElse: () => 
                                     MediaItem(id: episode.guid, title: episode.title, album: playerProvider.currentPodcast?.title ?? '', extras: {'url': episode.audioUrl, 'podcastUrl': playerProvider.currentPodcast?.url})
                                 );
                                 await playerProvider.markAsListened(item);
                             }
                          }
                          break;
                      case 'download':
                          if (episode?.audioUrl != null) downloader.downloadEpisode(episode!.audioUrl!);
                          break;
                      case 'delete_download':
                          if (episode?.audioUrl != null) downloader.deletedownload(episode!.audioUrl!);
                          break;
                      case 'remove_queue':
                           // Similar logic to 'played', need MediaItem
                           if (episode != null) {
                               final item = playerProvider.queue.firstWhere((i) => i.id == episode.guid, orElse: () => MediaItem(id: '', title: ''));
                               if (item.id.isNotEmpty) await playerProvider.removeFromQueue(item);
                           }
                          break;
                      case 'toggle_percent':
                          settings.setShowPercentListened(!settings.showPercentListened);
                          break;
                  }
              },
              itemBuilder: (context) {
                  final downloader = Provider.of<DownloadProvider>(context, listen: false);
                  final settings = Provider.of<SettingsProvider>(context, listen: false);
                  final downloadStatus = downloader.getStatus(episode?.audioUrl ?? '');
                  
                  return [
                      // 1. Show Queue
                      const PopupMenuItem(
                          value: 'show_queue',
                          child: Row(children: [Icon(Icons.list, color: Colors.white), SizedBox(width: 8), Text('Show Queue', style: TextStyle(color: Colors.white))]),
                      ),
                      const PopupMenuDivider(),
                      
                      // 2. Playback Settings
                      PopupMenuItem(
                          value: 'speed',
                          child: Row(children: [const Icon(Icons.speed, color: Colors.white), const SizedBox(width: 8), Text('Speed: ${playerProvider.speed}x', style: const TextStyle(color: Colors.white))]),
                      ),
                      PopupMenuItem(
                          value: 'sleep_timer',
                          child: Row(children: [
                              Icon(playerProvider.isSleepTimerActive ? Icons.timer_off : Icons.timer, color: playerProvider.isSleepTimerActive ? Colors.deepPurpleAccent : Colors.white), 
                              const SizedBox(width: 8), 
                              Text(playerProvider.isSleepTimerActive ? 'Cancel Timer' : 'Sleep Timer', style: TextStyle(color: playerProvider.isSleepTimerActive ? Colors.deepPurpleAccent : Colors.white))
                          ]),
                      ),
                      const PopupMenuDivider(),

                      // 3. Episode Actions
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
                              enabled: false,
                              child: Row(children: [
                                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, value: downloader.getProgress(episode?.audioUrl ?? ''))), 
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
                      const PopupMenuDivider(),
                      
                      // 4. View Settings
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
             // Skip Back
            IconButton(
              icon: const Icon(
                Icons.replay_10, // Approximate for 15s
                color: Colors.white,
                size: 28,
              ),
              onPressed: playerProvider.rewind,
            ),
             // Play/Pause
            IconButton(
              icon: Icon(
                playerProvider.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 32,
              ),
              onPressed: playerProvider.togglePlay,
            ),
             // Skip Forward
            IconButton(
              icon: const Icon(
                Icons.forward_30,
                color: Colors.white,
                size: 28,
              ),
              onPressed: playerProvider.fastForward,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
