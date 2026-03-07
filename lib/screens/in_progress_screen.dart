import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Helper text persistence
import '../providers/podcast_provider.dart';
import '../models/podcast.dart';
import '../providers/profile_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/queue_list.dart';
import '../widgets/action_button.dart';
import '../providers/download_provider.dart';

class InProgressScreen extends StatefulWidget {
  const InProgressScreen({super.key});

  @override
  State<InProgressScreen> createState() => _InProgressScreenState();
}

class _InProgressScreenState extends State<InProgressScreen> with SingleTickerProviderStateMixin {
  // -- Device Queue Tab State --
  String _currentFilter = 'All';
  String _currentQueueType = 'Device Queue';

  // -- Server Sync Tab State --
  List<Map<String, dynamic>> _inProgressEpisodes = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  final Set<int> _selectedIndices = {};
  
  bool _showDeviceQueueHelper = true;

  @override
  void initState() {
    super.initState();
    // _tabController no longer needed
    _loadData();
    _checkHelperText();
  }

  Future<void> _checkHelperText() async {
      final prefs = await SharedPreferences.getInstance();
      final hasDismissed = prefs.getBool('dismissed_device_queue_helper') ?? false;
      if (mounted) {
          setState(() {
              _showDeviceQueueHelper = !hasDismissed;
          });
      }
  }

