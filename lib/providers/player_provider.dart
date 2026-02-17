import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import '../models/podcast.dart';
import '../services/chapter_service.dart';
import '../api/gpodder_api.dart';
import 'download_provider.dart';
import '../services/audio_handler.dart';
import 'podcast_provider.dart';
import 'settings_provider.dart';
import '../services/watch_service.dart';
import '../services/live_activity_service.dart';
import '../services/id3_chapter_service.dart';
import '../services/log_service.dart';
import '../services/siri_service.dart';
import '../utils/media_item_builder.dart';
import '../utils/episode_action_cache.dart';
import '../models/sync_conflict.dart';

class PlayerProvider with ChangeNotifier {
  final PodcastAudioHandler _audioHandler;
  
  // Expose internal player for legacy compat if needed, or better, rely on handler
  // For now, we use internalPlayer to minimize breaking changes in logic below
  AudioPlayer get _player => _audioHandler.internalPlayer;

  Episode? _currentEpisode;
  Podcast? _currentPodcast;
  List<Chapter>? _currentChapters;

  Episode? get currentEpisode => _currentEpisode;
  Podcast? get currentPodcast => _currentPodcast;
  List<Chapter>? get currentChapters => _currentChapters;
  
  /// Returns the chapter that is active at the given [position].
  Chapter? getCurrentChapter(Duration position) {
    if (_currentChapters == null || _currentChapters!.isEmpty) return null;
    final posSeconds = position.inSeconds.toDouble();
    Chapter? current;
    for (final ch in _currentChapters!) {
      if (ch.startTime <= posSeconds) {
        current = ch;
      } else {
        break;
      }
    }
    return current;
  }
  
  // Expose player getter if consumers need it, though they should ideally go through provider/handler
  AudioPlayer get player => _player; 
  bool get isPlaying => _player.playing;
  
  // Expose queue
  Stream<List<MediaItem>> get queueStream => _audioHandler.queue;
  List<MediaItem> get queue => _audioHandler.queue.value;
  
  DateTime _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(0);
  int? _lastSyncedPosition;
  SettingsProvider? _settings;

  // B1: Cache removed, using PodcastProvider

  // B3: Cached SharedPreferences instance
  SharedPreferences? _prefs;
  Future<SharedPreferences> get _sharedPrefs async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // B5: Debounce timestamp for _syncProgress
  DateTime _lastUploadTime = DateTime(0);

  // B8: Throttle timestamps for watch/live activity sync
  DateTime _lastWatchSyncTime = DateTime(0);
  DateTime _lastLiveActivityTime = DateTime(0);
  // B9: Track playing state to avoid redundant notifyListeners
  bool _lastPlayingState = false;

  PodcastProvider? _podcastProvider;

  void updateSettings(SettingsProvider settings) {
    if (_settings != settings) {
      _settings = settings;
      notifyListeners();
    }
    // Always check sync when settings change (e.g. user toggles auto-sync on)
    _checkWatchSync();
  }

  void updatePodcastProvider(PodcastProvider provider) {
    _podcastProvider = provider;
  }
  
  DownloadProvider? _downloadProvider;
  WatchService? _watchService;
  LiveActivityService? _liveActivityService;
  
  void updateDownloadProvider(DownloadProvider provider) {
      _downloadProvider = provider;
  }
  
  void setLiveActivityService(LiveActivityService service) {
      _liveActivityService = service;
      service.onAction = _handleLiveActivityAction;
  }

  // B7: Guards for service setters to avoid redundant re-setting
  bool get hasWatchService => _watchService != null;
  bool get hasLiveActivityService => _liveActivityService != null;
  
  void _handleLiveActivityAction(String action) {
      switch (action) {
          case 'togglePlay':
              togglePlay();
              break;
          case 'skipForward':
              fastForward();
              break;
          case 'skipBackward':
              rewind();
              break;
      }
  }
  
  void setWatchService(WatchService service) {
      _watchService = service;
      // Start listening for commands from watch
      _watchService!.listenForCommands(_audioHandler);
      _watchService!.setCustomCommandHandler((command, args) {
          final episodeId = args['episodeId'] as String?;
          
          if (command == 'remove_from_queue' && episodeId != null) {
              final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
              if (item != null) removeFromQueue(item);
          } else if (command == 'mark_as_played' && episodeId != null) {
              final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
              if (item != null) markAsListened(item);
          } else if (command == 'playLatest') {
              final podcastName = args['podcastName'] as String?;
              if (podcastName != null) {
                  SiriService().handlePlayMedia(podcastName);
              }
          } else if (command == 'update_progress') {
              final episodeId = args['episodeId'] as String?;
              final position = args['position'] as int?;
              if (episodeId != null && position != null && _podcastProvider != null) {
                  // Get current episode info if possible to populate action fields
                  // If not current, we might need to look it up or just send minimal info
                  // For minimal sync, we need podcast URL. 
                  // If it's in the queue, we can find it.
                  final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
                  if (item != null) {
                       final podcastUrl = item.extras?['podcastUrl'] as String?;
                       if (podcastUrl != null) {
                           Log.d('PlayerProvider', 'Syncing watch progress for $episodeId: $position');
                           final action = EpisodeAction(
                               podcast: podcastUrl,
                               episode: episodeId,
                               guid: episodeId,
                               action: 'play',
                               timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                               position: position,
                               started: 0,
                               total: item.duration?.inSeconds ?? 0,
                               device: 'apple-watch', // Distinguish device
                           );
                           _podcastProvider!.sendEpisodeAction(action);
                       }
                  }
              }
          }
      });
  }
  

