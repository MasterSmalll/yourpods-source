
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
import '../services/chapter_service.dart';
import '../services/log_service.dart';

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
  List<MediaItem>? _lastQueue;
  String? _lastMediaItemId;
  bool _lastIsPlaying = false;
  int _lastChapterCount = -1;

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
    Log.d('CarPlayService', "init called");
    _podcastProvider = podcastProvider;

    // Listen to CarPlay connection changes
    _flutterCarplay.addListenerOnConnectionChange((status) {
        Log.i('CarPlayService', "Connection status changed: $status");
        if (status == ConnectionStatusTypes.connected) {
            // Refresh content when CarPlay connects
            _lastPodcastCount = -1;
            _lastQueue = null;
            _updateContent();
        }
    });

    // Listen to PodcastProvider
    _providerListener = () {
      Log.d('CarPlayService', "PodcastProvider updated");
      _scheduleUpdate();
    };
    _podcastProvider!.addListener(_providerListener!);
    
    // Listen to Queue
    if (_audioHandler != null) {
        Log.d('CarPlayService', "Listening to AudioHandler Queue");
        _queueSubscription?.cancel();
        _queueSubscription = _audioHandler!.queue.listen((queue) {
            Log.d('CarPlayService', "Queue updated: ${queue.length} items");
            _scheduleUpdate();
        });
        
        // Listen to playback state for isPlaying indicator updates
        _playbackStateSubscription = _audioHandler!.playbackState.listen((state) {
            Log.d('CarPlayService', "Playback state changed: ${state.playing}");
            _scheduleUpdate();
        });
        
        // Listen to mediaItem changes to update currently playing
        _mediaItemSubscription = _audioHandler!.mediaItem.listen((item) {
            if (item != null) {
                Log.d('CarPlayService', "MediaItem changed: ${item.title}");
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
      final currentQueue = _audioHandler?.queue.value;
      
      final currentMediaItemId = _audioHandler?.mediaItem.value?.id;
      final isCurrentlyPlaying = _audioHandler?.playbackState.value.playing ?? false;
      final chapterCount = _playerProvider?.currentChapters?.length ?? 0;
      
      // Only update if data has actually changed
      if (subscriptions.length == _lastPodcastCount && 
          currentQueue == _lastQueue &&
          currentMediaItemId == _lastMediaItemId &&
          isCurrentlyPlaying == _lastIsPlaying &&
          chapterCount == _lastChapterCount) {
          Log.d('CarPlayService', "Skipping update - no changes");
          return;
      }
      
      _lastPodcastCount = subscriptions.length;
      _lastQueue = currentQueue;
      _lastMediaItemId = currentMediaItemId;
      _lastIsPlaying = isCurrentlyPlaying;
      _lastChapterCount = chapterCount;
      
      Log.d('CarPlayService', "_updateContent called (changes detected)");
      
      final podcastItems = subscriptions.map((p) {
        return CPListItem(
          text: p.title,
          detailText: "Tap to view episodes",
          image: p.logoUrl, // Network image URL for podcast artwork
          onPress: (complete, self) async {
            Log.i('CarPlayService', "Podcast tapped: ${p.title}");
            try {
                await _showEpisodes(p);
            } catch (e) {
                Log.e('CarPlayService', "Error showing episodes: $e");
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
      
      // Define variables needed for Now Playing
      final currentMediaItem = _audioHandler?.mediaItem.value;
      final isPlayerPlaying = _audioHandler?.playbackState.value.playing ?? false;
      
      // Calculate Chapter Items
      List<CPListItem> chapterItems = [];
      final chapters = _playerProvider?.currentChapters;
      if (chapters != null && chapters.isNotEmpty) {
           chapterItems = chapters.map((c) {
               return CPListItem(
                   text: c.title,
                   detailText: "${Duration(seconds: c.startTime.toInt()).toString().split('.').first}",
                   onPress: (complete, self) {
                       Log.d('CarPlayService', "Chapter tapped: ${c.title}");
                       _audioHandler?.seek(Duration(seconds: c.startTime.toInt()));
                       FlutterCarplay.showSharedNowPlaying(animated: true);
                       complete();
                   },
               );
           }).toList();
      }
      
      // Build Now Playing / Current Item Section
      List<CPListItem> nowPlayingItems = [];
      if (currentMediaItem != null) {
          String detailText = currentMediaItem.album ?? "";
          
          // Add Progress to Now Playing item
          final playbackState = _audioHandler?.playbackState.value;
          final duration = currentMediaItem.duration;
          
          if (playbackState != null && duration != null && duration.inSeconds > 0) {
              final position = playbackState.position;
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

          nowPlayingItems.add(CPListItem(
              text: currentMediaItem.title,
              detailText: detailText,
              image: currentMediaItem.artUri?.toString(),
              isPlaying: isPlayerPlaying,
              onPress: (complete, self) {
                  Log.d('CarPlayService', "Now Playing item tapped");
                  FlutterCarplay.showSharedNowPlaying(animated: true);
                  complete();
              },
          ));
      }

      // Build Up Next (Queue) Section
      List<CPListItem> upNextItems = [];
      if (_audioHandler != null && _audioHandler!.queue.value.isNotEmpty) {
          upNextItems = _audioHandler!.queue.value
            .where((item) => item.id != currentMediaItem?.id) // Exclude current playing item from Up Next
            .map((item) {
                // ... same queue item building logic ...
                String detailText = item.artist ?? "";
                
                 // Calculate progress if possible (for queue items that are partially played)
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
                  isPlaying: false, // Not playing (since filtered out current)
                  onPress: (complete, self) {
                    Log.d('CarPlayService', "Queue item tapped: ${item.title} (${item.id})");
                    
                    int? positionSeconds;
                    if (item.extras?['position_seconds'] != null) {
                         positionSeconds = item.extras!['position_seconds'] as int;
                    }

                    if (_playerProvider != null && item.extras?['podcastUrl'] != null) {
                        final p = Podcast(url: item.extras!['podcastUrl'], title: item.album ?? 'Unknown');
                        final e = Episode(
                            guid: item.id, 
                            title: item.title, 
                            description: '', 
                            audioUrl: item.extras?['url'],
                            imageUrl: item.artUri?.toString(),
                        );
                        _playerProvider!.play(p, e, initialPositionSeconds: positionSeconds);
                    } else if (_audioHandler != null) {
                        MediaItem itemToPlay = item;
                        if (positionSeconds != null) {
                             final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                             newExtras['position_seconds'] = positionSeconds;
                             itemToPlay = item.copyWith(extras: newExtras);
                        }
                        
                        _audioHandler!.playMediaItem(itemToPlay).catchError((e) {
                            Log.e('CarPlayService', "Error playing queue item: $e");
                        });
                    }
                    
                    FlutterCarplay.showSharedNowPlaying(animated: true);
                    complete();
                  },
                );
          }).toList().cast<CPListItem>();
      }

      final nowPlayingTemplate = CPListTemplate(
        sections: [
            if (nowPlayingItems.isNotEmpty)
                CPListSection(items: nowPlayingItems, header: "Now Playing"),
            if (upNextItems.isNotEmpty)
                CPListSection(items: upNextItems, header: "Up Next")
        ], 
        title: "Now Playing",
        systemIcon: "play.circle.fill",
        emptyViewTitleVariants: ["Nothing Playing"],
        emptyViewSubtitleVariants: ["Select a podcast to start listening."],
      );

      // ... Chapter logic ... (same as before)
      
      Log.d('CarPlayService', "Updating Root Template with Now Playing tab");
      
      FlutterCarplay.setRootTemplate(
        rootTemplate: CPTabBarTemplate(
          templates: [
            nowPlayingTemplate, // First tab
            podcastList, 
            if (chapterItems.isNotEmpty)
              CPListTemplate(
                sections: [CPListSection(items: chapterItems, header: "Chapters")],
                title: "Chapters",
                systemIcon: "list.bullet",
                emptyViewTitleVariants: ["No Chapters"],
                emptyViewSubtitleVariants: ["This episode has no chapters."],
              ),
          ],
        ),
        animated: true, 
      );
      
      // Force update to ensure callbacks are properly connected
      _flutterCarplay.forceUpdateRootTemplate();
      
    } catch (e) {
      Log.e('CarPlayService', "Error updating content: $e");
    }
  }
  Future<void> _showEpisodes(Podcast p) async {
      Log.d('CarPlayService', "Fetching episodes for ${p.title}...");
      if (_podcastProvider == null) return;
      try {
        // Use ignoreCacheAge: true to prefer speed for CarPlay
        // Add timeout to prevent infinite spinner
        final episodes = await _podcastProvider!.fetchEpisodes(p.url, ignoreCacheAge: true)
            .timeout(const Duration(seconds: 8));

        Log.i('CarPlayService', "Found ${episodes.length} episodes for ${p.title}");
        
        if (episodes.isEmpty) {
            Log.i('CarPlayService', "No episodes found.");
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
                    Log.i('CarPlayService', "Play episode TAPPED: ${e.title} (${e.guid})");
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
                        Log.e('CarPlayService', "Cannot play - Handler/Provider missing or No URL");
                        // Optional: Show error alert on CarPlay if possible or just log
                    }
                    complete();
                },
            );
        }).toList();
        
        final List<CPListItem> typedItems = items.cast<CPListItem>();
        
        Log.d('CarPlayService', "Pushing episode list");
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
          Log.e('CarPlayService', "Error fetching episodes: $e");
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


