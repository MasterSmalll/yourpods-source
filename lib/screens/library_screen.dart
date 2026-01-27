import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../models/podcast.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/action_button.dart';
import 'episode_list_screen.dart';
import '../providers/download_provider.dart';
import '../providers/profile_provider.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _selectedFilter = 'All'; // All, Downloaded, Unplayed, In Progress

  @override
  void initState() {
      super.initState();
      // Initial filter update after first frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateFilters(context);
      });
  }

  Future<void> _updateFilters(BuildContext context) async {
      final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
      final list = downloadProvider.downloadedUrls;
      
      final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
      final deviceId = profileProvider.currentProfile?.deviceId ?? 'flutter-client'; // Fallback
      
      await Provider.of<PodcastProvider>(context, listen: false).updateFilterStatuses(list, deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Podcasts', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Column(
            children: [
               // Filter Chips
               SingleChildScrollView(
                   scrollDirection: Axis.horizontal,
                   padding: const EdgeInsets.symmetric(horizontal: 16.0),
                   child: Consumer<PodcastProvider>(
                       builder: (context, provider, _) {
                           return Row(
                               children: [
                                   _buildFilterChip('All'),
                                   const SizedBox(width: 8),
                                   _buildFilterChip('Downloaded'),
                                   const SizedBox(width: 8),
                                   _buildFilterChip('Unplayed'),
                                   const SizedBox(width: 8),
                                   _buildFilterChip('In Progress'),
                                   
                                   if (provider.groups.isNotEmpty) ...[
                                       const SizedBox(width: 8),
                                       const VerticalDivider(color: Colors.white24, width: 1, thickness: 1, indent: 8, endIndent: 8),
                                       const SizedBox(width: 8),
                                       ...provider.groups.keys.map((group) {
                                            return Padding(
                                                padding: const EdgeInsets.only(right: 8.0),
                                                child: _buildFilterChip(group, isGroup: true),
                                            );
                                       }),
                                   ],
                                   
                                   const SizedBox(width: 8),
                                   IconButton(
                                       icon: const Icon(Icons.edit, color: Colors.white54),
                                       tooltip: 'Manage Groups',
                                       onPressed: () => _showManageGroupsDialog(context),
                                   ),
                               ],
                           );
                       },
                   ),
               ),
               
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ActionButton(
                      icon: Icons.playlist_add,
                      label: 'Queue New',
                      onPressed: () async {
                          final scaffold = ScaffoldMessenger.of(context);
                          final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
                          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);

                          if (!context.mounted) return;

                          // 1. Show Option Dialog
                          final choice = await showDialog<String>(
                              context: context,
                              builder: (ctx) => SimpleDialog(
                                  backgroundColor: const Color(0xFF1F1E27),
                                  title: const Text('Queue New Episodes', style: TextStyle(color: Colors.white)),
                                  children: [
                                      SimpleDialogOption(
                                          onPressed: () => Navigator.pop(ctx, 'all'),
                                          child: const Padding(
                                              padding: EdgeInsets.symmetric(vertical: 8.0),
                                              child: Text('Add All New Episodes', style: TextStyle(color: Colors.white)),
                                          ),
                                      ),
                                      SimpleDialogOption(
                                          onPressed: () => Navigator.pop(ctx, 'choose'),
                                          child: const Padding(
                                              padding: EdgeInsets.symmetric(vertical: 8.0),
                                              child: Text('Choose Podcasts...', style: TextStyle(color: Colors.white)),
                                          ),
                                      ),
                                  ],
                              ),
                          );

                          if (choice == null) return;

                          try {
                              List<Map<String, dynamic>> episodesToAdd = [];

                              if (choice == 'all') {
                                  episodesToAdd = await podcastProvider.getAllNewEpisodes();
                              } else if (choice == 'choose') {
                                  // Show multi-select dialog
                                  if (!context.mounted) return;
                                  final selectedUrls = await showDialog<Set<String>>(
                                      context: context,
                                      builder: (ctx) => _PodcastSelectionDialog(subscriptions: podcastProvider.subscriptions),
                                  );

                                  if (selectedUrls == null || selectedUrls.isEmpty) return;
                                  
                                  // Fetch new from selected
                                  for (var url in selectedUrls) {
                                      final eps = await podcastProvider.getNewEpisodesForPodcast(url);
                                      episodesToAdd.addAll(eps);
                                  }
                              }

                              if (episodesToAdd.isEmpty) {
                                  scaffold.showSnackBar(const SnackBar(content: Text('No new episodes found for selection.')));
                                  return;
                              }
                              
                              // Confirm count
                              if (!context.mounted) return;
                              final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                      backgroundColor: const Color(0xFF1F1E27),
                                      title: const Text('Confirm Queue', style: TextStyle(color: Colors.white)),
                                      content: Text(
                                          'Add ${episodesToAdd.length} episodes to queue?',
                                          style: const TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                          TextButton(
                                              onPressed: () => Navigator.pop(ctx, false),
                                              child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                                          ),
                                          TextButton(
                                              onPressed: () => Navigator.pop(ctx, true),
                                              child: const Text('Add', style: TextStyle(color: Colors.deepPurpleAccent)),
                                          ),
                                      ],
                                  ),
                              );

                              if (confirmed == true) {
                                  scaffold.showSnackBar(const SnackBar(content: Text('Adding to queue...'), duration: Duration(seconds: 1)));
                                  await playerProvider.addEpisodesToQueue(episodesToAdd);
                                  if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${episodesToAdd.length} episodes to queue.')));
                                  }
                              }

                          } catch (e) {
                              scaffold.showSnackBar(SnackBar(content: Text('Error: $e')));
                          }
                      },
                    ),
                    const SizedBox(width: 8),
                    ActionButton(
                      icon: Icons.add,
                      label: 'Add Link',
                      onPressed: () => _showAddPodcastDialog(context),
                    ),
                    const SizedBox(width: 8),
                    ActionButton(
                      icon: Icons.home,
                      label: 'Home',
                      onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false),
                    ),
                    const SizedBox(width: 8),
                    ActionButton(
                      icon: Icons.history,
                      label: 'History',
                      onPressed: () => Navigator.pushNamed(context, '/inprogress'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Consumer<PodcastProvider>(
                  builder: (context, provider, child) {
                    if (provider.isLoading) {
                      return const Center(child: CircularProgressIndicator(color: Colors.deepPurple));
                    }

                    if (provider.error != null) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Error: ${provider.error}', textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () => provider.refreshSubscriptions('flutter-client'),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }

                    if (provider.subscriptions.isEmpty) {
                      return const Center(child: Text('No subscriptions found.'));
                    }
                    
                    // Filter Logic
                    final filteredList = provider.subscriptions.where((p) {
                        if (_selectedFilter == 'All') return true;
                        if (_selectedFilter == 'Downloaded') return provider.hasDownloads(p.url);
                        if (_selectedFilter == 'Unplayed') return provider.hasUnplayed(p.url);
                        if (_selectedFilter == 'In Progress') return provider.hasInProgress(p.url);
                        
                        // Check Groups
                        if (provider.groups.containsKey(_selectedFilter)) {
                            return provider.isPodcastInGroup(_selectedFilter, p.url);
                        }
                        
                        return true;
                    }).toList();
                    
                    if (filteredList.isEmpty && _selectedFilter != 'All') {
                         return Center(
                             child: Column(
                               mainAxisAlignment: MainAxisAlignment.center,
                               children: [
                                 Icon(Icons.filter_list_off, size: 48, color: Colors.white24),
                                 SizedBox(height: 16),
                                 Text('No podcasts match "$_selectedFilter"', style: TextStyle(color: Colors.white54)),
                               ],
                             )
                         );
                    }

                    return RefreshIndicator(
                      onRefresh: () async {
                          final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
                          final deviceId = profileProvider.currentProfile?.deviceId ?? 'flutter-client';
  
                          // 1. Refresh Subscriptions (GPodder)
                          await provider.refreshSubscriptions(deviceId);
                          
                          // 2. Refresh All Feeds & Check auto-queue (Consolidated)
                          if (!context.mounted) return;
                          final newEpisodes = await provider.refreshAllFeeds(deviceId);
                          
                          // 3. Update Filters to reflect new content
                          if (context.mounted) {
                              await _updateFilters(context);
                          }
                          
                          // 4. Queue if found
                          
                          // 4. Queue if found
                          if (newEpisodes.isNotEmpty && context.mounted) {
                              final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                              await playerProvider.addEpisodesToQueue(newEpisodes);
                              
                              if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text('Auto-queued ${newEpisodes.length} new episodes'),
                                          behavior: SnackBarBehavior.floating,
                                      )
                                  );
                              }
                          }
                      },
                      child: GridView.builder(
                        padding: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 120),
                        physics: const AlwaysScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                          childAspectRatio: 0.75,
                        ),
                        itemCount: filteredList.length,
                        itemBuilder: (context, index) {
                          final podcast = filteredList[index];
                          return _buildPodcastCard(context, podcast);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: NowPlayingBar(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildFilterChip(String label, {bool isGroup = false}) {
      final isSelected = _selectedFilter == label;
      return FilterChip(
          label: Text(label),
          selected: isSelected,
          onSelected: (bool selected) {
              setState(() {
                  _selectedFilter = label; // Force selection, act as tabs
              });
          },
          backgroundColor: isGroup ? const Color(0xFF3F3D4E) : const Color(0xFF2A2935),
          selectedColor: Colors.deepPurpleAccent,
          labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.white70),
          checkmarkColor: Colors.white,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      );
  }

  void _showManageGroupsDialog(BuildContext context) {
      showDialog(
          context: context,
          builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1F1E27),
              title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                      const Text('Manage Groups', style: TextStyle(color: Colors.white)),
                      IconButton(
                          icon: const Icon(Icons.add, color: Colors.deepPurpleAccent),
                          onPressed: () {
                              Navigator.pop(context);
                              _showCreateGroupDialog(context);
                          },
                      ),
                  ],
              ),
              content: SizedBox(
                  width: double.maxFinite,
                  child: Consumer<PodcastProvider>(
                      builder: (context, provider, _) {
                          if (provider.groups.isEmpty) {
                              return const Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Text('No groups yet.', style: TextStyle(color: Colors.white54), textAlign: TextAlign.center),
                              );
                          }
                          return ListView.builder(
                              shrinkWrap: true,
                              itemCount: provider.groups.length,
                              itemBuilder: (context, index) {
                                  final name = provider.groups.keys.elementAt(index);
                                  final count = provider.groups[name]!.length;
                                  return ListTile(
                                      title: Text(name, style: const TextStyle(color: Colors.white)),
                                      subtitle: Text('$count podcasts', style: const TextStyle(color: Colors.white54)),
                                      trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                              IconButton(
                                                  icon: const Icon(Icons.edit, color: Colors.white70),
                                                  onPressed: () {
                                                      Navigator.pop(context);
                                                      _editGroup(context, name);
                                                  },
                                              ),
                                              IconButton(
                                                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                                                  onPressed: () {
                                                      provider.deleteGroup(name);
                                                      if (_selectedFilter == name) {
                                                          setState(() {
                                                              _selectedFilter = 'All';
                                                          });
                                                      }
                                                  },
                                              ),
                                          ],
                                      ),
                                  );
                              },
                          );
                      },
                  ),
              ),
              actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close', style: TextStyle(color: Colors.white60)),
                  ),
              ],
          ),
      );
  }

  void _showCreateGroupDialog(BuildContext context) {
      final controller = TextEditingController();
      showDialog(
          context: context,
          builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1F1E27),
              title: const Text('New Group', style: TextStyle(color: Colors.white)),
              content: TextField(
                  controller: controller,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      hintText: 'Group Name',
                      hintStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurple)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurpleAccent)),
                  ),
              ),
              actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                  ),
                  TextButton(
                      onPressed: () {
                          final name = controller.text.trim();
                          if (name.isNotEmpty) {
                              Provider.of<PodcastProvider>(context, listen: false).createGroup(name);
                              Navigator.pop(context);
                              _showManageGroupsDialog(context); // Reopen manage dialog
                          }
                      },
                      child: const Text('Create', style: TextStyle(color: Colors.deepPurpleAccent)),
                  ),
              ],
          ),
      );
  }

  Future<void> _editGroup(BuildContext context, String groupName) async {
      final provider = Provider.of<PodcastProvider>(context, listen: false);
      final currentMembers = provider.groups[groupName] ?? [];
      
      // We need to pass the *set* of currently selected URLs to the dialog logic?
      // But _PodcastSelectionDialog returns a set of selected URLs.
      // Wait, _PodcastSelectionDialog (existing one) manages its own state starting empty?
      // Let's check _PodcastSelectionDialog.
      // It has `_selectedUrls` initialized to empty.
      // We should probably allow passing `initialSelection`.
      
      // For now, I'll modify _PodcastSelectionDialog to accept initialSelection first.
      // Then call it here.
      
      // Hack: For now, I'll implement _PodcastGroupEditorDialog to avoid breaking the queuing dialog logic
      // OR I can quickly update _PodcastSelectionDialog to accept `initialSelection`.
      
      final selected = await showDialog<Set<String>>(
          context: context,
          builder: (ctx) => _PodcastSelectionDialog(
              subscriptions: provider.subscriptions,
              initialSelection: currentMembers.toSet(),
          ),
      );

      if (selected != null) {
          // Update group members
          // The provider doesn't have a "setGroupMembers" method yet, only toggle.
          // I will iterate.
          
          // Actually, I should probably add `setGroupPodcasts(groupName, List<String> urls)` to provider for efficiency.
          // But I can allow the user to modify it here:
          
          // Optimization: A "set group contents" method is better.
          // provider.updateGroup(groupName, selected.toList());
          
          // Wait, I didn't verify if I can add that method.
          // I should add `updateGroupMembers` to PodcastProvider.
          
          await provider.updateGroupMembers(groupName, selected.toList());
      }
      
      if (context.mounted) {
          _showManageGroupsDialog(context);
      }
  }

  Widget _buildPodcastCard(BuildContext context, Podcast podcast) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EpisodeListScreen(podcast: podcast),
          ),
        ).then((_) {
            // Refresh state when coming back, in case we interacted with episodes
            // Just trigger a rebuild by notifying listener? Or local setState?
            // Actually LibraryScreen is listening to PodcastProvider, so if provider notifies, we rebuild.
            // markEpisodeAsInteracted notifies listeners, so it should update automatically!
        });
      },
      child: FutureBuilder<bool>(
        future: Provider.of<PodcastProvider>(context, listen: false).hasAnyNewEpisodes(podcast.url),
        initialData: false, // Default no dot until loaded
        builder: (context, snapshot) {
            final hasNew = snapshot.data ?? false;
            
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E27),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          podcast.logoUrl != null
                              ? Image.network(
                                  podcast.logoUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(Icons.podcasts, size: 64, color: Colors.white24),
                                )
                              : const Icon(Icons.podcasts, size: 64, color: Colors.white24),
                          
                          // Remove Button
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => _confirmRemove(context, podcast),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close, color: Colors.white, size: 20),
                                ),
                              ),
                            ),
                          ),

                          // NEW Badge
                          if (hasNew)
                            Positioned(
                                top: 8,
                                left: 8,
                                child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: Colors.blueAccent,
                                        borderRadius: BorderRadius.circular(4),
                                        boxShadow: const [
                                            BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))
                                        ]
                                    ),
                                    child: const Text(
                                        'NEW',
                                        style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        podcast.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Colors.white,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
        },
      ),
    );
  }

  void _showAddPodcastDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1E27),
        title: const Text('Add Podcast', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter RSS Feed URL',
            hintStyle: TextStyle(color: Colors.white54),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurple)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurpleAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(context);
                try {
                  await Provider.of<PodcastProvider>(context, listen: false)
                      .subscribe(url, 'flutter-client'); // In real app, get deviceId from storage/provider
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Podcast added successfully')),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to add podcast: $e')),
                  );
                }
              }
            },
            child: const Text('Add', style: TextStyle(color: Colors.deepPurpleAccent)),
          ),
        ],
      ),
    );
  }
  void _confirmRemove(BuildContext context, Podcast podcast) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1E27),
        title: const Text('Remove Podcast', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to remove "${podcast.title}"? This will also remove it from the server.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Provider.of<PodcastProvider>(context, listen: false)
                  .removePodcast(podcast.url, 'flutter-client'); // In real app, get proper deviceId
            },
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

