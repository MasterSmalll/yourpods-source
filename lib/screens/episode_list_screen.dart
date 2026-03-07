import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/podcast.dart';
import '../providers/podcast_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/action_button.dart';
import '../providers/settings_provider.dart';
import 'player_screen.dart';

class EpisodeListScreen extends StatefulWidget {
  final Podcast podcast;
  const EpisodeListScreen({super.key, required this.podcast});

  @override
  State<EpisodeListScreen> createState() => _EpisodeListScreenState();
}

class _EpisodeListScreenState extends State<EpisodeListScreen> {
  List<Episode>? _episodes;
  bool _isLoading = true;
  String? _error;

  Map<String, String> _episodeStatuses = {};
  bool _isUsDateFormat = true;

  bool _isSelectionMode = false;
  final Set<String> _selectedEpisodeGuids = {};

  int _displayLimit = 20;

  @override
  void initState() {
    super.initState();
    _loadDateFormat();
    _loadEpisodes();
  }

  Future<void> _loadDateFormat() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
        setState(() {
            _isUsDateFormat = prefs.getBool('use_us_date_format') ?? true;
        });
    }
  }

  Future<void> _toggleDateFormat() async {
      final prefs = await SharedPreferences.getInstance();
      final newValue = !_isUsDateFormat;
      await prefs.setBool('use_us_date_format', newValue);
      if (mounted) {
          setState(() {
              _isUsDateFormat = newValue;
          });
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text('Date format switched to ${newValue ? "MM-DD-YYYY" : "DD-MM-YYYY"}'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(milliseconds: 1500),
              )
          );
      }
  }

  Future<void> _loadEpisodes({bool forceRefresh = false}) async {
    try {
      final provider = Provider.of<PodcastProvider>(context, listen: false);
      // Pass forceRefresh to provider
      final episodes = await provider.fetchEpisodes(widget.podcast.url, forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _episodes = episodes;
          _isLoading = false;
        });
        
        // Load statuses after episodes are loaded
        _loadStatuses();

        // Check download status for these episodes
        if (_episodes != null) {
            final urls = _episodes!.map((e) => e.audioUrl).whereType<String>().toList();
            Provider.of<DownloadProvider>(context, listen: false).checkDownloads(urls);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadStatuses() async {
      if (_episodes == null) return;
      final provider = Provider.of<PodcastProvider>(context, listen: false);
      final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
      final deviceId = profileProvider.currentProfile?.deviceId ?? 'yourpods-ios';
      
      final serverStatuses = await provider.getEpisodeStatuses(widget.podcast.url, deviceId);
      final newStatuses = <String, String>{};
      
      for (var episode in _episodes!) {
          final serverStatus = serverStatuses[episode.guid];
          if (serverStatus != null) {
              newStatuses[episode.guid] = serverStatus; // 'played', 'in_progress', 'interacted'
          } else {
              final isNew = await provider.isEpisodeNew(widget.podcast.url, episode.guid);
              newStatuses[episode.guid] = isNew ? 'new' : 'none';
          }
      }
      
      if (mounted) {
          setState(() {
              _episodeStatuses = newStatuses;
          });
      }
  }

  Future<void> _markAsInteracted(Episode episode) async {
      if (_episodeStatuses[episode.guid] == 'new') {
          final provider = Provider.of<PodcastProvider>(context, listen: false);
          await provider.markEpisodeAsInteracted(widget.podcast.url, episode.guid);
          if (mounted) {
              setState(() {
                  _episodeStatuses[episode.guid] = 'none';
              });
          }
      }
  }

  Future<void> _markAllAsPlayed() async {
      if (_episodes == null || _episodes!.isEmpty) return;

      final shouldMark = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
              title: const Text('Mark all as played?'),
              content: const Text('This will mark all episodes as played.'),
              backgroundColor: const Color(0xFF1F1E27),
              titleTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              contentTextStyle: const TextStyle(color: Colors.white70),
              actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                  ),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Mark Played', style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold)),
                  ),
              ],
          ),
      );

      if (shouldMark != true) return;

      final provider = Provider.of<PodcastProvider>(context, listen: false);
      final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
      final deviceId = profileProvider.currentProfile?.deviceId ?? 'yourpods-ios';

      // Optimistic UI: update immediately so user sees the change
      if (mounted) {
          setState(() {
              for (var e in _episodes!) {
                  _episodeStatuses[e.guid] = 'played';
              }
          });
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Marking all as played...')),
          );
      }
      
      final items = _episodes!.map((e) => {
          'podcast': widget.podcast,
          'episode': e,
      }).toList();

      // Fire-and-forget: sync to server in background
      provider.markEpisodesAsPlayed(items, deviceId).catchError((e) {
          if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Sync failed: $e'), backgroundColor: Colors.redAccent),
              );
          }
      });
  }

  void _toggleSelectionMode() {
      setState(() {
          _isSelectionMode = !_isSelectionMode;
          _selectedEpisodeGuids.clear();
      });
  }
  
  void _toggleSelection(String guid) {
      setState(() {
          if (_selectedEpisodeGuids.contains(guid)) {
              _selectedEpisodeGuids.remove(guid);
              if (_selectedEpisodeGuids.isEmpty) {
                  _isSelectionMode = false;
              }
          } else {
              _selectedEpisodeGuids.add(guid);
              _isSelectionMode = true;
          }
      });
  }

  Future<void> _addSelectedToQueue() async {
      if (_selectedEpisodeGuids.isEmpty) return;
      
      final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
      final episodesToAdd = <Map<String, dynamic>>[];
      
      for (var guid in _selectedEpisodeGuids) {
          try {
              final episode = _episodes!.firstWhere((e) => e.guid == guid);
              episodesToAdd.add({
                  'podcast': widget.podcast,
                  'episode': episode,
              });
          } catch (e) {
              // ignore
          }
      }
      
      if (episodesToAdd.isNotEmpty) {
          await playerProvider.addEpisodesToQueue(episodesToAdd);
          if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${episodesToAdd.length} to queue')));
              setState(() {
                  _isSelectionMode = false;
                  _selectedEpisodeGuids.clear();
              });
          }
      }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode 
            ? IconButton(
                icon: const Icon(Icons.close), 
                onPressed: _toggleSelectionMode,
              )
            : null,
        title: _isSelectionMode 
            ? Text('${_selectedEpisodeGuids.length} Selected')
            : Text(widget.podcast.title),
        backgroundColor: Colors.transparent,
        actions: [
            if (_isSelectionMode)
                ActionChip( // Use ActionChip or similar for better fit in AppBar, or just ActionButton but carefully.
                    avatar: const Icon(Icons.playlist_add, size: 20, color: Colors.white),
                    label: const Text('Add Queue', style: TextStyle(color: Colors.white)),
                    backgroundColor: Colors.deepPurple,
                    onPressed: _addSelectedToQueue,
                )
            else ...[
                ActionButton(
                    icon: Icons.checklist,
                    label: 'Select',
                    onPressed: _toggleSelectionMode,
                    color: Colors.white,
                    textColor: Colors.white,
                ),
                PopupMenuButton<String>(
                    icon: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                            Icon(Icons.more_vert, color: Colors.white),
                            Text('Menu', style: TextStyle(color: Colors.white60, fontSize: 10)),
                        ],
                    ),
                    onSelected: (value) async {
                        if (value == 'mark_all') {
                            _markAllAsPlayed();
                        } else if (value == 'toggle_played') {
                            final settings = Provider.of<SettingsProvider>(context, listen: false);
                            settings.setHidePlayedEpisodes(!settings.hidePlayedEpisodes);
                        }
                    },
                    itemBuilder: (context) {
                        final settings = Provider.of<SettingsProvider>(context, listen: false);
                        return [
                            PopupMenuItem(
                                value: 'toggle_played',
                                child: Row(
                                    children: [
                                        Icon(settings.hidePlayedEpisodes ? Icons.visibility_off : Icons.visibility, color: Colors.black),
                                        const SizedBox(width: 8),
                                        Text(settings.hidePlayedEpisodes ? 'Show Played' : 'Hide Played'),
                                    ],
                                ),
                            ),
                            const PopupMenuItem(
                                value: 'mark_all',
                                child: Row(
                                    children: [Icon(Icons.check_circle_outline, color: Colors.black), SizedBox(width: 8), Text('Mark All Played')],
                                ),
                            ),
                        ];
                    },
                ),
            ],
        ],
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.deepPurple))
              : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : Consumer2<DownloadProvider, SettingsProvider>(
                      builder: (context, downloadProvider, settings, child) {
                        var visibleEpisodes = _episodes!;
                        
                        if (settings.hidePlayedEpisodes) {
                            visibleEpisodes = visibleEpisodes.where((e) {
                                final status = _episodeStatuses[e.guid];
                                return status != 'played';
                            }).toList();
                        }
                        
                        visibleEpisodes = visibleEpisodes.take(_displayLimit).toList();
                        
                        return RefreshIndicator(
                          onRefresh: () => _loadEpisodes(forceRefresh: true),
                          child: ListView.separated(
                            padding: const EdgeInsets.only(bottom: 80),
                            itemCount: visibleEpisodes.length + (_episodes!.length > _displayLimit ? 1 : 0),
                            separatorBuilder: (context, index) => Divider(color: Colors.white.withOpacity(0.1)),
                            itemBuilder: (context, index) {
                              if (index == visibleEpisodes.length) {
                                  return Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: TextButton(
                                          child: const Text('Load More Episodes'),
                                          onPressed: () {
                                              setState(() {
                                                  _displayLimit += 20;
                                              });
                                          },
                                      ),
                                  );
                              }
                            
                              final episode = visibleEpisodes[index];
                              final status = downloadProvider.getStatus(episode.audioUrl ?? '');
                              final progress = downloadProvider.getProgress(episode.audioUrl ?? '');
                              final episodeStatus = _episodeStatuses[episode.guid] ?? 'none';

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                title: Text(
                                  episode.title,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold, 
                                      color: episodeStatus == 'played' ? Colors.white38 : Colors.white
                                  ),
                                ),
                                subtitle: GestureDetector(
                                  onLongPress: _toggleDateFormat,
                                  child: Text(
                                    _formatSubtitle(episode.pubDate, episode.duration),
                                    style: const TextStyle(color: Colors.white60),
                                  ),
                                ),
                                leading: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                        if (_isSelectionMode)
                                            Checkbox(
                                                value: _selectedEpisodeGuids.contains(episode.guid),
                                                activeColor: Colors.deepPurpleAccent,
                                                checkColor: Colors.white,
                                                fillColor: WidgetStateProperty.resolveWith((states) {
                                                    if (states.contains(WidgetState.selected)) {
                                                        return Colors.deepPurpleAccent;
                                                    }
                                                    return Colors.white54;
                                                }),
                                                onChanged: (val) => _toggleSelection(episode.guid),
                                            ),
                                        Stack(
                                            children: [
                                                episode.imageUrl != null
                                                    ? ClipRRect(
                                                        borderRadius: BorderRadius.circular(4),
                                                        child: Image.network(episode.imageUrl!, width: 50, height: 50, fit: BoxFit.cover),
                                                      )
                                                    : const Icon(Icons.podcasts, color: Colors.deepPurple, size: 40),
                                                
                                                if (episodeStatus == 'new')
                                                    Positioned(
                                                        top: -2,
                                                        right: -2,
                                                        child: Container(
                                                            width: 12,
                                                            height: 12,
                                                            decoration: BoxDecoration(
                                                                color: Colors.blueAccent,
                                                                shape: BoxShape.circle,
                                                                border: Border.all(color: const Color(0xFF1F1E27), width: 1.5),
                                                            ),
                                                        ),
                                                    ),
                                                if (episodeStatus == 'played')
                                                    Positioned.fill(
                                                        child: Container(
                                                            color: Colors.black54,
                                                            child: const Icon(Icons.check, color: Colors.greenAccent, size: 30),
                                                        ),
                                                    ),
                                                 if (episodeStatus == 'in_progress')
                                                    Positioned(
                                                        bottom: 0,
                                                        left: 0,
                                                        right: 0,
                                                        child: Container(
                                                            height: 4,
                                                            color: Colors.deepPurpleAccent,
                                                        ),
                                                    ),
                                            ],
                                        ),
                                    ],
                                ),
                                trailing: _isSelectionMode 
                                    ? null 
                                    : _buildDownloadButton(episode.audioUrl, status, progress, downloadProvider, episode),
                                onTap: () async {
                                  if (_isSelectionMode) {
                                      _toggleSelection(episode.guid);
                                      return;
                                  }
                                  _markAsInteracted(episode);
                                  final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                                  playerProvider.play(widget.podcast, episode, downloadProvider: downloadProvider);
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => const PlayerScreen()),
                                  );
                                  if (context.mounted) {
                                      _loadDateFormat();
                                      _loadStatuses(); // Refresh statuses in case they changed in Player
                                  }
                                },
                              );
                            },
                          ),
                        );
                      },
                    ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: NowPlayingBar(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildDownloadButton(String? url, DownloadState status, double progress, DownloadProvider provider, Episode episode) {
      if (url == null) return const SizedBox();
      
      Widget downloadWidget;
      switch (status) {
          case DownloadState.none:
              downloadWidget = IconButton(
                  icon: const Icon(Icons.download_for_offline_outlined, color: Colors.white70),
                  tooltip: 'Download',
                  onPressed: () => provider.downloadEpisode(url),
              );
              break;
          case DownloadState.error:
              downloadWidget = IconButton(
                  icon: const Icon(Icons.error_outline, color: Colors.redAccent),
                  tooltip: 'Retry download',
                  onPressed: () {
                      final error = provider.getError(url);
                      if (error != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Download failed: $error'), backgroundColor: Colors.redAccent),
                          );
                      }
                      provider.downloadEpisode(url);
                  },
              );
              break;
          case DownloadState.downloading:
              // Keep generic spinner for downloading state as it's not an action
              downloadWidget = SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      value: progress, 
                      strokeWidth: 2, 
                      color: Colors.deepPurpleAccent
                  ),
              );
              break;
          case DownloadState.pausedCellular:
              downloadWidget = IconButton(
                  icon: const Icon(Icons.pause_circle_outline, color: Colors.orangeAccent),
                  tooltip: 'Paused (cellular) — will resume on WiFi',
                  onPressed: () => provider.downloadEpisode(url),
              );
              break;
          case DownloadState.downloaded:
              downloadWidget = IconButton(
                  icon: const Icon(Icons.check_circle, color: Colors.greenAccent),
                  tooltip: 'Downloaded (tap to delete)',
                  onPressed: () {
                      provider.deletedownload(url);
                  },
              );
              break;
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
            downloadWidget,
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white70),
              onSelected: (value) {
                final player = Provider.of<PlayerProvider>(context, listen: false);
                if (value == 'play_next') {
                    player.playNextInQueue(widget.podcast, episode);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Playing next')));
                } else if (value == 'add_queue') {
                    player.addToQueue(widget.podcast, episode);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to queue')));
                } else if (value == 'details') {
                   _markAsInteracted(episode);
                   _showEpisodeDetails(episode);
                } else if (value == 'mark_played') {
                   final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
                   final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
                   final deviceId = profileProvider.currentProfile?.deviceId ?? 'yourpods-ios';
                   
                   podcastProvider.markEpisodesAsPlayed(
                      [{'podcast': widget.podcast, 'episode': episode}], 
                      deviceId
                   );
                   
                   setState(() {
                       _episodeStatuses[episode.guid] = 'played';
                   });
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as played')));
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'play_next',
                  child: Row(children: [Icon(Icons.play_arrow, color: Colors.black), SizedBox(width: 8), Text('Play Next')]),
                ),
                const PopupMenuItem(
                  value: 'add_queue',
                  child: Row(children: [Icon(Icons.playlist_add, color: Colors.black), SizedBox(width: 8), Text('Add to Queue')]),
                ),
                const PopupMenuItem(
                  value: 'mark_played',
                  child: Row(children: [Icon(Icons.check_circle_outline, color: Colors.black), SizedBox(width: 8), Text('Mark as Played')]),
                ),
                const PopupMenuItem(
                  value: 'details',
                  child: Row(children: [Icon(Icons.info_outline, color: Colors.black), SizedBox(width: 8), Text('Details')]),
                ),
              ],
            ),
        ],
      );
  }

  void _showEpisodeDetails(Episode episode) {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1F1E27),
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          isScrollControlled: true,
          builder: (context) {
              return DraggableScrollableSheet(
                  initialChildSize: 0.6,
                  minChildSize: 0.4,
                  maxChildSize: 0.9,
                  expand: false,
                  builder: (context, scrollController) {
                      return Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: ListView(
                              controller: scrollController,
                              children: [
                                  Center(
                                      child: Container(
                                          width: 40,
                                          height: 4,
                                          margin: const EdgeInsets.only(bottom: 24),
                                          decoration: BoxDecoration(
                                              color: Colors.white24,
                                              borderRadius: BorderRadius.circular(2),
                                          ),
                                      ),
                                  ),
                                  if (episode.imageUrl != null)
                                      Center(
                                          child: ClipRRect(
                                              borderRadius: BorderRadius.circular(12),
                                              child: Image.network(
                                                  episode.imageUrl!,
                                                  width: 150,
                                                  height: 150,
                                                  fit: BoxFit.cover,
                                              ),
                                          ),
                                      ),

                                  const SizedBox(height: 24),
                                  
                                  // Action Buttons
                                  Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                          ActionButton(
                                              icon: Icons.playlist_add,
                                              label: 'Add to Queue',
                                              onPressed: () {
                                                  final player = Provider.of<PlayerProvider>(context, listen: false);
                                                  player.addToQueue(widget.podcast, episode);
                                                  Navigator.pop(context);
                                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to queue')));
                                              },
                                          ),
                                      ],
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                      episode.title,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                      ),
                                      textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                      _formatSubtitle(episode.pubDate, episode.duration),
                                      style: const TextStyle(color: Colors.white60),
                                      textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                      _stripHtml(episode.description ?? 'No description available.'),
                                      style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                                  ),
                                  const SizedBox(height: 40),
                              ],
                          ),
                      );
                  },
              );
          },
      );
  }

  String _stripHtml(String htmlString) {
      final RegExp exp = RegExp(r"<[^>]*>", multiLine: true, caseSensitive: true);
      return htmlString.replaceAll(exp, '');
  }

  String _formatSubtitle(DateTime? date, Duration? duration) {
      final dateStr = _formatDate(date);
      final durStr = _formatDuration(duration);
      
      if (dateStr.isNotEmpty && durStr.isNotEmpty) {
          return '$dateStr • $durStr';
      } else if (dateStr.isNotEmpty) {
          return dateStr;
      } else if (durStr.isNotEmpty) {
          return durStr;
      }
      return '';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    if (_isUsDateFormat) {
        return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}-${date.year}';
    } else {
        return '${date.day.toString().padLeft(2, '0')}-${date.month.toString().padLeft(2, '0')}-${date.year}';
    }
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '';
    if (duration.inHours > 0) {
        return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inMinutes}m';
  }
}
