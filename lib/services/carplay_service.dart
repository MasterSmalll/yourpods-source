
import 'dart:async';
import 'package:flutter_carplay/flutter_carplay.dart';
// import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../models/podcast.dart';
import '../services/audio_handler.dart';
import '../providers/settings_provider.dart';
import '../services/log_service.dart';
import '../utils/media_item_builder.dart';

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
  int _lastChapterCount = -1;
  
  // Suppress root template updates (e.g. while launching an episode)
  bool _suppressUpdates = false;
  
  // When true, re-present the system Now Playing screen after a template
  // rebuild (setRootTemplate dismisses it). Cleared when user browses episodes.
  bool _shouldResumeNowPlaying = false;
  
  // Persistent CPListItem reference for in-place updates (no template rebuild)
  CPListItem? _nowPlayingListItem;
  // Track last-seen playing state in playbackState listener to avoid spurious updates
  bool _lastListenedPlaying = false;

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

  DownloadProvider? _downloadProvider;
  void setDownloadProvider(DownloadProvider provider) {
      _downloadProvider = provider;
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
        
        // Listen to playback state — only react to play/pause toggle,
        // NOT every playback event (which fires ~1/second and caused blink)
        _playbackStateSubscription = _audioHandler!.playbackState.listen((state) {
            if (state.playing != _lastListenedPlaying) {
                _lastListenedPlaying = state.playing;
                Log.d('CarPlayService', "Playback state changed: ${state.playing}");
                // Use in-place CPListItem update instead of full template rebuild
                _updateIsPlayingState(state.playing);
            }
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
    
    // START PREFETCH of episode actions for instant lookups
    if (podcastProvider.currentProfileId != null) {
        podcastProvider.syncEpisodeActions(podcastProvider.currentProfileId!);
    }
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
  
  /// Update the Now Playing list item's isPlaying indicator in-place
  /// without rebuilding the entire template (prevents blink/flash).
  void _updateIsPlayingState(bool isPlaying) {
      if (_nowPlayingListItem != null) {
          _nowPlayingListItem!.setIsPlaying(isPlaying);
          Log.d('CarPlayService', 'Updated isPlaying in-place: $isPlaying');
      } else {
          // No persistent reference yet — fall back to full rebuild
          _scheduleUpdate();
      }
  }

  bool _isQueueSame(List<MediaItem>? q1, List<MediaItem>? q2) {
    if (q1 == q2) return true;
    if (q1 == null || q2 == null) return false;
    if (q1.length != q2.length) return false;
    for (int i = 0; i < q1.length; i++) {
      if (q1[i].id != q2[i].id) return false;
    }
    return true;
  }

  void _updateContent() {
    if (_podcastProvider == null) return;
    if (_suppressUpdates) {
      Log.d('CarPlayService', 'Skipping update — suppressed during episode launch');
      return;
    }
    
    try {
      final subscriptions = _podcastProvider!.subscriptions;
      final currentQueue = _audioHandler?.queue.value;
      
      final currentMediaItemId = _audioHandler?.mediaItem.value?.id;
      final chapterCount = _playerProvider?.currentChapters?.length ?? 0;
      
      // Only rebuild template if STRUCTURAL data changed.
      // Play/pause toggle is handled by _updateIsPlayingState() in-place.
      if (subscriptions.length == _lastPodcastCount && 
          _isQueueSame(currentQueue, _lastQueue) &&
          currentMediaItemId == _lastMediaItemId &&
          chapterCount == _lastChapterCount) {
          Log.d('CarPlayService', "Skipping update - no structural changes");
          return;
      }
      
      _lastPodcastCount = subscriptions.length;
      _lastQueue = currentQueue;
      _lastMediaItemId = currentMediaItemId;
      _lastChapterCount = chapterCount;
      
      Log.d('CarPlayService', "_updateContent called (structural changes detected)");
      
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
                   detailText: Duration(seconds: c.startTime.toInt()).toString().split('.').first,
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
      // NOTE: Progress text intentionally omitted — the CarPlay Now Playing
      // screen shows progress via MPNowPlayingInfoCenter. Embedding live
      // progress here would force template rebuilds and cause screen blink.
      List<CPListItem> nowPlayingItems = [];
      if (currentMediaItem != null) {
          final detailText = currentMediaItem.album ?? "";

          final nowPlayingItem = CPListItem(
              text: currentMediaItem.title,
              detailText: detailText,
              image: currentMediaItem.artUri?.toString(),
              isPlaying: isPlayerPlaying,
              onPress: (complete, self) {
                   Log.d('CarPlayService', "Now Playing item tapped");
                   // Resume playback if paused/stopped
                   if (_audioHandler != null && !(_audioHandler!.playbackState.value.playing)) {
                       Log.i('CarPlayService', 'Resuming playback from Now Playing tap');
                       _audioHandler!.play();
                   }
                   _shouldResumeNowPlaying = true;
                   FlutterCarplay.showSharedNowPlaying(animated: true);
                   complete();
               },
          );
          // Keep persistent reference for in-place updates
          _nowPlayingListItem = nowPlayingItem;
          nowPlayingItems.add(nowPlayingItem);
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
                  onPress: (complete, self) async {
                    Log.d('CarPlayService', "Queue item tapped: ${item.title} (${item.id})");
                    
                    _suppressUpdates = true;
                    _debounceTimer?.cancel();
                    
                    int? positionSeconds;
                    if (item.extras?['position_seconds'] != null) {
                         positionSeconds = item.extras!['position_seconds'] as int;
                    }

                    try {
                        if (_playerProvider != null && item.extras?['podcastUrl'] != null) {
                            final p = Podcast(url: item.extras!['podcastUrl'], title: item.album ?? 'Unknown');
                            final e = Episode(
                                guid: item.id, 
                                title: item.title, 
                                description: '', 
                                audioUrl: item.extras?['url'],
                                imageUrl: item.artUri?.toString(),
                            );
                            await _playerProvider!.play(p, e, initialPositionSeconds: positionSeconds);
                        } else if (_audioHandler != null) {
                            MediaItem itemToPlay = item;
                            if (positionSeconds != null) {
                                 final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                                 newExtras['position_seconds'] = positionSeconds;
                                 itemToPlay = item.copyWith(extras: newExtras);
                            }
                            
                            await _audioHandler!.playMediaItem(itemToPlay);
                        }
                        
                        await Future.delayed(const Duration(milliseconds: 300));
                        _shouldResumeNowPlaying = true;
                        await FlutterCarplay.showSharedNowPlaying(animated: true);
                        _audioHandler?.refreshNowPlayingInfo();
                    } catch (err) {
                        Log.e('CarPlayService', "Error playing queue item: $err");
                    } finally {
                        Future.delayed(const Duration(milliseconds: 2000), () {
                            _suppressUpdates = false;
                            // Sync ALL cache fields to current state to prevent
                            // unnecessary template rebuild that dismisses Now Playing
                            _lastMediaItemId = _audioHandler?.mediaItem.value?.id;

                            _lastChapterCount = _playerProvider?.currentChapters?.length ?? 0;
                            _lastQueue = _audioHandler?.queue.value;
                            _lastPodcastCount = _podcastProvider?.subscriptions.length ?? _lastPodcastCount;
                        });
                    }
                    
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
                CPListSection(items: upNextItems, header: "Up Next"),
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
      // Required by flutter_carplay to register onPress callbacks on native side.
      // Without this, tapping any list item shows an infinite spinner.
      // Blink is prevented by the other fixes that reduced how often we reach this code.
      _flutterCarplay.forceUpdateRootTemplate();

      
      // Re-present the Now Playing screen if it should be showing.
      // setRootTemplate dismisses presented templates, so we re-show it
      // after a short delay to let the framework finish processing.
       if (_shouldResumeNowPlaying) {
           // Clear flag BEFORE the delayed callback to prevent re-triggering
           // if another template rebuild happens during the 500ms window.
           _shouldResumeNowPlaying = false;
           Future.delayed(const Duration(milliseconds: 500), () async {
               Log.d('CarPlayService', 'Re-presenting Now Playing after template rebuild');
               await FlutterCarplay.showSharedNowPlaying(animated: false);
               // Removed refreshNowPlayingInfo() here — it's only needed after
               // explicit user actions (play/seek/skip), not after template rebuilds.
               // Calling it here triggered _broadcastState → playbackState stream →
               // _scheduleUpdate() creating a feedback loop.
           });
       }
      
      // Removed automatic clearing of _shouldResumeNowPlaying when paused
      // to ensure the Now Playing screen persists.

    } catch (e) {
      Log.e('CarPlayService', "Error updating content: $e");
    }
  }
  Future<void> _showEpisodes(Podcast p) async {
      Log.d('CarPlayService', "Fetching episodes for ${p.title}...");
      // User is actively browsing — don't yank them back to Now Playing
      _shouldResumeNowPlaying = false;
      if (_podcastProvider == null) return;
      try {
        // Use getEpisodes to leverage memory/file cache for speed
        final episodes = await _podcastProvider!.getEpisodes(p.url)
            .timeout(const Duration(seconds: 4));

        Map<String, String> statuses = {};
        if (_podcastProvider?.currentProfileId != null) {
            statuses = await _podcastProvider!.getEpisodeStatuses(p.url, _podcastProvider!.currentProfileId!);
        }
        
        final hidePlayed = _settingsProvider?.hidePlayedEpisodes ?? false;
        
        final filteredEpisodes = episodes.where((e) {
            if (!hidePlayed) return true;
            // Check status
            final status = statuses[e.guid];
            return status != 'played';
        }).toList();

        Log.i('CarPlayService', "Found ${episodes.length} episodes for ${p.title} (Showing ${filteredEpisodes.length})");
        
        if (filteredEpisodes.isEmpty) {
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
        
        final items = filteredEpisodes.map((e) {
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

            // A4: Surface progress for partially-played episodes
            final queueItem = _audioHandler?.queue.value
                .cast<MediaItem?>()
                .firstWhere((i) => i?.id == e.guid, orElse: () => null);
            final posSeconds = queueItem?.extras?['position_seconds'] as int?;
            final durSeconds = (e.duration?.inSeconds ?? queueItem?.duration?.inSeconds);
            if (posSeconds != null && posSeconds > 0 && durSeconds != null && durSeconds > 0) {
                final posStr = '${(posSeconds ~/ 60).toString().padLeft(2, '0')}:${(posSeconds % 60).toString().padLeft(2, '0')}';
                final durStr = '${(durSeconds ~/ 60).toString().padLeft(2, '0')}:${(durSeconds % 60).toString().padLeft(2, '0')}';
                detailText = '▶ $posStr / $durStr${detailText.isNotEmpty ? ' • $detailText' : ''}';
            }
            
            return CPListItem(
                text: e.title,
                detailText: detailText,
                image: episodeImage, // Episode or podcast artwork
                isPlaying: isCurrentItem && isPlayerPlaying, // Playing indicator
                onPress: (complete, self) async {
                    Log.i('CarPlayService', "Play episode TAPPED: ${e.title} (${e.guid})");
                    if (_playerProvider != null && e.audioUrl != null) {
                        // Suppress root template updates while we're launching the episode
                        // to prevent setRootTemplate from popping us back to home
                        _suppressUpdates = true;
                        _debounceTimer?.cancel();
                        
                        try {
                            // Use PlayerProvider to ensure sync
                            await _playerProvider!.play(p, e, downloadProvider: _downloadProvider);
                            
                            // Small delay to let the audio handler settle before showing Now Playing
                            await Future.delayed(const Duration(milliseconds: 300));
                            
                            // Show Now Playing screen
                            _shouldResumeNowPlaying = true;
                            await FlutterCarplay.showSharedNowPlaying(animated: true);
                            _audioHandler?.refreshNowPlayingInfo();
                        } catch (err) {
                            Log.e('CarPlayService', 'Error playing episode from CarPlay: $err');
                        } finally {
                            // Re-enable updates after a delay so we don't
                            // immediately reset the template while play() is still loading
                            Future.delayed(const Duration(milliseconds: 2000), () {
                                _suppressUpdates = false;
                                // Sync ALL cache fields to current state to prevent
                                // unnecessary template rebuild that dismisses Now Playing
                                _lastMediaItemId = _audioHandler?.mediaItem.value?.id;
    
                                _lastChapterCount = _playerProvider?.currentChapters?.length ?? 0;
                                _lastQueue = _audioHandler?.queue.value;
                                _lastPodcastCount = _podcastProvider?.subscriptions.length ?? _lastPodcastCount;
                            });
                        }
                    } else if (_audioHandler != null && e.audioUrl != null) {
                         // Fallback if player provider missing
                        _suppressUpdates = true;
                        _debounceTimer?.cancel();
                        final item = MediaItemBuilder.fromEpisode(p, e);
                        await _audioHandler!.playMediaItem(item);
                        await Future.delayed(const Duration(milliseconds: 300));
                        _shouldResumeNowPlaying = true;
                        await FlutterCarplay.showSharedNowPlaying(animated: true);
                        _audioHandler?.refreshNowPlayingInfo();
                        Future.delayed(const Duration(milliseconds: 2000), () {
                            _suppressUpdates = false;
                            _lastMediaItemId = _audioHandler?.mediaItem.value?.id;

                            _lastChapterCount = _playerProvider?.currentChapters?.length ?? 0;
                            _lastQueue = _audioHandler?.queue.value;
                            _lastPodcastCount = _podcastProvider?.subscriptions.length ?? _lastPodcastCount;
                        });
                    } else {
                        Log.e('CarPlayService', "Cannot play - Handler/Provider missing or No URL");
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