class _PodcastSelectionDialog extends StatefulWidget {
  final List<Podcast> subscriptions;
  final Set<String>? initialSelection;
  
  const _PodcastSelectionDialog({
      required this.subscriptions,
      this.initialSelection,
  });

  @override
  State<_PodcastSelectionDialog> createState() => _PodcastSelectionDialogState();
}

class _PodcastSelectionDialogState extends State<_PodcastSelectionDialog> {
  final Set<String> _selectedUrls = {};
  
  @override
  void initState() {
      super.initState();
      if (widget.initialSelection != null) {
          _selectedUrls.addAll(widget.initialSelection!);
      }
  }

  @override
  Widget build(BuildContext context) {
      return AlertDialog(
          backgroundColor: const Color(0xFF1F1E27),
          title: const Text('Choose Podcasts', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0, left: 12, right: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                       const Text("Select Podcast", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 12)),
                       const Text("Auto Queue", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
                Flexible(
                    child: Container(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: widget.subscriptions.length,
                            itemBuilder: (context, index) {
                                final podcast = widget.subscriptions[index];
                                final isSelected = _selectedUrls.contains(podcast.url);
                                final isAutoQueue = Provider.of<PodcastProvider>(context).isAutoQueueEnabled(podcast.url);

                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Checkbox(
                                      value: isSelected,
                                      activeColor: Colors.deepPurpleAccent,
                                      checkColor: Colors.white,
                                      side: const BorderSide(color: Colors.white54),
                                      onChanged: (val) {
                                          setState(() {
                                              if (val == true) {
                                                  _selectedUrls.add(podcast.url);
                                              } else {
                                                  _selectedUrls.remove(podcast.url);
                                              }
                                          });
                                      },
                                  ),
                                  title: Text(podcast.title, style: const TextStyle(color: Colors.white)),
                                  trailing: IconButton(
                                      icon: Icon(
                                          isAutoQueue ? Icons.autorenew : Icons.autorenew_outlined,
                                          color: isAutoQueue ? Colors.blueAccent : Colors.white24,
                                      ),
                                      tooltip: isAutoQueue ? 'Auto-Queue Enabled' : 'Enable Auto-Queue',
                                      onPressed: () {
                                          Provider.of<PodcastProvider>(context, listen: false).toggleAutoQueue(podcast.url);
                                      },
                                  ),
                                  onTap: () {
                                       setState(() {
                                          if (isSelected) {
                                              _selectedUrls.remove(podcast.url);
                                          } else {
                                              _selectedUrls.add(podcast.url);
                                          }
                                      });
                                  },
                                );
                            },
                        ),
                    ),
                ),
            ],
            ),
          ),
          actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(context, _selectedUrls),
                  child: const Text('Add Selected', style: TextStyle(color: Colors.deepPurpleAccent)),
              ),
          ],
      );
  }
}
