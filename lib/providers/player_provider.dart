import 'package:flutter/material.dart';
import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import '../models/podcast.dart';
import '../api/gpodder_api.dart';
import 'download_provider.dart';
import '../services/audio_handler.dart';
import 'podcast_provider.dart';
import 'settings_provider.dart';
import '../services/watch_service.dart';

class PlayerProvider with ChangeNotifier {
  final PodcastAudioHandler _audioHandler;
  
  // Expose internal player for legacy compat if needed, or better, rely on handler
  // For now, we use internalPlayer to minimize breaking changes in logic below
  AudioPlayer get _player => _audioHandler.internalPlayer;

  Episode? _currentEpisode;
  Podcast? _currentPodcast;

  Episode? get currentEpisode => _currentEpisode;
  Podcast? get currentPodcast => _currentPodcast;
  
  // Expose player getter if consumers need it, though they should ideally go through provider/handler
  AudioPlayer get player => _player; 
  bool get isPlaying => _player.playing;
  
  // Expose queue
  Stream<List<MediaItem>> get queueStream => _audioHandler.queue;
  List<MediaItem> get queue => _audioHandler.queue.value;
  
  DateTime _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(0);
  SettingsProvider? _settings;

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
  
  void updateDownloadProvider(DownloadProvider provider) {
      _downloadProvider = provider;
  }
  
  void setWatchService(WatchService service) {
      _watchService = service;
      // Start listening for commands from watch
      _watchService!.listenForCommands(_audioHandler);
      _watchService!.setCustomCommandHandler((command, args) {
          final episodeId = args['episodeId'] as String?;
          if (episodeId == null) return;
          
          if (command == 'remove_from_queue') {
              final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
              if (item != null) removeFromQueue(item);
          } else if (command == 'mark_as_played') {
              final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
              if (item != null) markAsListened(item);
          }
      });
  }
  