  // Action Sync Persistence (Deprecated in PlayerProvider, moved to PodcastProvider)
  // We keep the method signatures for compatibility if needed, but they delegate.
  // ...
  
  void _checkWatchSync() {
      if (_watchService != null && _downloadProvider != null && _settings != null) {
          _watchService!.syncQueue(
              queue: _audioHandler.queue.value,
              downloadProvider: _downloadProvider!,
              settings: _settings!,
              speed: _player.speed,
              skipSilence: skipSilenceEnabled,
          );
      }
  }
  
  void _syncWatchPlaybackState() {
      if (_watchService != null) {
          _watchService!.updatePlaybackState(
              mediaItem: _audioHandler.mediaItem.value,
              isPlaying: _audioHandler.playbackState.value.playing,
          );
      }
  }
  

  static String formatDurationHuman(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m';
    }
    return '${d.inSeconds}s';
  }

  static String formatProgress({
    required Duration position,
    required Duration duration,
    required bool showPercentListened,
    bool includeDuration = false,
  }) {
    int percent = 0;
    String result;
    if (showPercentListened) {
      if (duration.inSeconds > 0) {
        percent = (position.inSeconds / duration.inSeconds * 100).clamp(0, 100).toInt();
      }
      result = '$percent% listened';
    } else {
      if (duration.inSeconds > 0) {
        final left = duration.inSeconds - position.inSeconds;
        percent = (left / duration.inSeconds * 100).clamp(0, 100).toInt();
      }
      result = '$percent% left';
    }
    if (includeDuration && duration.inSeconds > 0) {
      result = '$result • ${formatDurationHuman(duration)}';
    }
    return result;
  }

  PlayerProvider(this._audioHandler) {
    _player.positionStream.listen((position) {
       if (_player.playing && _currentEpisode != null) {
         final now = DateTime.now();
         final interval = _settings?.syncInterval ?? 30;
         if (now.difference(_lastSyncTime).inSeconds >= interval) {
           _syncProgress(action: 'play');
           _lastSyncTime = now;
         }
       }
    });
    
    // Also listen to playback state to notify listeners when state changes (e.g. from background)
    _audioHandler.playbackState.listen((state) {
        // Detect Pause event to force sync
        final playing = state.playing;
        
        if (!playing && _currentEpisode != null) {
             _syncProgress(action: 'play'); 
        }

        // Detect Completion to mark as played
        if (state.processingState == AudioProcessingState.completed && _currentEpisode != null) {
             _syncAsPlayed(_currentEpisode!);
        }

        // B8: Throttle watch and live activity sync to avoid main thread saturation
        final now = DateTime.now();
        if (now.difference(_lastWatchSyncTime).inSeconds >= 2) {
            _syncWatchPlaybackState();
            _lastWatchSyncTime = now;
        }
        if (now.difference(_lastLiveActivityTime).inSeconds >= 2) {
            _updateLiveActivity();
            _lastLiveActivityTime = now;
        }

        // B9: Only notify listeners when playing state actually changes
        // to avoid excessive widget tree rebuilds on every playback event
        if (playing != _lastPlayingState ||
            state.processingState == AudioProcessingState.completed ||
            state.processingState == AudioProcessingState.idle) {
            _lastPlayingState = playing;
            notifyListeners();
        }
    });
    
    // Listen to media item changes to update current episode info if it changes via queue
    _audioHandler.mediaItem.listen((item) {
        if (item != null && _podcastProvider != null) {
            // Need to handle potential switch from one episode to another
            // If ID changed, the previous one is done (or skipped).
            // We rely on playbackState.completed or periodic sync for the old one.
            // Here we just ensure the NEW one is loaded so future syncs work.
            _syncFromMediaItem(item, _podcastProvider!);
        }
        _syncWatchPlaybackState(); // Sync to Watch
    });

    // Listen to queue changes for fallback logic and watch sync
    _audioHandler.queue.listen((queue) {
       if (_currentEpisode == null && _podcastProvider != null) {
           _evaluateFallbackState(_podcastProvider!);
       }
       _checkWatchSync();
    });
  }

  Future<void> _syncAsPlayed(Episode episode) async {
       if (_api == null) return;
       
       final duration = episode.duration?.inSeconds ?? 0;
       
       Log.d('PlayerProvider', 'Marking ${episode.title} as played (syncing duration: $duration)');
       
       final episodeAction = EpisodeAction(
         podcast: _currentPodcast?.url ?? '', // Attempt to get url
         episode: episode.guid, 
         guid: episode.guid,
         action: 'play',
         timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
         position: duration > 0 ? duration : 1, 
         started: 0,
         total: duration > 0 ? duration : 1,
         device: _deviceId,
       );

        if (_podcastProvider != null) {
            await _podcastProvider!.sendEpisodeAction(episodeAction);
        } else {
             // Fallback if provider not linked?
            try {
              await _api!.uploadEpisodeActions([episodeAction]);
            } catch (e) {
              Log.e('PlayerProvider', 'Failed to sync marked-as-listened: $e');
            }
        }
       
       // Mark as interacted locally
       if (_currentPodcast != null) {
          _podcastProvider?.markEpisodeAsInteracted(_currentPodcast!.url, episode.guid);
       }
  }

  Future<void> forceSync({String action = 'play'}) async {
      Log.i('PlayerProvider', 'Forcing sync with action: $action');
      await _syncProgress(action: action);
  }

  GPodderApi? _api;
  String _deviceId = 'flutter-client'; // Default or injected

  void setApi(GPodderApi api, String deviceId) {
    Log.d('PlayerProvider', 'setApi called with deviceId: $deviceId');
    _api = api;
    _deviceId = deviceId;
    
    // Timestamp loading handled in PodcastProvider now.
    syncPlaybackState();
  }

  Future<void> loadInitialState(PodcastProvider podcastProvider) async {
      await _evaluateFallbackState(podcastProvider);
      // Note: enrichQueueWithPositions() is called in setApi() when API is ready
  }

  /// Syncs playback state (Episode Actions) from the server.
  /// Delegates to PodcastProvider.
  /// Syncs playback state (Episode Actions) from the server.
  /// Delegates to PodcastProvider.
  /// Returns a list of conflicts if any found (and strategy is Ask).
  Future<List<SyncConflict>> syncPlaybackState({bool force = true}) async {
      if (_podcastProvider == null) return [];
      
      Log.d('PlayerProvider', 'Delegating playback sync to PodcastProvider...');
      
      final strategy = _settings?.syncConflictStrategy ?? SyncStrategy.serverWins;
      final conflicts = await _podcastProvider!.syncEpisodeActions(_deviceId, force: force, strategy: strategy);
      
      // After sync, check if we need to seek current episode
      // If there are conflicts for the CURRENT episode, we might not want to seek automatically?
      // Or we wait for resolution?
      // If strategy is ASK, syncEpisodeActions returns conflicts but DOES NOT update local yet for those items.
      // So we shouldn't seek yet if current is conflicted.
      
      if (_currentEpisode != null && _audioHandler.mediaItem.value?.id == _currentEpisode!.guid) {
           // Check if current is in conflicts
           final isConflicted = conflicts.any((c) => c.episodeGuid == _currentEpisode!.guid);
           
           if (!isConflicted) {
               final action = _podcastProvider!.getLatestAction(_currentEpisode!.guid);
               if (action != null && action.position != null) {
                   final currentPos = _player.position.inSeconds;
                   if (action.position! > currentPos + 5) {
                        Log.i('PlayerProvider', 'Remote position ahead ($currentPos -> ${action.position}), seeking...');
                        await _audioHandler.seek(Duration(seconds: action.position!));
                   }
               }
           }
      }
      
      // Enrich Queue with new actions
      await _enrichQueueFromProvider();
      
      return conflicts;
  }

  Future<void> _enrichQueueFromProvider() async {
       if (queue.isEmpty || _podcastProvider == null) return;
       
       bool hasUpdates = false;
       final updatedQueue = queue.map((item) {
           final action = _podcastProvider!.getLatestAction(item.id);
           if (action != null && action.position != null) {
               final currentPos = item.extras?['position_seconds'] as int? ?? 0;
               if (action.position! > currentPos) {
                   hasUpdates = true;
                   final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                   newExtras['position_seconds'] = action.position;
                   return item.copyWith(extras: newExtras);
               }
           }
           return item;
       }).toList();
       
       if (hasUpdates) {
           await _audioHandler.updateQueue(updatedQueue);
           Log.d('PlayerProvider', 'Queue enriched with new actions form PodcastProvider');
       }
  }

  // Legacy method kept for signature compatibility if needed
  Future<void> _enrichQueueWithActions(Map<String, EpisodeAction> actions) async {
      await _enrichQueueFromProvider();
  }

  // Deprecated direct enriched, used internally by syncPlaybackState now
  Future<void> enrichQueueWithPositions() async {
      await syncPlaybackState();
  }


  Future<void> _evaluateFallbackState(PodcastProvider podcastProvider) async {
      // 1. Current Loaded Item (Playing or Paused)
      if (_audioHandler.mediaItem.value != null) {
          _syncFromMediaItem(_audioHandler.mediaItem.value!, podcastProvider);
          return; 
      }
      
      // 2. Queue Top (Device Queue)
      if (_audioHandler.queue.value.isNotEmpty) {
          final item = _audioHandler.queue.value.first;
          await _audioHandler.prepareMediaItem(item);
          _syncFromMediaItem(item, podcastProvider);
          return;
      }
      
      // 3. In Progress (Synced with Server)
      try {
          final inProgress = await podcastProvider.fetchInProgressEpisodes(_deviceId);
          if (inProgress.isNotEmpty) {
              final top = inProgress.first;
              final podcast = top['podcast'] as Podcast;
              final episode = top['episode'] as Episode;
              
              if (episode.audioUrl != null) {
                   final mediaItem = MediaItem(
                        id: episode.guid,
                        album: podcast.title,
                        title: episode.title,
                        artist: '', 
                        artUri: (episode.imageUrl != null || podcast.logoUrl != null) 
                            ? Uri.parse(episode.imageUrl ?? podcast.logoUrl!) 
                            : null,
                        duration: episode.duration,
                        extras: {
                          'url': episode.audioUrl,
                          'podcastUrl': podcast.url,
                          if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
                        },
                   );
                   await _audioHandler.prepareMediaItem(mediaItem);
                   _currentPodcast = podcast;
                   _currentEpisode = episode;
                   // Trigger chapter fetch if we have a URL but no chapters yet
                   if (episode.chaptersUrl != null || episode.audioUrl != null) {
                       _fetchChaptersForCurrent(episode.chaptersUrl);
                   }
                   notifyListeners();
                   return;
              }
          }
      } catch (e) {
          Log.e('PlayerProvider', "Error loading initial in-progress: $e");
      }
  }

  void _syncFromMediaItem(MediaItem item, PodcastProvider provider) {
      if (item.extras?['podcastUrl'] != null) {
         final pUrl = item.extras!['podcastUrl'] as String;
         final podcast = provider.subscriptions.where((p) => p.url == pUrl).firstOrNull 
             ?? Podcast(url: pUrl, title: item.album ?? 'Unknown');
         
         final episode = Episode(
             guid: item.id,
             title: item.title,
             description: '',
             audioUrl: item.extras?['url'],
             imageUrl: item.artUri?.toString(),
             duration: item.duration,
             chaptersUrl: item.extras?['chaptersUrl'],
         );
         
         _currentPodcast = podcast;
         _currentEpisode = episode;
         
         // Restore chapters from extras if available
         if (item.extras?['chapters'] != null) {
             try {
                 final List<dynamic> chaptersJson = item.extras!['chapters'];
                 _currentChapters = chaptersJson.map((c) => Chapter.fromJson(c)).toList();
             } catch (e) {
                 Log.e('PlayerProvider', 'Error parsing chapters from extras: $e');
                 _currentChapters = null;
             }
         } else {
             _currentChapters = null;
             // Trigger fetch if needed
             if (episode.chaptersUrl != null || episode.audioUrl != null) {
                 _fetchChaptersForCurrent(episode.chaptersUrl);
             }
         }
         
         notifyListeners();
      }
  }

  Future<void> play(Podcast podcast, Episode episode, {DownloadProvider? downloadProvider, int? initialPositionSeconds}) async {
    Log.d('PlayerProvider', 'play called for episode: ${episode.title}, current state: ${_player.playing}');
    if (episode.audioUrl == null) return;
    
    final currentId = _audioHandler.mediaItem.value?.id;
    if (currentId == episode.guid) {
         if (!_player.playing) {
             Log.d('PlayerProvider', 'Resuming already loaded episode: ${episode.title}');
             await _audioHandler.play();
             _syncProgress(action: 'play');
         }
         _currentEpisode = episode;
         _currentPodcast = podcast;
         notifyListeners();
         return;
    }

    _currentEpisode = episode;
    _currentPodcast = podcast;
    _currentChapters = null; // Reset chapters for new episode
    
    // Mark as interacted locally when allowed to play
    _podcastProvider?.markEpisodeAsInteracted(podcast.url, episode.guid);
    
    notifyListeners();
    
    // Fetch chapters asynchronously if available (RSS or ID3)
    if (episode.chaptersUrl != null || episode.audioUrl != null) {
      _fetchChaptersForCurrent(episode.chaptersUrl);
    }

    try {
      Duration? initialPosition;
      
      String? localPath;
      if (downloadProvider != null) {
          localPath = await downloadProvider.getDownloadedPath(episode.audioUrl!);
      }

      if (_podcastProvider != null) {
           final action = _podcastProvider!.getLatestAction(episode.guid);
           if (action != null && action.position != null && action.position! > 0) {
                 initialPosition = Duration(seconds: action.position!);
                 Log.d('PlayerProvider', 'Resuming from server position (via PodcastProvider): $initialPosition');
           }
      }

      // Check local queue for position if not found on server or to prefer local state?
      // If we have a local queue item with same ID, it might have more recent saved position (from local playback)
      // than server if sync hasn't happened yet.
      final queueItem = _audioHandler.queue.value.where((i) => i.id == episode.guid).firstOrNull;
      if (queueItem != null && queueItem.extras?['position_seconds'] != null) {
           final localPos = queueItem.extras!['position_seconds'] as int;
           // Use local if we don't have server pos OR if local is ahead?
           // Generally local queue state is trustable for "this device".
           if (initialPosition == null || localPos > initialPosition.inSeconds) {
                initialPosition = Duration(seconds: localPos);
                Log.d('PlayerProvider', 'Resuming from local queue position: $initialPosition');
           }
      }

      if (initialPositionSeconds != null && initialPositionSeconds > 0) {
          initialPosition = Duration(seconds: initialPositionSeconds);
          Log.d('PlayerProvider', 'Resuming from explicit position: $initialPosition');
      }

      final Map<String, dynamic> playExtras = {
        'url': episode.audioUrl,
        if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
      };
      if (_currentChapters != null && _currentChapters!.isNotEmpty) {
        playExtras['chapters'] = _currentChapters!.map((c) => c.toJson()).toList();
      }
      
      final mediaItem = MediaItemBuilder.fromEpisode(
        podcast, 
        episode,
        extras: playExtras,
        duration: episode.duration,
      );

      if (localPath != null) {
          Log.d('PlayerProvider', 'Playing local file: $localPath');
          await _audioHandler.playEpisode(mediaItem, localPath, initialPosition: initialPosition); 
      } else {
          Log.d('PlayerProvider', 'Streaming: ${episode.audioUrl}');
          await _audioHandler.playEpisode(mediaItem, episode.audioUrl!, initialPosition: initialPosition);
      }
      
      _lastSyncTime = DateTime.now();
      _lastSyncedPosition = initialPosition?.inSeconds ?? 0;
      _syncProgress(action: 'play');
      _startLiveActivity();
      
      notifyListeners();
    } catch (e) {
      Log.e('PlayerProvider', 'Error playing audio: $e');
    }
  }

  void togglePlay() {
    if (_player.playing) {
      _audioHandler.pause();
      _syncProgress(action: 'play');
    } else {
      _audioHandler.play();
    }
    notifyListeners();
  }
  
  Future<void> fastForward() => _audioHandler.fastForward();
  Future<void> rewind() => _audioHandler.rewind();
  
  Future<void> addToQueue(Podcast podcast, Episode episode) async {
       if (episode.audioUrl == null) return;
       
       // Fetch saved position from server if available
       int? savedPosition;
       if (_api != null) {
           try {
              final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(seconds: 3));
              final relatedActions = actions.where((a) => a.podcast == podcast.url && a.episode == episode.guid).toList();
              
              if (relatedActions.isNotEmpty) {
                  relatedActions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
                  final latest = relatedActions.first;
                  if (latest.position != null && latest.position! > 0) {
                      savedPosition = latest.position;
                      Log.d('PlayerProvider', 'Found saved position for ${episode.title}: $savedPosition seconds');
                  }
              }
           } catch (e) {
               Log.d('PlayerProvider', 'Could not fetch position for episode (timeout or error): $e');
           }
       }
       
       final Map<String, dynamic> extras = {
           'url': episode.audioUrl,
           'podcastUrl': podcast.url,
           if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
           if (episode.pubDate != null) 'pubDate': episode.pubDate!.toIso8601String(),
       };
       
       // Include saved position if we found one
       if (savedPosition != null) {
           extras['position_seconds'] = savedPosition;
       }
       
       // Include chapters if available
       if (episode.chapters != null && episode.chapters!.isNotEmpty) {
           extras['chapters'] = episode.chapters!.map((c) => c.toJson()).toList();
       }
       
       final mediaItem = MediaItem(
        id: episode.guid,
        album: podcast.title,
        title: episode.title,
        artist: '', 
        artUri: (episode.imageUrl != null || podcast.logoUrl != null) 
            ? Uri.parse(episode.imageUrl ?? podcast.logoUrl!) 
            : null,
        duration: episode.duration,
        extras: extras, 
      );
      await _audioHandler.addQueueItem(mediaItem);
  }

  Future<void> addEpisodesToQueue(List<Map<String, dynamic>> items, {bool playNext = false}) async {
      // Fetch all episode actions once for efficiency
      Map<String, int> positionMap = {};
      if (_api != null) {
          try {
              final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(seconds: 3));
              for (var action in actions) {
                  if (action.position != null && action.position! > 0) {
                      positionMap[action.episode] = action.position!;
                  }
              }
          } catch (e) {
              Log.d('PlayerProvider', 'Could not fetch positions for bulk add (timeout or error): $e');
          }
      }
      
      final mediaItems = items.map((item) {
          final podcast = item['podcast'] as Podcast;
          final episode = item['episode'] as Episode;
          if (episode.audioUrl == null) return null;
          
          final Map<String, dynamic> extras = {
              'url': episode.audioUrl,
              'podcastUrl': podcast.url,
              if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
              if (episode.pubDate != null) 'pubDate': episode.pubDate!.toIso8601String(),
          };
          
          // Include saved position if we found one
          final savedPosition = positionMap[episode.guid];
          if (savedPosition != null) {
              extras['position_seconds'] = savedPosition;
          }
          
          // Include chapters if available
          if (episode.chapters != null && episode.chapters!.isNotEmpty) {
              extras['chapters'] = episode.chapters!.map((c) => c.toJson()).toList();
          }
          
          return MediaItem(
            id: episode.guid,
            album: podcast.title,
            title: episode.title,
            artist: '', 
            artUri: (episode.imageUrl != null || podcast.logoUrl != null) 
                ? Uri.parse(episode.imageUrl ?? podcast.logoUrl!) 
                : null,
            duration: episode.duration,
            extras: extras,
          );
      }).whereType<MediaItem>().toList();
      
      if (mediaItems.isNotEmpty) {
          if (playNext) {
             Log.d('PlayerProvider', 'Adding ${mediaItems.length} items to queue (Play Next)');
             await _audioHandler.insertAfterCurrent(mediaItems);
          } else {
             Log.d('PlayerProvider', 'Adding ${mediaItems.length} items to queue (Bottom)');
             await _audioHandler.addQueueItems(mediaItems);
          }
      }
  }
  
  Future<void> playNextInQueue(Podcast podcast, Episode episode) async {
       if (episode.audioUrl == null) return;
       
       // Fetch saved position from server if available
       int? savedPosition;
       if (_api != null) {
           try {
              final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(seconds: 3));
              final relatedActions = actions.where((a) => a.podcast == podcast.url && a.episode == episode.guid).toList();
              
              if (relatedActions.isNotEmpty) {
                  relatedActions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
                  final latest = relatedActions.first;
                  if (latest.position != null && latest.position! > 0) {
                      savedPosition = latest.position;
                  }
              }
           } catch (e) {
               Log.d('PlayerProvider', 'Could not fetch position for episode (timeout or error): $e');
           }
       }
       
       final Map<String, dynamic> extras = {
           'url': episode.audioUrl,
           'podcastUrl': podcast.url,
           if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
           if (episode.pubDate != null) 'pubDate': episode.pubDate!.toIso8601String(),
       };
       
       // Include saved position if we found one
       if (savedPosition != null) {
           extras['position_seconds'] = savedPosition;
       }
       
       // Include chapters if available
       if (episode.chapters != null && episode.chapters!.isNotEmpty) {
           extras['chapters'] = episode.chapters!.map((c) => c.toJson()).toList();
       }
       
       final mediaItem = MediaItem(
        id: episode.guid,
        album: podcast.title,
        title: episode.title,
        artist: '', 
        artUri: (episode.imageUrl != null || podcast.logoUrl != null) 
            ? Uri.parse(episode.imageUrl ?? podcast.logoUrl!) 
            : null,
        duration: episode.duration,
        extras: extras, 
      );
      await _audioHandler.playNext(mediaItem);
  }

  Future<void> removeFromQueue(MediaItem item) async {
      await _audioHandler.removeQueueItem(item);
  }
  
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
      await _audioHandler.reorderQueue(oldIndex, newIndex);
  }
  
  Future<void> skipToQueueItem(int index) async {
      await _audioHandler.skipToQueueItem(index);
  }

  Future<void> playMediaItem(MediaItem item) async {
      Log.d('PlayerProvider', 'playMediaItem called for ${item.title}');
      
      // Ensure we have an API instance before proceeding
      if (_api == null && _podcastProvider != null) {
          Log.d('PlayerProvider', '_api is null, trying to create from PodcastProvider...');
          _api = _podcastProvider!.api; // Store it if possible, or just use accessor
          if (_api != null) {
             Log.d('PlayerProvider', 'Successfully set _api from PodcastProvider');
          }
      }

      Log.d('PlayerProvider', '_api is ${_api == null ? "NULL" : "set"}, position_seconds in extras: ${item.extras?['position_seconds']}');
      
      // Sync progress of currently playing/paused episode before switching
      // FIRE AND FORGET: Do not await this, so we don't block the UI/switching
      if (_currentEpisode != null && _player.position.inSeconds > 0) {
          Log.d('PlayerProvider', 'Triggering background sync before switching episodes');
          // We call the internal _syncProgress directly without await or forceSync wrapper to be sure
          _syncProgress(action: 'play').then((_) {
               Log.d('PlayerProvider', 'Background sync completed');
          }).catchError((e) {
               Log.e('PlayerProvider', 'Background sync failed: $e');
          });
      }
      
      // Update current episode/podcast info for UI display (mini player)
      _updateCurrentFromMediaItem(item);
      
      // Check if position_seconds is available in extras (preferred/fastest)
      if (item.extras?['position_seconds'] != null) {
           Log.d('PlayerProvider', 'playMediaItem - playing immediately with saved position from extras');
           await _audioHandler.playMediaItem(item);
           return;
      }
      
      // If missing and we have API, try to fetch briefly, but don't block too long
      if (_api != null) {
          Log.d('PlayerProvider', 'playMediaItem - position missing, attempting quick fetch...');
          try {
              // Reduced timeout to 1 second to avoid "doesn't play" feeling
              // Usage of future here to allow falling through if it takes too long? 
              // Actually, simpler to just await with short timeout.
              final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(milliseconds: 1000));
              final relatedActions = actions.where((a) => a.episode == item.id).toList();
              
              if (relatedActions.isNotEmpty) {
                  relatedActions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
                  final latest = relatedActions.first;
                  if (latest.position != null && latest.position! > 0) {
                      Log.d('PlayerProvider', 'Found position ${latest.position} seconds for ${item.title}');
                      // Update the item with the position
                      final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                      newExtras['position_seconds'] = latest.position!;
                      final updatedItem = item.copyWith(extras: newExtras);
                      
                      await _audioHandler.playMediaItem(updatedItem);
                      return;
                  }
              }
          } catch (e) {
              Log.e('PlayerProvider', 'fetch position timed out or failed, playing from start: $e');
              // Proceed to play as-is (from start)
          }
      }
      
      // Fallback: Play as-is (from 0 or whatever defaults)
      await _audioHandler.playMediaItem(item);
  }
  
  /// Helper to update current episode/podcast from MediaItem for UI display
  void _updateCurrentFromMediaItem(MediaItem item) {
      // Try to find the podcast from podcastUrl in extras
      if (item.extras?['podcastUrl'] != null && _podcastProvider != null) {
          final podcastUrl = item.extras!['podcastUrl'] as String;
          final podcast = _podcastProvider!.subscriptions
              .where((p) => p.url == podcastUrl)
              .firstOrNull ?? Podcast(url: podcastUrl, title: item.album ?? 'Unknown');
          
          final episode = Episode(
              guid: item.id,
              title: item.title,
              description: '',
              audioUrl: item.extras?['url'],
              imageUrl: item.artUri?.toString(),
              duration: item.duration,
          );
          
          _currentPodcast = podcast;
          _currentEpisode = episode;
          
          if (_currentChapters == null || _currentChapters!.isEmpty) {
              if (item.extras?['chaptersUrl'] != null || episode.audioUrl != null) {
                  _fetchChaptersForCurrent(item.extras?['chaptersUrl']);
              }
          }
          notifyListeners();
      }
  }
  
  Future<void> clearQueue() async {
      await _audioHandler.updateQueue([]);
  }
  
  Future<void> markAsListened(MediaItem item) async {
      await removeFromQueue(item);

      if (_api == null) return;
      
      final podcastUrl = item.extras?['podcastUrl'] ?? ''; 
      if (podcastUrl.isEmpty) {
          return;
      }
      
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final duration = item.duration?.inSeconds ?? 0;
      
      final episodeAction = EpisodeAction(
        podcast: podcastUrl,
        episode: item.id, 
        guid: item.id,
        action: 'play',
        timestamp: now,
        position: duration > 0 ? duration : 1, 
        started: 0,
        total: duration > 0 ? duration : 1,
        device: _deviceId,
      );

      try {
        await _api!.uploadEpisodeActions([episodeAction]);
      } catch (e) {
        Log.e('PlayerProvider', 'Failed to sync marked-as-listened: $e');
      }
  }

  void _fetchChaptersForCurrent(String? chaptersUrl) {
    if (chaptersUrl != null) {
        final duration = _settings?.feedCacheDuration ?? 24;
        ChapterService().fetchChapters(chaptersUrl, cacheDurationHours: duration).then((chapters) => _handleChaptersLoaded(chapters, chaptersUrl));
    } else if (_currentEpisode?.audioUrl != null) {
        // Fallback to ID3 tags
        Log.d('PlayerProvider', 'No chaptersUrl, attempting ID3 tag extraction...');
        ID3ChapterService().extractID3Chapters(_currentEpisode!.audioUrl!).then((chapters) => _handleChaptersLoaded(chapters, null));
    }
  }

  void _handleChaptersLoaded(List<Chapter> chapters, String? originalChaptersUrl) {
      if (chapters.isNotEmpty) {
        // If we fetched via ID3, originalChaptersUrl is null, so we just check if we are still on the same episode
        // For RSS, we check if the URL matches.
        bool isRelevant = false;
        if (originalChaptersUrl != null) {
            isRelevant = _currentEpisode?.chaptersUrl == originalChaptersUrl;
        } else {
            // ID3 match check - is the current episode's audio URL what we just parsed?
            // This is a bit loose, theoretically we should pass the audioUrl back.
            // Simplified: if current episode has no chaptersUrl, we assume this ID3 result is for it.
            isRelevant = _currentEpisode?.chaptersUrl == null; 
        }

        if (isRelevant) {
            _currentChapters = chapters;
            notifyListeners();
            
            // Update AudioHandler with new chapters
            final currentItem = _audioHandler.mediaItem.value;
            if (currentItem != null && currentItem.id == _currentEpisode?.guid) {
                final newExtras = Map<String, dynamic>.from(currentItem.extras ?? {});
                newExtras['chapters'] = chapters.map((c) => c.toJson()).toList();
                
                final updatedItem = currentItem.copyWith(extras: newExtras);
                _audioHandler.updateMediaItem(updatedItem);
            }
        }
      }
  }


    // Expose API setter or use PodcastProvider
    GPodderApi? get api => _api ?? _podcastProvider?.api;
    
    Future<void> _syncProgress({required String action}) async {
        final apiToUse = api;
        if (apiToUse == null || _currentPodcast == null || _currentEpisode == null) {
            return;
        }

        // B5: Debounce non-stop actions to avoid excessive server uploads
        if (action != 'stop' && DateTime.now().difference(_lastUploadTime).inSeconds < 30) return;

        final position = _player.position.inSeconds;
        final duration = _player.duration?.inSeconds ?? 0;
        
        final episodeId = _currentEpisode!.guid;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        // Update Queue Item with new position and duration
        final currentQueue = _audioHandler.queue.value;
        var index = currentQueue.indexWhere((item) => item.id == episodeId);
    
    // Fallback: Try finding by URL if ID lookup fails
    if (index == -1 && _currentEpisode!.audioUrl != null) {
        index = currentQueue.indexWhere((item) => item.extras?['url'] == _currentEpisode!.audioUrl);
    }
    
    if (index != -1) {
        final item = currentQueue[index];
        final newExtras = Map<String, dynamic>.from(item.extras ?? {});
        newExtras['position_seconds'] = position;
        
        // Update duration if we have a valid one from player
        final newDuration = _player.duration ?? item.duration;

        final newItem = item.copyWith(
            extras: newExtras,
            duration: newDuration,
        );
        
        _audioHandler.updateQueue(
            List<MediaItem>.from(currentQueue)..[index] = newItem
        );
        // B9: Removed notifyListeners here — position display uses StreamBuilder,
        // and queue persistence is handled by updateQueue. Calling notifyListeners
        // here caused full widget tree rebuilds every 30s during playback.
    }

    final episodeAction = EpisodeAction(
      podcast: _currentPodcast!.url,
      episode: episodeId,
      guid: _currentEpisode!.guid,
      action: action,
      timestamp: now,
      position: position,
      started: _lastSyncedPosition ?? position, 
      total: duration,
      device: _deviceId,
    );

    _lastSyncedPosition = position;

    try {
          if (_podcastProvider != null) {
              await _podcastProvider!.sendEpisodeAction(episodeAction);
          } else if (apiToUse != null) {
              await apiToUse.uploadEpisodeActions([episodeAction]);
          }
          _lastUploadTime = DateTime.now(); // B5: Update debounce timestamp
          Log.d('PlayerProvider', 'Successfully synced action via PodcastProvider');
    } catch (e) {
      Log.e('PlayerProvider', 'Failed to sync progress: $e');
    }
  }
  
  double get speed => _audioHandler.currentSpeed;
  
  Future<void> setSpeed(double speed) async {
      await _audioHandler.setSpeed(speed);
      notifyListeners();
  }
  
  Future<void> cycleSpeed() async {
      await _audioHandler.cycleSpeed();
      notifyListeners();
  }
  
  bool get skipSilenceEnabled => _audioHandler.skipSilenceEnabled;
  
  Future<void> toggleSkipSilence() async {
      await _audioHandler.setSkipSilenceEnabled(!skipSilenceEnabled);
      notifyListeners();
  }
  
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;
  
  bool get isSleepTimerActive => _sleepTimer != null && _sleepTimer!.isActive;
  DateTime? get sleepTimerEndTime => _sleepTimerEndTime;
  
  void setSleepTimer(Duration duration) {
      _sleepTimer?.cancel();
      _sleepTimerEndTime = DateTime.now().add(duration);
      
      _sleepTimer = Timer(duration, () {
          _audioHandler.pause();
          _sleepTimer = null;
          _sleepTimerEndTime = null;
          notifyListeners();
      });
      notifyListeners();
  }
  
  void cancelSleepTimer() {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepTimerEndTime = null;
      notifyListeners();
  }

  // ── Live Activity Helpers ──
  
  void _startLiveActivity() {
      if (!Platform.isIOS || _liveActivityService == null) return;
      final ep = _currentEpisode;
      final pod = _currentPodcast;
      if (ep == null) return;
      
      _liveActivityService!.startActivity(
          episodeTitle: ep.title,
          podcastName: pod?.title ?? '',
          artUrl: ep.imageUrl ?? pod?.logoUrl,
          isPlaying: _player.playing,
          positionSeconds: _player.position.inSeconds,
          durationSeconds: ep.duration?.inSeconds ?? 0,
      );
  }
  
  void _updateLiveActivity() {
      if (!Platform.isIOS || _liveActivityService == null) return;
      final ep = _currentEpisode;
      final pod = _currentPodcast;
      if (ep == null) return;
      
      final state = _audioHandler.playbackState.value;
      
      // End activity if stopped/completed with no next item
      if (state.processingState == AudioProcessingState.idle ||
          state.processingState == AudioProcessingState.completed) {
          _liveActivityService!.endActivity();
          return;
      }
      
      _liveActivityService!.updateActivity(
          episodeTitle: ep.title,
          podcastName: pod?.title ?? '',
          artUrl: ep.imageUrl ?? pod?.logoUrl,
          isPlaying: state.playing,
          positionSeconds: _player.position.inSeconds,
          durationSeconds: ep.duration?.inSeconds ?? _player.duration?.inSeconds ?? 0,
      );
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _liveActivityService?.dispose();
    super.dispose();
  }
}
