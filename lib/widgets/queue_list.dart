import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Tutorial
import 'package:audio_service/audio_service.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
// import '../providers/podcast_provider.dart'; // import for future improved filtering
import 'queue_episode_tile.dart';

class QueueList extends StatefulWidget {
  final String currentFilter;
  final ScrollController? scrollController;

  const QueueList({
    super.key, 
    required this.currentFilter,
    this.scrollController,
  });

  @override
  State<QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<QueueList> {
  // Filter state moved to parent

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkTutorial());
  }

  Future<void> _checkTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_reorder_tutorial') ?? false;
    if (!hasSeen && mounted) {
        showDialog(
            context: context,
            builder: (context) => AlertDialog(
                title: const Text('Reordering Episodes', style: TextStyle(color: Colors.white)),
                content: const Text('You can long-press on any episode in the "All" list to drag and reorder it.', style: TextStyle(color: Colors.white70)),
                backgroundColor: const Color(0xFF2A2935),
                actions: [
                    TextButton(
                        onPressed: () {
                            prefs.setBool('has_seen_reorder_tutorial', true);
                            Navigator.pop(context);
                        },
                        child: const Text('Got it'),
                    ),
                ],
            ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Filter Dropdown moved to parent
        
        Expanded(
          child: Consumer<PlayerProvider>(
            builder: (context, player, child) {
              return StreamBuilder<List<MediaItem>>(
                stream: player.queueStream,
                builder: (context, snapshot) {
                  final queue = snapshot.data ?? [];
                  
                  if (queue.isEmpty) {
                    return const Center(
                      child: Text(
                        'Queue is empty',
                        style: TextStyle(fontSize: 18, color: Colors.grey),
                      ),
                    );
                  }

                  // Apply Filters
                  final filteredQueue = queue.where((item) {
                     if (widget.currentFilter == 'All') return true;
                     
                     if (widget.currentFilter == 'Downloaded') {
                         final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
                         final url = item.extras?['url'] as String?;
                         return url != null && downloadProvider.getStatus(url) == DownloadState.downloaded;
                     }
                     
                     if (widget.currentFilter == 'Unplayed') {
                         // Assume queue items are unplayed unless actively playing?
                         // Or filter out "In Progress" items?
                         // For now, let's treat "Unplayed" as "Not In Progress"
                         // Check if it matches current episode?
                         if (player.currentEpisode?.guid == item.id) return false;
                         return true;
                     }
                     
                     if (widget.currentFilter == 'In Progress') {
                         // Check if it is current episode
                         if (player.currentEpisode?.guid == item.id) return true;
                         return false;
                     }
                     
                     return true;
                  }).toList();

                  if (filteredQueue.isEmpty) {
                       return Center(
                           child: Column(
                               mainAxisAlignment: MainAxisAlignment.center,
                               children: [
                                   const Icon(Icons.filter_list_off, size: 48, color: Colors.white24),
                                   const SizedBox(height: 16),
                                   Text('No episodes match "${widget.currentFilter}"', style: const TextStyle(color: Colors.white54)),
                               ],
                           ),
                       );
                  }

                  // If showing 'All', allow reordering
                  if (widget.currentFilter == 'All') {
                      return ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 120),
                        itemCount: filteredQueue.length,
                        onReorder: (oldIndex, newIndex) {
                           player.reorderQueue(oldIndex, newIndex);
                        },
                        itemBuilder: (context, index) {
                          final item = filteredQueue[index];
                          return QueueEpisodeTile(
                              key: ValueKey(item.id),
                              item: item,
                              index: index,
                              isReorderingAllowed: true,
                              onTap: () => player.playMediaItem(item), 
                              onMoveToTop: () => player.reorderQueue(index, 0),
                              onMoveToBottom: () => player.reorderQueue(index, queue.length),
                          );
                        },
                      );
                  } else {
                      // Filtered view (No reorder)
                      // Important: We need to find original index for skipToQueueItem
                      return ListView.builder(
                          padding: const EdgeInsets.only(bottom: 120),
                          itemCount: filteredQueue.length,
                          itemBuilder: (context, index) {
                              final item = filteredQueue[index];
                              
                              return QueueEpisodeTile(
                                  key: ValueKey(item.id),
                                  item: item,
                                  index: index, // Visual index
                                  isReorderingAllowed: false,
                                  onTap: () {
                                      player.playMediaItem(item);
                                  },
                              );
                          },
                      );
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }


}

