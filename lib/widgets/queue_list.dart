import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Tutorial
import 'package:audio_service/audio_service.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
// import '../providers/podcast_provider.dart'; // import for future improved filtering
import 'queue_episode_tile.dart';
import 'conflict_resolution_dialog.dart';
import '../models/sync_conflict.dart';

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

                  // 1. Identify Now Playing
                  MediaItem? nowPlayingItem;
                  final currentId = player.currentEpisode?.guid; // Or player.mediaItem.value?.id
                  
                  // 2. Separate Queue
                  final List<MediaItem> upNextItems = [];
                  
                  for (var item in queue) {
                      if (item.id == currentId) {
                          nowPlayingItem = item;
                      } else {
                          upNextItems.add(item);
                      }
                  }
                  
                  // If we didn't find current in queue (e.g. queue cleared but playing), 
                  // maybe we should just show the queue as is?
                  // But usually current IS in queue. 
                  // If currentId is null (nothing playing), everything is Up Next.

                  // 3. Apply Filters to *Up Next* (Now Playing is always shown if it matches, or maybe specifically handled?)
                  // The user likely wants to see Now Playing regardless of filter, OR matching filter.
                  // Let's filter both for consistency with "Downloaded" etc.
                  
                  bool matchesFilter(MediaItem item) {
                     if (widget.currentFilter == 'All') return true;
                     
                     if (widget.currentFilter == 'Downloaded') {
                         final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
                         final url = item.extras?['url'] as String?;
                         return url != null && downloadProvider.getStatus(url) == DownloadState.downloaded;
                     }
                     
                     if (widget.currentFilter == 'Unplayed') {
                         // "Unplayed" generally implies "Not In Progress"
                         // So Now Playing probably shouldn't show in "Unplayed" list?
                         // But if I just started it?
                         // Let's stick to existing logic:
                         if (player.currentEpisode?.guid == item.id) return false; 
                         return true;
                     }
                     
                     if (widget.currentFilter == 'In Progress') {
                         if (player.currentEpisode?.guid == item.id) return true;
                         return false;
                     }
                     
                     return true;
                  }

                  final filteredUpNext = upNextItems.where(matchesFilter).toList();
                  
                  // Check Now Playing against filter too?
                  // "Unplayed" -> Now Playing (active) is technically "In Progress" usually.
                  // "In Progress" -> Now Playing definitely is.
                  // "Downloaded" -> checks download status.
                  
                  bool showNowPlaying = false;
                  if (nowPlayingItem != null) {
                      showNowPlaying = matchesFilter(nowPlayingItem!);
                  }

                  if (!showNowPlaying && filteredUpNext.isEmpty) {
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

                  // 4. Build List
                  // If showing 'All', allow reordering of Up Next
                  if (widget.currentFilter == 'All') {
                      return RefreshIndicator(
                        onRefresh: () async {
                            final conflicts = await player.syncPlaybackState(force: true);
                            if (context.mounted && conflicts.isNotEmpty) {
                                ConflictResolutionDialog.show(context, conflicts);
                            }
                        },
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(), // Ensure scroll for refresh
                          controller: widget.scrollController,
                          slivers: [
                              if (showNowPlaying && nowPlayingItem != null)
                                  SliverToBoxAdapter(
                                      child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                              _buildSectionHeader("Now Playing"),
                                              QueueEpisodeTile(
                                                  key: ValueKey(nowPlayingItem!.id),
                                                  item: nowPlayingItem!,
                                                  index: -1, // Not reorderable
                                                  isReorderingAllowed: false,
                                                  onTap: () => player.playMediaItem(nowPlayingItem!),
                                              ),
                                              if (filteredUpNext.isNotEmpty)
                                                  _buildSectionHeader("Up Next"),
                                          ],
                                      ),
                                  ),
                              
                              if (filteredUpNext.isNotEmpty && !showNowPlaying && nowPlayingItem == null)
                                   // Edge case: Nothing playing, just Up Next (which is everything)
                                   // But typically we'd header it "Up Next" if we have a distinction?
                                   // Or just "Queue"?
                                   // Let's assume if there's no Now Playing, it's just a list.
                                   // But for consistency let's header it if we think it's helpful.
                                   // Actually if nothing is playing, "Now Playing" header limits confusion.
                                   SliverToBoxAdapter(child: _buildSectionHeader("Up Next")),

                              SliverReorderableList(
                                  itemBuilder: (context, index) {
                                      final item = filteredUpNext[index];
                                      return QueueEpisodeTile(
                                          key: ValueKey(item.id),
                                          item: item,
                                          index: index,
                                          isReorderingAllowed: true,
                                          onTap: () => player.playMediaItem(item), 
                                          onMoveToTop: () {
                                              // We need absolute index in original queue
                                              final originalIndex = queue.indexOf(item);
                                              if (originalIndex != -1) player.reorderQueue(originalIndex, 0); // Logic might differ if Now Playing is at 0?
                                              // reorderQueue(old, new). 
                                              // If Now Playing is at 0, moving to 0 replaces it? 
                                              // Usually Now Playing is index 0. 
                                              // If we move to 0, does it become Now Playing?
                                              // Yes.
                                          },
                                          onMoveToBottom: () {
                                               final originalIndex = queue.indexOf(item);
                                               if (originalIndex != -1) player.reorderQueue(originalIndex, queue.length);
                                          },
                                      );
                                  },
                                  itemCount: filteredUpNext.length,
                                  onReorder: (oldIndex, newIndex) {
                                      // Map filteredUpNext indices to global queue indices
                                      final item = filteredUpNext[oldIndex];
                                      final globalOldIndex = queue.indexOf(item);
                                      
                                      // Prepare target
                                      int globalNewIndex;
                                      if (newIndex >= filteredUpNext.length) {
                                          // Moving to end of Up Next
                                          // So after the last item of Up Next
                                          final lastItem = filteredUpNext.last;
                                          globalNewIndex = queue.indexOf(lastItem) + 1; 
                                          // Correction for removal? 
                                          // reorderQueue handles "insert at newIndex". 
                                      } else {
                                          final targetItem = filteredUpNext[newIndex];
                                          globalNewIndex = queue.indexOf(targetItem);
                                      }
                                      
                                      // Adjust if moving downwards (standard ReorderableListView logic)
                                      // But we are manually calculating via global indices.
                                      // player.reorderQueue likely expects global indices.
                                      
                                      if (globalOldIndex != -1) {
                                          player.reorderQueue(globalOldIndex, globalNewIndex);
                                      }
                                  },
                              ),
                              
                              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
                          ],
                        ),
                      );
                  } else {
                      // Filtered View (No reorder)
                      return RefreshIndicator(
                        onRefresh: () async {
                            final conflicts = await player.syncPlaybackState(force: true);
                            if (context.mounted && conflicts.isNotEmpty) {
                                ConflictResolutionDialog.show(context, conflicts);
                            }
                        },
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(), // Ensure scroll for refresh
                          controller: widget.scrollController,
                          slivers: [
                               if (showNowPlaying && nowPlayingItem != null)
                                  SliverToBoxAdapter(
                                      child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                              _buildSectionHeader("Now Playing"),
                                              QueueEpisodeTile(
                                                  key: ValueKey(nowPlayingItem!.id),
                                                  item: nowPlayingItem!,
                                                  index: -1,
                                                  isReorderingAllowed: false,
                                                  onTap: () => player.playMediaItem(nowPlayingItem!),
                                              ),
                                              if (filteredUpNext.isNotEmpty)
                                                  _buildSectionHeader("Up Next"),
                                          ],
                                      ),
                                  ),
                                  
                              SliverList(
                                  delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                          final item = filteredUpNext[index];
                                          return QueueEpisodeTile(
                                              key: ValueKey(item.id),
                                              item: item,
                                              index: index,
                                              isReorderingAllowed: false,
                                              onTap: () => player.playMediaItem(item),
                                          );
                                      },
                                      childCount: filteredUpNext.length,
                                  ),
                              ),
                              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
                          ],
                        ),
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

  Widget _buildSectionHeader(String title) {
      return Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
              ),
          ),
      );


  }
}

