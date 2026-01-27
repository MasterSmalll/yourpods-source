
import 'dart:async';
import 'package:flutter_carplay/flutter_carplay.dart';
// import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../models/podcast.dart';
import '../services/audio_handler.dart';
import '../providers/settings_provider.dart';

class CarPlayService {
  static final CarPlayService _instance = CarPlayService._internal();

  factory CarPlayService() {
    return _instance;
  }

  CarPlayService._internal();

  StreamSubscription? _queueSubscription;
  // BuildContext? _context; // Removed dependency on context
  PodcastAudioHandler? _audioHandler;
  PodcastProvider? _podcastProvider;
  PlayerProvider? _playerProvider;
  VoidCallback? _providerListener;
  
  // FlutterCarplay instance for proper callback registration
  final FlutterCarplay _flutterCarplay = FlutterCarplay();
  
  // Debouncing to prevent excessive template updates
  Timer? _debounceTimer;
  int _lastPodcastCount = -1;
  int _lastQueueCount = -1;

  void setAudioHandler(PodcastAudioHandler handler) {
    _audioHandler = handler;
  }

  void setPlayerProvider(PlayerProvider provider) {
    _playerProvider = provider;
  }
  
  SettingsProvider? _settingsProvider;
  void setSettingsProvider(SettingsProvider provider) {
      _settingsProvider = provider;
  }
  
  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _mediaItemSubscription;

  void init(PodcastProvider podcastProvider) {
    print("CarPlayService: init called");
    _podcastProvider = podcastProvider;

    // Listen to CarPlay connection changes
    _flutterCarplay.addListenerOnConnectionChange((status) {
        print("CarPlayService: Connection status changed: $status");
        if (status == ConnectionStatusTypes.connected) {
            // Refresh content when CarPlay connects
            _lastPodcastCount = -1;
            _lastQueueCount = -1;
            _updateContent();
        }
    });

    // Listen to PodcastProvider
    _providerListener = () {
      print("CarPlayService: PodcastProvider updated");
      _scheduleUpdate();
    };
    _podcastProvider!.addListener(_providerListener!);
    
    // Listen to Queue
    if (_audioHandler != null) {
        print("CarPlayService: Listening to AudioHandler Queue");
        _queueSubscription?.cancel();
        _queueSubscription = _audioHandler!.queue.listen((queue) {
            print("CarPlayService: Queue updated: ${queue.length} items");
            _scheduleUpdate();
        });
        
        // Listen to playback state for isPlaying indicator updates
        _playbackStateSubscription = _audioHandler!.playbackState.listen((state) {
            print("CarPlayService: Playback state changed: ${state.playing}");
            _scheduleUpdate();
        });
        
        // Listen to mediaItem changes to update currently playing
        _mediaItemSubscription = _audioHandler!.mediaItem.listen((item) {
            if (item != null) {
                print("CarPlayService: MediaItem changed: ${item.title}");
                _scheduleUpdate();
            }
        });
    }
    
    // Initial content update (immediate, no debounce)
    _updateContent();
  }

  void dispose() {
      _flutterCarplay.removeListenerOnConnectionChange();
      _debounceTimer?.cancel();
      _queueSubscription?.cancel();
      _playbackStateSubscription?.cancel();
      _mediaItemSubscription?.cancel();
      if (_podcastProvider != null && _providerListener != null) {
          _podcastProvider!.removeListener(_providerListener!);
      }
  }
  