  Future<void> _dismissDeviceQueueHelper() async {
      setState(() {
          _showDeviceQueueHelper = false;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('dismissed_device_queue_helper', true);
  }
  
  @override
  void dispose() {
      // _tabController.dispose();
      super.dispose();
  }

  Future<void> _loadData() async {
    final provider = Provider.of<PodcastProvider>(context, listen: false);
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    
    final deviceId = profileProvider.currentProfile?.deviceId;
    if (deviceId == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
    }

    // Only fetch if we are loading the server tab essentially, but do it initially
    final episodes = await provider.fetchInProgressEpisodes(deviceId);
    
    if (mounted) {
      setState(() {
        _inProgressEpisodes = episodes;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = Provider.of<ProfileProvider>(context).currentProfile?.isLocal ?? false;
    
    // Safety check: if local profile somehow loaded with server tab selected, revert it
    if (isLocal && _currentQueueType == 'Synced with Server') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _currentQueueType = 'Device Queue');
        });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '${_selectedIndices.length} Selected' : 'In Progress'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _isSelectionMode
             ? ActionButton(
                icon: Icons.close,
                label: 'Cancel',
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedIndices.clear();
                  });
                },
              )
            : null,
        // TabBar removed
        actions: [
          if (_isSelectionMode)
             ActionButton(
               icon: Icons.check_circle_outline,
               label: 'Played',
               onPressed: () async {
                 if (_selectedIndices.isEmpty) return;
                 
                 final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
                 final deviceId = profileProvider.currentProfile?.deviceId;
                 
                 if (deviceId == null) return;
                 
                 final selectedItems = _selectedIndices.map((i) => _inProgressEpisodes[i]).toList();
                 
                 await Provider.of<PodcastProvider>(context, listen: false)
                     .markEpisodesAsPlayed(selectedItems, deviceId);
                 
                 if (context.mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(
                     SnackBar(content: Text('${selectedItems.length} episodes marked as played')),
                   );
                   setState(() {
                       _isSelectionMode = false;
                       _selectedIndices.clear();
                   });
                   _loadData();
                 }
               },
             )
          else
            ActionButton(
              icon: Icons.home,
              label: 'Home',
              onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false),
            ),
        ],
      ),
      body: Stack(
          children: [
              Column(
                children: [
                    // Control Header
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Row(
                            children: [
                                // Filter Dropdown
                                const Text('Filter: ', style: TextStyle(color: Colors.white70)),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF2A2935),
                                        borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                            value: _currentFilter,
                                            dropdownColor: const Color(0xFF2A2935),
                                            icon: const Icon(Icons.arrow_drop_down, color: Colors.deepPurpleAccent),
                                            style: const TextStyle(color: Colors.white),
                                            isExpanded: true,
                                            onChanged: (String? newValue) {
                                                if (newValue != null) {
                                                    setState(() {
                                                        _currentFilter = newValue;
                                                    });
                                                }
                                            },
                                            items: <String>['All', 'Downloaded', 'Unplayed', 'In Progress']
                                                .map<DropdownMenuItem<String>>((String value) {
                                                    return DropdownMenuItem<String>(
                                                        value: value,
                                                        child: Text(value),
                                                    );
                                                }).toList(),
                                        ),
                                    ),
                                  ),
                                ),
                                
                                const Spacer(),

                                // Queue Source Dropdown
                                Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF2A2935),
                                        borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                            value: _currentQueueType,
                                            dropdownColor: const Color(0xFF2A2935),
                                            icon: const Icon(Icons.swap_vert, color: Colors.deepPurpleAccent),
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            onChanged: (String? newValue) {
                                                if (newValue != null) {
                                                    setState(() {
                                                        _currentQueueType = newValue;
                                                        if (_currentQueueType == 'Synced with Server') {
                                                            // Refresh server data when switching logic?
                                                            // _loadData(); // Maybe?
                                                        }
                                                    });
                                                }
                                            },
                                            items: (isLocal ? <String>['Device Queue'] : <String>['Device Queue', 'Synced with Server'])
                                                .map<DropdownMenuItem<String>>((String value) {
                                                    return DropdownMenuItem<String>(
                                                        value: value,
                                                        child: Text(value),
                                                    );
                                                }).toList(),
                                        ),
                                    ),
                                ),
                            ],
                        ),
                    ),
                    
                    // Content
                    Expanded(
                        child: Stack(
                            children: [
                                // View 1: Device Queue
                                if (_currentQueueType == 'Device Queue')
                                    Column(
                                        children: [
                                            if (_showDeviceQueueHelper)
                                                Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                                    color: Colors.black12,
                                                    width: double.infinity,
                                                    child: Row(
                                                        children: [
                                                            const Expanded(
                                                                child: Text(
                                                                    'Your local listening queue on this device.',
                                                                    textAlign: TextAlign.center,
                                                                    style: TextStyle(color: Colors.white54, fontSize: 12),
                                                                ),
                                                            ),
                                                            GestureDetector(
                                                                onTap: _dismissDeviceQueueHelper,
                                                                child: const Icon(Icons.close, color: Colors.white54, size: 16),
                                                            ),
                                                        ],
                                                    ),
                                                ),
                                            Expanded(child: QueueList(currentFilter: _currentFilter)),
                                        ],
                                    ),

                                // View 2: Server Sync List
                                if (_currentQueueType == 'Synced with Server')
                                    Column(
                                        children: [
                                            Container(
                                                padding: const EdgeInsets.all(8),
                                                color: Colors.black12,
                                                width: double.infinity,
                                                child: const Text(
                                                    'Episodes in progress synced from your gPodder server.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(color: Colors.white54, fontSize: 12),
                                                ),
                                            ),
                                            Expanded(
                                                child: _isLoading
                                                    ? const Center(child: CircularProgressIndicator(color: Colors.deepPurple))
                                                    : _inProgressEpisodes.isEmpty
                                                        ? const Center(
                                                            child: Text('No in-progress episodes on server.',
                                                                style: TextStyle(color: Colors.white70)))
                                                        : RefreshIndicator(
                                                            onRefresh: () async {
                                                                await _loadData();
                                                                // Auto-queue: drain any pending episodes from buffer
                                                                // (buffer is populated by Library refresh, background refresh, or app resume)
                                                                if (!context.mounted) return;
                                                                final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                                                                final autoQueued = await playerProvider.drainPendingAutoQueue();
                                                                if (autoQueued > 0 && context.mounted) {
                                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                                        SnackBar(
                                                                            content: Text('Auto-queued $autoQueued new episodes'),
                                                                            behavior: SnackBarBehavior.floating,
                                                                        ),
                                                                    );
                                                                }
                                                            },
                                                            child: ListView.builder(
                                                                padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 120),
                                                                itemCount: _inProgressEpisodes.length,
                                                                itemBuilder: (context, index) {
                                                                    final item = _inProgressEpisodes[index];
                                                                    final podcast = item['podcast'] as Podcast;
                                                                    final action = item['action']; // EpisodeAction
                                                                    final episode = item['episode'] as Episode;

                                                                    return Card(
                                                                    color: _selectedIndices.contains(index)
                                                                        ? Colors.deepPurple.withValues(alpha: 0.2)
                                                                        : const Color(0xFF1F1E27),
                                                                    margin: const EdgeInsets.only(bottom: 12),
                                                                    shape: RoundedRectangleBorder(
                                                                        borderRadius: BorderRadius.circular(12),
                                                                        side: _selectedIndices.contains(index)
                                                                            ? const BorderSide(color: Colors.deepPurpleAccent)
                                                                            : BorderSide.none),
                                                                    child: ListTile(
                                                                        onLongPress: () {
                                                                        setState(() {
                                                                            _isSelectionMode = true;
                                                                            _selectedIndices.add(index);
                                                                        });
                                                                        },
                                                                        onTap: () {
                                                                        if (_isSelectionMode) {
                                                                            setState(() {
                                                                            if (_selectedIndices.contains(index)) {
                                                                                _selectedIndices.remove(index);
                                                                                if (_selectedIndices.isEmpty) {
                                                                                _isSelectionMode = false;
                                                                                }
                                                                            } else {
                                                                                _selectedIndices.add(index);
                                                                            }
                                                                            });
                                                                        } else {
                                                                            final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
                                                                            Provider.of<PlayerProvider>(context, listen: false)
                                                                                .play(podcast, episode, downloadProvider: downloadProvider, initialPositionSeconds: action.position);
                                                                            // Stay on screen or go home? User might want to manage queue.
                                                                            // Let's stay here but maybe show mini player update.
                                                                        }
                                                                        },
                                                                        leading: Stack(
                                                                            alignment: Alignment.center,
                                                                            children: [
                                                                              Container(
                                                                                 width: 50,
                                                                                 height: 50,
                                                                                 decoration: BoxDecoration(
                                                                                   borderRadius: BorderRadius.circular(4),
                                                                                   color: Colors.grey[800],
                                                                                 ),
                                                                                 child: podcast.logoUrl != null
                                                                                      ? ClipRRect(
                                                                                          borderRadius: BorderRadius.circular(4),
                                                                                          child: Image.network(
                                                                                            podcast.logoUrl!,
                                                                                            fit: BoxFit.cover,
                                                                                            width: 50,
                                                                                            height: 50,
                                                                                            errorBuilder: (c, o, s) => const Icon(Icons.podcasts, color: Colors.white24),
                                                                                          ),
                                                                                        )
                                                                                      : const Icon(Icons.podcasts, color: Colors.white24),
                                                                              ),
                                                                            ],
                                                                        ),
                                                                        title: Text(
                                                                        episode.title,
                                                                        style: const TextStyle(
                                                                            color: Colors.white, fontWeight: FontWeight.bold),
                                                                        maxLines: 1,
                                                                        overflow: TextOverflow.ellipsis,
                                                                        ),
                                                                        subtitle: Column(
                                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                                        children: [
                                                                            Text(
                                                                            podcast.title,
                                                                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                                                                            maxLines: 1,
                                                                            overflow: TextOverflow.ellipsis,
                                                                            ),
                                                                            const SizedBox(height: 4),
                                                                            Consumer<SettingsProvider>(
                                                                                builder: (context, settings, _) {
                                                                                    final pos = Duration(seconds: action.position ?? 0);
                                                                                    final total = Duration(seconds: action.total ?? 0);
                                                                                    
                                                                                    String text = PlayerProvider.formatProgress(
                                                                                        position: pos,
                                                                                        duration: total,
                                                                                        showPercentListened: settings.showPercentListened,
                                                                                        includeDuration: true,
                                                                                    );
                                                                                    
                                                                                    if (episode.pubDate != null) {
                                                                                        final dateStr = DateFormat('MMM d').format(episode.pubDate!);
                                                                                        text = "$dateStr • $text";
                                                                                    }
                                                                                    
                                                                                    return Text(
                                                                                        text,
                                                                                        style: const TextStyle(
                                                                                            color: Colors.deepPurpleAccent, fontSize: 10),
                                                                                    );
                                                                                }
                                                                            ),
                                                                        ],
                                                                        ),
                                                                        trailing: _isSelectionMode
                                                                            ? Checkbox(
                                                                                value: _selectedIndices.contains(index),
                                                                                onChanged: (val) {
                                                                                    setState(() {
                                                                                    if (val == true) {
                                                                                        _selectedIndices.add(index);
                                                                                    } else {
                                                                                        _selectedIndices.remove(index);
                                                                                        if (_selectedIndices.isEmpty) {
                                                                                        _isSelectionMode = false;
                                                                                        }
                                                                                    }
                                                                                    });
                                                                                },
                                                                                activeColor: Colors.deepPurpleAccent,
                                                                                )
                                                                            : ActionButton(
                                                                                icon: Icons.delete_outline,
                                                                                label: 'Remove',
                                                                                color: Colors.white54,
                                                                                textColor: Colors.white54,
                                                                                onPressed: () async {
                                                                                    final profileProvider =
                                                                                        Provider.of<ProfileProvider>(context,
                                                                                            listen: false);
                                                                                    final deviceId =
                                                                                        profileProvider.currentProfile?.deviceId;
                                                                                    if (deviceId != null) {
                                                                                    await Provider.of<PodcastProvider>(context,
                                                                                            listen: false)
                                                                                        .removeInProgressEpisode(
                                                                                            podcast, episode, deviceId);

                                                                                    if (context.mounted) {
                                                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                                                        const SnackBar(
                                                                                            content:
                                                                                                Text('Removed from In Progress')),
                                                                                        );
                                                                                        _loadData(); // Refresh list
                                                                                    }
                                                                                    }
                                                                                },
                                                                                ),
                                                                        ),
                                                                    );
                                                                },
                                                            ),
                                                        ),
                                            ),
                                        ],
                                    ),
                            ],
                        ),
                    ),
                ],
              ),
              
              Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                      top: false,
                      child: const NowPlayingBar(),
                  ),
              ),
          ],
      ),
    );
  }


}