  void _checkWatchSync() {
      if (_watchService != null && _downloadProvider != null && _settings != null) {
          _watchService!.syncQueue(
              queue: _audioHandler.queue.value,
              downloadProvider: _downloadProvider!,
              settings: _settings!,
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
  

  static String formatProgress({
    required Duration position,
    required Duration duration,
    required bool showPercentListened,
  }) {
    int percent = 0;
    if (showPercentListened) {
      if (duration.inSeconds > 0) {
        percent = (position.inSeconds / duration.inSeconds * 100).clamp(0, 100).toInt();
      }
      return '$percent% listened';
    } else {
      if (duration.inSeconds > 0) {
        final left = duration.inSeconds - position.inSeconds;
        percent = (left / duration.inSeconds * 100).clamp(0, 100).toInt();
      }
      return '$percent% left';
    }
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

        _syncWatchPlaybackState(); // Sync to Watch
        notifyListeners();
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
       
       print('PlayerProvider: Marking ${episode.title} as played (syncing duration: $duration)');
       
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

       try {
         await _api!.uploadEpisodeActions([episodeAction]);
       } catch (e) {
         print('Failed to sync marked-as-listened: $e');
       }
       
       // Mark as interacted locally
       if (_currentPodcast != null) {
          _podcastProvider?.markEpisodeAsInteracted(_currentPodcast!.url, episode.guid);
       }
  }

  Future<void> forceSync({String action = 'play'}) async {
      print('Forcing sync with action: $action');
      await _syncProgress(action: action);
  }

  GPodderApi? _api;
  String _deviceId = 'flutter-client'; // Default or injected

  void setApi(GPodderApi api, String deviceId) {
    print('PlayerProvider: setApi called with deviceId: $deviceId');
    _api = api;
    _deviceId = deviceId;
    // Enrich queue with positions now that we have API access
    print('PlayerProvider: Calling enrichQueueWithPositions...');
    enrichQueueWithPositions();
  }

  Future<void> loadInitialState(PodcastProvider podcastProvider) async {
      await _evaluateFallbackState(podcastProvider);
      // Note: enrichQueueWithPositions() is called in setApi() when API is ready
  }

  /// Updates existing queue items with their saved playback positions from the server
  Future<void> enrichQueueWithPositions() async {
      if (_api == null || queue.isEmpty) return;
      
      try {
          print('PlayerProvider: Enriching queue with saved positions...');
          // Fetch all episode actions
          final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(seconds: 3));
          
          // Build a map of episode guid -> position
          final Map<String, int> positionMap = {};
          for (var action in actions) {
              if (action.position != null && action.position! > 0) {
                  positionMap[action.episode] = action.position!;
              }
          }
          
          // Update queue items
          bool hasUpdates = false;
          final updatedQueue = queue.map((item) {
              final savedPosition = positionMap[item.id];
              
              // Only update if we found a position and it's not already set
              if (savedPosition != null && item.extras?['position_seconds'] == null) {
                  hasUpdates = true;
                  final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                  newExtras['position_seconds'] = savedPosition;
                  print('PlayerProvider: Enriched ${item.title} with position: $savedPosition seconds');
                  return item.copyWith(extras: newExtras);
              }
              
              return item;
          }).toList();
          
          if (hasUpdates) {
              await _audioHandler.updateQueue(updatedQueue);
              print('PlayerProvider: Queue enrichment complete');
          }
      } catch (e) {
          print('PlayerProvider: Could not enrich queue with positions: $e');
      }
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
                        extras: {'url': episode.audioUrl, 'podcastUrl': podcast.url},
                   );
                   await _audioHandler.prepareMediaItem(mediaItem);
                   _currentPodcast = podcast;
                   _currentEpisode = episode;
                   notifyListeners();
                   return;
              }
          }
      } catch (e) {
          print("Error loading initial in-progress: $e");
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
         );
         
         _currentPodcast = podcast;
         _currentEpisode = episode;
         notifyListeners();
      }
  }

  Future<void> play(Podcast podcast, Episode episode, {DownloadProvider? downloadProvider, int? initialPositionSeconds}) async {
    print('PlayerProvider.play called for episode: ${episode.title}, current state: ${_player.playing}');
    if (episode.audioUrl == null) return;
    
    final currentId = _audioHandler.mediaItem.value?.id;
    if (currentId == episode.guid) {
         if (!_player.playing) {
             print('Resuming already loaded episode: ${episode.title}');
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
    
    // Mark as interacted locally when allowed to play
    _podcastProvider?.markEpisodeAsInteracted(podcast.url, episode.guid);
    
    notifyListeners();

    try {
      Duration? initialPosition;
      
      String? localPath;
      if (downloadProvider != null) {
          localPath = await downloadProvider.getDownloadedPath(episode.audioUrl!);
      }

      if (_api != null) {
          try {
             final actions = await _api!.getEpisodeActions(_deviceId).timeout(const Duration(seconds: 5));
             
             final targetId = episode.guid; 
             final relatedActions = actions.where((a) => a.podcast == podcast.url && a.episode == targetId).toList();
             
             if (relatedActions.isNotEmpty) {
                 relatedActions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
                 final latest = relatedActions.first;
                 if (latest.position != null && latest.position! > 0) {
                     initialPosition = Duration(seconds: latest.position!);
                     print('Resuming from server position: $initialPosition');
                 }
             }
          } catch (e) {
              print('Pre-play sync skipped (timeout or error): $e');
          }
      }

      if (initialPositionSeconds != null && initialPositionSeconds > 0) {
          initialPosition = Duration(seconds: initialPositionSeconds);
          print('Resuming from explicit position: $initialPosition');
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
        extras: {'url': episode.audioUrl},
      );

      if (localPath != null) {
          print('Playing local file: $localPath');
          await _audioHandler.playEpisode(mediaItem, localPath, initialPosition: initialPosition); 
      } else {
          print('Streaming: ${episode.audioUrl}');
          await _audioHandler.playEpisode(mediaItem, episode.audioUrl!, initialPosition: initialPosition);
      }
      
      _lastSyncTime = DateTime.now();
      _syncProgress(action: 'play');
      
      notifyListeners();
    } catch (e) {
      debugPrint('Error playing audio: $e');
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
                      print('Found saved position for ${episode.title}: $savedPosition seconds');
                  }
              }
           } catch (e) {
               print('Could not fetch position for episode (timeout or error): $e');
           }
       }
       
       final Map<String, dynamic> extras = {
           'url': episode.audioUrl,
           'podcastUrl': podcast.url,
       };
       
       // Include saved position if we found one
       if (savedPosition != null) {
           extras['position_seconds'] = savedPosition;
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

  Future<void> addEpisodesToQueue(List<Map<String, dynamic>> items) async {
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
              print('Could not fetch positions for bulk add (timeout or error): $e');
          }
      }
      
      final mediaItems = items.map((item) {
          final podcast = item['podcast'] as Podcast;
          final episode = item['episode'] as Episode;
          if (episode.audioUrl == null) return null;
          
          final Map<String, dynamic> extras = {
              'url': episode.audioUrl,
              'podcastUrl': podcast.url,
          };
          
          // Include saved position if we found one
          final savedPosition = positionMap[episode.guid];
          if (savedPosition != null) {
              extras['position_seconds'] = savedPosition;
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
          await _audioHandler.addQueueItems(mediaItems);
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
               print('Could not fetch position for episode (timeout or error): $e');
           }
       }
       
       final Map<String, dynamic> extras = {
           'url': episode.audioUrl,
           'podcastUrl': podcast.url,
       };
       
       // Include saved position if we found one
       if (savedPosition != null) {
           extras['position_seconds'] = savedPosition;
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
      print('PlayerProvider: playMediaItem called for ${item.title}');
      
      // Ensure we have an API instance before proceeding
      if (_api == null && _podcastProvider != null) {
          print('PlayerProvider: _api is null, trying to create from PodcastProvider...');
          _api = _podcastProvider!.api; // Store it if possible, or just use accessor
          if (_api != null) {
             print('PlayerProvider: Successfully set _api from PodcastProvider');
          }
      }

      print('PlayerProvider: _api is ${_api == null ? "NULL" : "set"}, position_seconds in extras: ${item.extras?['position_seconds']}');
      
      // Sync progress of currently playing/paused episode before switching
      // FIRE AND FORGET: Do not await this, so we don't block the UI/switching
      if (_currentEpisode != null && _player.position.inSeconds > 0) {
          print('PlayerProvider: Triggering background sync before switching episodes');
          // We call the internal _syncProgress directly without await or forceSync wrapper to be sure
          _syncProgress(action: 'play').then((_) {
               print('PlayerProvider: Background sync completed');
          }).catchError((e) {
               print('PlayerProvider: Background sync failed: $e');
          });
      }
      
      // Update current episode/podcast info for UI display (mini player)
      _updateCurrentFromMediaItem(item);
      
      // Check if position_seconds is available in extras (preferred/fastest)
      if (item.extras?['position_seconds'] != null) {
           print('PlayerProvider: playMediaItem - playing immediately with saved position from extras');
           await _audioHandler.playMediaItem(item);
           return;
      }
      
      // If missing and we have API, try to fetch briefly, but don't block too long
      if (_api != null) {
          print('PlayerProvider: playMediaItem - position missing, attempting quick fetch...');
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
                      print('PlayerProvider: Found position ${latest.position} seconds for ${item.title}');
                      // Update the item with the position
                      final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                      newExtras['position_seconds'] = latest.position!;
                      final updatedItem = item.copyWith(extras: newExtras);
                      
                      await _audioHandler.playMediaItem(updatedItem);
                      return;
                  }
              }
          } catch (e) {
              print('PlayerProvider: fetch position timed out or failed, playing from start: $e');
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
        
        // Mark as interacted locally
        _podcastProvider?.markEpisodeAsInteracted(podcastUrl, item.id);
      } catch (e) {
        print('Failed to sync marked-as-listened: $e');
      }
  }

    // Expose API setter or use PodcastProvider
    GPodderApi? get api => _api ?? _podcastProvider?.api;
    
    Future<void> _syncProgress({required String action}) async {
        final apiToUse = api;
        if (apiToUse == null || _currentPodcast == null || _currentEpisode == null) {
            return;
        }

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
        notifyListeners(); // Force UI rebuild just in case
    }

    final episodeAction = EpisodeAction(
      podcast: _currentPodcast!.url,
      episode: episodeId,
      guid: _currentEpisode!.guid,
      action: action,
      timestamp: now,
      position: position,
      started: position, 
      total: duration,
      device: _deviceId,
    );

    try {
      if (apiToUse != null) {
          await apiToUse.uploadEpisodeActions([episodeAction]);
          print('PlayerProvider: Successfully uploaded action to server');
      } else {
           print('PlayerProvider: Cannot upload action, API is null');
      }
    } catch (e) {
      print('Failed to sync progress: $e');
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

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }
}