  void _scheduleUpdate() {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
          _updateContent();
      });
  }

  void _updateContent() {
    if (_podcastProvider == null) return;
    
    try {
      final subscriptions = _podcastProvider!.subscriptions;
      final queueCount = _audioHandler?.queue.value.length ?? 0;
      
      // Only update if data has actually changed
      if (subscriptions.length == _lastPodcastCount && queueCount == _lastQueueCount) {
          print("CarPlayService: Skipping update - no changes");
          return;
      }
      
      _lastPodcastCount = subscriptions.length;
      _lastQueueCount = queueCount;
      
      print("CarPlayService: _updateContent called (podcasts: $_lastPodcastCount, queue: $_lastQueueCount)");
      
      final podcastItems = subscriptions.map((p) {
        return CPListItem(
          text: p.title,
          detailText: "Tap to view episodes",
          image: p.logoUrl, // Network image URL for podcast artwork
          onPress: (complete, self) async {
            print("CarPlay: Podcast tapped: ${p.title}");
            try {
                await _showEpisodes(p);
            } catch (e) {
                print("CarPlay: Error showing episodes: $e");
            } finally {
                complete();
            }
          },
        );
      }).toList();

      final List<CPListItem> typedPodcastItems = podcastItems.cast<CPListItem>();
      final podcastList = CPListTemplate(
        sections: [CPListSection(items: typedPodcastItems, header: "Library (${typedPodcastItems.length})")],
        title: "Podcasts",
        systemIcon: "music.note.list",
        emptyViewTitleVariants: ["No Subscriptions"],
        emptyViewSubtitleVariants: ["Add podcasts on your phone"],
      );
      
      // Build Queue List
      List<CPListItem> queueItems = [];
      final currentMediaItem = _audioHandler?.mediaItem.value;
      final isPlayerPlaying = _audioHandler?.internalPlayer.playing ?? false;
      
      if (_audioHandler != null && _audioHandler!.queue.value.isNotEmpty) {
          queueItems = _audioHandler!.queue.value.map((item) {
                final isCurrentItem = currentMediaItem?.id == item.id;
                
                String detailText = item.artist ?? "";
                
                // Calculate progress if possible
                if (item.extras?['position_seconds'] != null && item.duration != null) {
                    final position = Duration(seconds: item.extras!['position_seconds'] as int);
                    final duration = item.duration!;
                    
                    if (duration.inSeconds > 0) {
                         final showPercentListened = _settingsProvider?.showPercentListened ?? false;
                         final progressString = PlayerProvider.formatProgress(
                             position: position, 
                             duration: duration, 
                             showPercentListened: showPercentListened
                         );
                         
                         if (detailText.isNotEmpty) {
                             detailText += " • $progressString";
                         } else {
                             detailText = progressString;
                         }
                    }
                }
                
                return CPListItem(
                  text: item.title,
                  detailText: detailText,
                  image: item.artUri?.toString(), // Artwork from MediaItem
                  isPlaying: isCurrentItem && isPlayerPlaying, // Show playing indicator
                  onPress: (complete, self) {
                    print("CarPlay: Queue item tapped: ${item.title} (${item.id})");
                    
                    if (_playerProvider != null && item.extras?['podcastUrl'] != null) {
                        // Reconstruct for PlayerProvider to handle sync
                        final p = Podcast(url: item.extras!['podcastUrl'], title: item.album ?? 'Unknown');
                        final e = Episode(
                            guid: item.id, 
                            title: item.title, 
                            description: '', 
                            audioUrl: item.extras?['url'],
                            imageUrl: item.artUri?.toString(),
                        );
                        _playerProvider!.play(p, e);
                    } else {
                        // Fallback
                        _audioHandler!.playMediaItem(item).catchError((e) {
                            print("CarPlay: Error playing queue item: $e");
                        });
                    }
                    
                    // Show Now Playing screen for visual feedback
                    FlutterCarplay.showSharedNowPlaying(animated: true);
                    complete();
                  },
                );
          }).toList().cast<CPListItem>();
      }

      final queueList = CPListTemplate(
        sections: [
            if (queueItems.isNotEmpty)
                CPListSection(items: queueItems, header: "Up Next")
        ], 
        title: "Queue",
        systemIcon: "list.number",
        emptyViewTitleVariants: ["Queue Empty"],
        emptyViewSubtitleVariants: ["Add episodes to your queue."],
      );
      
      // Build Recent / Now Playing section
      List<CPListItem> recentItems = [];
      if (currentMediaItem != null) {
          recentItems.add(CPListItem(
              text: currentMediaItem.title,
              detailText: currentMediaItem.album ?? "",
              image: currentMediaItem.artUri?.toString(),
              isPlaying: isPlayerPlaying,
              onPress: (complete, self) {
                  print("CarPlay: Recent item tapped - showing Now Playing");
                  FlutterCarplay.showSharedNowPlaying(animated: true);
                  complete();
              },
          ));
      }
      
      final recentList = CPListTemplate(
        sections: [
            if (recentItems.isNotEmpty)
                CPListSection(items: recentItems, header: "Now Playing")
        ], 
        title: "Recent",
        systemIcon: "clock.fill",
        emptyViewTitleVariants: ["Nothing Playing"],
        emptyViewSubtitleVariants: ["Select an episode to start listening."],
      );
      
      print("CarPlayService: Updating Root Template with ${typedPodcastItems.length} podcasts, ${queueItems.length} queue items, ${recentItems.length} recent");
      
      FlutterCarplay.setRootTemplate(
        rootTemplate: CPTabBarTemplate(
          templates: [podcastList, queueList, recentList],
        ),
        animated: true, 
      );
      
      // Force update to ensure callbacks are properly connected
      _flutterCarplay.forceUpdateRootTemplate();
      
    } catch (e) {
      print("CarPlayService: Error updating content: $e");
    }
  }
  Future<void> _showEpisodes(Podcast p) async {
      print("CarPlayService: Fetching episodes for ${p.title}...");
      if (_podcastProvider == null) return;
      try {
        // Use ignoreCacheAge: true to prefer speed for CarPlay
        // Add timeout to prevent infinite spinner
        final episodes = await _podcastProvider!.fetchEpisodes(p.url, ignoreCacheAge: true)
            .timeout(const Duration(seconds: 8));

        print("CarPlayService: Found ${episodes.length} episodes for ${p.title}");
        
        if (episodes.isEmpty) {
            print("CarPlayService: No episodes found.");
            FlutterCarplay.push(
                template: CPListTemplate(
                    sections: [CPListSection(items: [CPListItem(text: "No Episodes", detailText: "", onPress: (c, s) => c())])],
                    title: p.title,
                    systemIcon: "music.note",
                    backButton: CPBarButton(title: "Back", style: CPBarButtonStyles.none, onPress: () => FlutterCarplay.pop()),
                ),
                animated: true,
            );
            return;
        }

        final currentMediaItem = _audioHandler?.mediaItem.value;
        final isPlayerPlaying = _audioHandler?.internalPlayer.playing ?? false;
        
        final items = episodes.map((e) {
            // Build detail text: truncated description + date
            String detailText = "";
            if (e.pubDate != null) {
                final date = e.pubDate!;
                detailText = "${date.month}/${date.day}/${date.year}";
            }
            if (e.description != null && e.description!.isNotEmpty) {
                final desc = e.description!.replaceAll(RegExp(r'<[^>]*>'), ''); // Strip HTML
                final truncated = desc.length > 50 ? '${desc.substring(0, 50)}...' : desc;
                detailText = detailText.isNotEmpty ? "$detailText • $truncated" : truncated;
            }
            
            final isCurrentItem = currentMediaItem?.id == e.guid;
            final episodeImage = e.imageUrl ?? p.logoUrl;
            
            return CPListItem(
                text: e.title,
                detailText: detailText,
                image: episodeImage, // Episode or podcast artwork
                isPlaying: isCurrentItem && isPlayerPlaying, // Playing indicator
                onPress: (complete, self) {
                    print("CarPlay: Play episode TAPPED: ${e.title} (${e.guid})");
                    if (_playerProvider != null && e.audioUrl != null) {
                        // Use PlayerProvider to ensure sync happen
                        _playerProvider!.play(p, e);
                        
                        // Show Now Playing screen for visual feedback
                        FlutterCarplay.showSharedNowPlaying(animated: true);
                    } else if (_audioHandler != null && e.audioUrl != null) {
                         // Fallback if player provider missing
                        final item = MediaItem(
                            id: e.guid, 
                            album: p.title,
                            title: e.title,
                            artUri: episodeImage != null ? Uri.parse(episodeImage) : null,
                            extras: {'url': e.audioUrl},
                        );
                        _audioHandler!.playMediaItem(item);
                         FlutterCarplay.showSharedNowPlaying(animated: true);
                    } else {
                        print("CarPlay: Cannot play - Handler/Provider missing or No URL");
                    }
                    complete();
                },
            );
        }).toList();
        
        final List<CPListItem> typedItems = items.cast<CPListItem>();
        
        print("CarPlayService: Pushing episode list");
        FlutterCarplay.push(
            template: CPListTemplate(
                sections: [CPListSection(items: typedItems)],
                title: p.title,
                systemIcon: "music.note",
                backButton: CPBarButton(
                    title: "Back", 
                    style: CPBarButtonStyles.none, 
                    onPress: () { 
                        FlutterCarplay.pop(); 
                    } 
                ),
            ),
            animated: true,
        );
      } catch (e) {
          print("CarPlayService: Error fetching episodes: $e");
          // Show error to user
          FlutterCarplay.push(
            template: CPListTemplate(
                sections: [CPListSection(items: [CPListItem(text: "Connection Error", detailText: "Could not load episodes.", onPress: (c, s) => c())])],
                title: "Error",
                systemIcon: "exclamationmark.triangle",
                backButton: CPBarButton(title: "Back", style: CPBarButtonStyles.none, onPress: () => FlutterCarplay.pop()),
            ),
            animated: true,
          );
      }
  }
}


