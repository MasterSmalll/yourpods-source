import 'package:flutter/material.dart';
import '../utils/safe_int.dart';
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
import '../models/sync_conflict.dart';
import '../models/queue_sync_change.dart';
import '../services/queue_sync_service.dart';

/// Result from syncPlaybackState containing both episode conflicts and queue sync changes.
class SyncResult {
  final List<SyncConflict> conflicts;
  final List<QueueSyncChange> queueChanges;

  SyncResult({required this.conflicts, required this.queueChanges});
  
  factory SyncResult.empty() => SyncResult(conflicts: [], queueChanges: []);
  
  bool get hasConflicts => conflicts.isNotEmpty;
  bool get hasQueueChanges => queueChanges.isNotEmpty;
  bool get isEmpty => !hasConflicts && !hasQueueChanges;
}

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

  /// Stream of user-visible error messages from the audio handler
  /// (e.g. network failures during auto-advance or stream recovery).
  Stream<String> get playbackErrorStream => _audioHandler.playbackError;

  /// Retry the last failed auto-advance (called from Retry SnackBar).
  Future<void> retryPlayback() => _audioHandler.retryLastAutoAdvance();
  
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
    
    // Re-sync _currentPodcast from subscriptions if we have a mediaItem
    // but _currentPodcast has incomplete data (e.g., on cold start,
    // _syncFromMediaItem built a fallback Podcast from item.album before
    // subscriptions loaded — now that subs are available, upgrade to full data).
    final current = _audioHandler.mediaItem.value;
    if (current != null && provider.subscriptions.isNotEmpty) {
        final pUrl = current.extras?['podcastUrl'] as String?;
        if (pUrl != null) {
            final sub = provider.subscriptions.where((p) => p.url == pUrl).firstOrNull;
            if (sub != null && (_currentPodcast == null || _currentPodcast!.logoUrl == null)) {
                _currentPodcast = sub;
                notifyListeners();
            }
        }
    }
  }
  
  DownloadProvider? _downloadProvider;
  WatchService? _watchService;
  LiveActivityService? _liveActivityService;
  
  void updateDownloadProvider(DownloadProvider provider) {
      if (_downloadProvider != provider) {
          _downloadProvider?.removeListener(_onDownloadProviderChanged);
          _downloadProvider = provider;
          _downloadProvider!.addListener(_onDownloadProviderChanged);
      }
  }

  /// React to download state changes. When the currently playing episode
  /// finishes downloading, seamlessly swap from the network stream to the
  /// local file to save battery and data.
  void _onDownloadProviderChanged() {
    if (_currentEpisode == null || _downloadProvider == null) return;
    final url = _currentEpisode!.audioUrl;
    if (url == null) return;

    final status = _downloadProvider!.getStatus(url);
    if (status == DownloadState.downloaded) {
      // Check if we're currently streaming (not already playing a local file)
      final currentUrl = _audioHandler.mediaItem.value?.extras?['url'] as String?;
      if (currentUrl != null && !currentUrl.startsWith('/')) {
        _swapToLocalFile(url);
      }
    }
  }

  /// Swap the currently streaming episode to its newly downloaded local file.
  Future<void> _swapToLocalFile(String url) async {
    try {
      final localPath = await _downloadProvider!.getDownloadedPath(url);
      if (localPath == null) return;

      final wasPlaying = _player.playing;
      final position = _player.position;

      Log.i('PlayerProvider', 'Swapping stream → local file at ${position.inSeconds}s');

      // Update the media item extras to reflect the local path
      final current = _audioHandler.mediaItem.value;
      if (current != null) {
        final newExtras = Map<String, dynamic>.from(current.extras ?? {});
        newExtras['url'] = localPath;
        final updated = current.copyWith(extras: newExtras);
        _audioHandler.mediaItem.add(updated);
      }

      // Reload the player with the local file at the same position
      await _audioHandler.playEpisode(
        _audioHandler.mediaItem.value!,
        localPath,
        initialPosition: position,
        autoPlay: wasPlaying,
      );
    } catch (e) {
      Log.e('PlayerProvider', 'Stream→local swap failed (non-fatal): $e');
    }
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
      if (_podcastProvider != null) {
          _watchService!.setPodcastProvider(_podcastProvider!);
      }
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
                  final item = _audioHandler.queue.value.where((i) => i.id == episodeId).firstOrNull;
                  if (item != null) {
                       final podcastUrl = item.extras?['podcastUrl'] as String?;
                       if (podcastUrl != null) {
                           Log.d('PlayerProvider', 'Syncing watch progress for $episodeId: $position');
                           final audioUrl = item.extras?['url'] as String?;
                           final action = EpisodeAction(
                               podcast: podcastUrl,
                               episode: audioUrl ?? episodeId,
                               guid: episodeId,
                               action: 'play',
                               timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                               position: position,
                               started: 0,
                               total: item.duration?.inSeconds ?? 0,
                               device: 'apple-watch',
                           );
                           _podcastProvider!.sendEpisodeAction(action);
                       }
                  }
              }
          } else if (command == 'request_library') {
              _syncWatchLibrary();
          } else if (command == 'request_episodes') {
              final feedUrl = args['feedUrl'] as String?;
              if (feedUrl != null) {
                  _sendEpisodesToWatch(feedUrl);
              }
          } else if (command == 'refresh_queue') {
              _checkWatchSync();
          }
      });
      
      // Trigger initial sync so the watch gets the current queue immediately
      _checkWatchSync();
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

  void _syncWatchLibrary() {
      if (_watchService != null && _podcastProvider != null) {
          _watchService!.syncLibrary(_podcastProvider!.subscriptions);
      }
  }

  Future<void> _sendEpisodesToWatch(String feedUrl) async {
      if (_watchService == null || _podcastProvider == null) return;

      try {
          final episodes = await _podcastProvider!.getEpisodes(feedUrl);
          // Send top 3 episodes initially, watch can request more
          final topEpisodes = episodes.take(3).map((e) => {
              'guid': e.guid,
              'title': e.title,
              'audioUrl': e.audioUrl,
              'duration': e.duration?.inSeconds ?? 0,
              'imageUrl': e.imageUrl,
              'pubDate': e.pubDate?.toIso8601String(),
          }).toList();

          await _watchService!.sendEpisodesToWatch(feedUrl, topEpisodes);
      } catch (e) {
          Log.e('PlayerProvider', 'Failed to send episodes to watch for $feedUrl: $e');
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
             // Don't compete for bandwidth during error recovery
             final ps = _audioHandler.playbackState.value.processingState;
             if (ps != AudioProcessingState.error) {
               _syncProgress(action: 'play');
             }
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
         episode: episode.audioUrl ?? episode.guid, 
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
      // Force-save to disk first (survives force-quit)
      await _audioHandler.forceSaveState();
      // Then sync to server, bypassing the 30s debounce
      await _syncProgress(action: action, bypassDebounce: true);
  }

  /// Force-save current queue and playback position to disk immediately.
  /// Called from lifecycle handlers to ensure no data is lost on force-quit.
  Future<void> forceSaveState() async {
      await _audioHandler.forceSaveState();
  }

  GPodderApi? _api;
  String _deviceId = 'flutter-client'; // Default or injected

  void setApi(GPodderApi? api, String deviceId, {String? profileId}) async {
    Log.d('PlayerProvider', 'setApi called with deviceId: $deviceId, profileId: $profileId');
    _api = api;
    _deviceId = deviceId;
    
    // Set profile ID on audio handler for profile-scoped queue storage.
    // MUST await so _loadLastState finishes and mediaItem is populated
    // before we proceed — otherwise the state clear below wipes the
    // just-restored episode.
    if (profileId != null) {
        await _audioHandler.setProfileId(profileId);
        // Don't clear _currentEpisode here — _syncFromMediaItem from the
        // mediaItem listener will populate it from the restored state.
        // Clearing it causes a race: the mini player briefly shows nothing,
        // and the queue listener re-enters _evaluateFallbackState with
        // _currentEpisode == null, potentially loading the wrong episode.
    }
    
    // Timestamp loading handled in PodcastProvider now.
    // Fire-and-forget: don't block startup/playback waiting for server sync.
    // The sync enriches queue positions and resolves conflicts, but playback
    // must be available immediately.
    syncPlaybackState().catchError((e) {
        Log.e('PlayerProvider', 'Background syncPlaybackState failed: $e');
    });
  }

  Future<void> loadInitialState(PodcastProvider podcastProvider) async {
      await _evaluateFallbackState(podcastProvider);
      // Drain any episodes queued by background refresh or previous sessions
      await drainPendingAutoQueue();
      // Note: enrichQueueWithPositions() is called in setApi() when API is ready
  }

  /// Drain the pending auto-queue buffer and add episodes to the player queue.
  /// Safe to call multiple times — clears the buffer after processing.
  Future<int> drainPendingAutoQueue() async {
      if (_podcastProvider == null) return 0;
      
      final pending = await _podcastProvider!.loadPendingAutoQueue();
      if (pending.isEmpty) return 0;
      
      Log.i('PlayerProvider', 'Draining ${pending.length} pending auto-queue episodes');
      
      final priorityItems = <Map<String, dynamic>>[];
      final standardItems = <Map<String, dynamic>>[];
      
      for (var item in pending) {
          final audioUrl = item['audioUrl'] as String?;
          if (audioUrl == null) continue;
          
          // Skip if already in queue
          final guid = item['guid'] as String;
          if (queue.any((q) => q.id == guid)) {
              Log.d('PlayerProvider', 'Skipping pending episode $guid — already in queue');
              continue;
          }
          
          final podcast = Podcast(
              url: item['podcastUrl'] as String? ?? '',
              title: item['podcastTitle'] as String? ?? 'Unknown',
              logoUrl: item['podcastLogoUrl'] as String?,
          );
          final episode = Episode(
              guid: guid,
              title: item['title'] as String? ?? '',
              description: '',
              audioUrl: audioUrl,
              imageUrl: item['imageUrl'] as String?,
              duration: item['duration'] != null 
                  ? Duration(seconds: item['duration'] as int) 
                  : null,
              pubDate: item['pubDate'] != null 
                  ? DateTime.tryParse(item['pubDate'] as String) 
                  : null,
              chaptersUrl: item['chaptersUrl'] as String?,
              transcriptUrl: item['transcriptUrl'] as String?,
          );
          
          final episodeMap = {'podcast': podcast, 'episode': episode};
          
          if (item['priority'] == true) {
              priorityItems.add(episodeMap);
          } else {
              standardItems.add(episodeMap);
          }
      }
      
      final totalAdded = priorityItems.length + standardItems.length;
      
      if (priorityItems.isNotEmpty) {
          await addEpisodesToQueue(priorityItems, playNext: true);
      }
      if (standardItems.isNotEmpty) {
          await addEpisodesToQueue(standardItems, playNext: false);
      }
      
      // Clear the buffer now that we've processed everything
      await _podcastProvider!.clearPendingAutoQueue();
      
      if (totalAdded > 0) {
          Log.i('PlayerProvider', 'Auto-queued $totalAdded episodes '
              '(${priorityItems.length} priority, ${standardItems.length} standard)');
      }
      
      return totalAdded;
  }

  /// Syncs playback state (Episode Actions) from the server.
  /// Delegates to PodcastProvider.
  /// Returns a SyncResult with conflicts and queue sync changes.
  Future<SyncResult> syncPlaybackState({bool force = true}) async {
      // Deduplicate queue — remove episodes with duplicate GUIDs,
      // keeping the first occurrence (which has the most recent position).
      // Runs regardless of whether server sync is available.
      await _deduplicateQueue();

      if (_podcastProvider == null) return SyncResult.empty();
      
      // Server sync requires an API connection; skip for local profiles
      List<SyncConflict> conflicts = [];
      if (_api != null) {
          Log.d('PlayerProvider', 'Delegating playback sync to PodcastProvider...');
          
          final strategy = _settings?.syncConflictStrategy ?? SyncStrategy.serverWins;
          conflicts = await _podcastProvider!.syncEpisodeActions(_deviceId, force: force, strategy: strategy);
          
          // After sync, check if we need to seek current episode
          if (_currentEpisode != null && _audioHandler.mediaItem.value?.id == _currentEpisode!.guid) {
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
      }
      
      // Enrich Queue with new actions — runs for ALL profiles (uses PodcastProvider, not API)
      await _enrichQueueFromProvider();
      
      // Compute queue sync changes
      final queueChanges = await _computeQueueSyncChanges();
      
      // Auto-apply if strategy is serverWins
      final queueStrategy = _settings?.queueSyncStrategy ?? QueueSyncStrategy.ask;
      if (queueStrategy == QueueSyncStrategy.serverWins && queueChanges.isNotEmpty) {
          Log.i('PlayerProvider', 'Auto-applying ${queueChanges.length} queue sync changes (serverWins)');
          await applyQueueSyncChanges(queueChanges);
          return SyncResult(conflicts: conflicts, queueChanges: []);
      } else if (queueStrategy == QueueSyncStrategy.deviceWins) {
          Log.d('PlayerProvider', 'Ignoring ${queueChanges.length} queue sync changes (deviceWins)');
          return SyncResult(conflicts: conflicts, queueChanges: []);
      }
      
      return SyncResult(conflicts: conflicts, queueChanges: queueChanges);
  }

  /// Compute proposed queue changes from server episode actions.
  Future<List<QueueSyncChange>> _computeQueueSyncChanges() async {
      if (_podcastProvider == null) return [];
      
      final changes = QueueSyncService.computeChanges(
          localQueue: queue,
          actionMap: _podcastProvider!.actionMap,
          subscriptions: _podcastProvider!.subscriptions,
      );
      
      // Enrich changes with episode/podcast titles
      for (final change in changes) {
          if (change.episodeTitle == null) {
              final info = await _podcastProvider!.resolveEpisodeInfo(
                  change.podcastUrl, change.episodeGuid,
              );
              change.episodeTitle = info['episodeTitle'];
              change.podcastTitle ??= info['podcastTitle'];
          }
      }
      
      if (changes.isNotEmpty) {
          Log.d('PlayerProvider', 'Queue sync: ${changes.length} changes detected '
              '(${changes.where((c) => c.type == QueueSyncChangeType.add).length} add, '
              '${changes.where((c) => c.type == QueueSyncChangeType.remove).length} remove, '
              '${changes.where((c) => c.type == QueueSyncChangeType.update).length} update)');
      }
      
      return changes;
  }

  /// Apply accepted queue sync changes.
  Future<void> applyQueueSyncChanges(List<QueueSyncChange> changes) async {
      final processedGuids = <String>{};
      for (final change in changes) {
          if (!change.accepted) continue;
          // Skip if we already processed this episode in this batch
          if (!processedGuids.add(change.episodeGuid)) {
              Log.d('PlayerProvider', 'Queue sync: skipping duplicate change for ${change.episodeTitle ?? change.episodeGuid}');
              continue;
          }
          
          switch (change.type) {
              case QueueSyncChangeType.add:
                  await _applyQueueAdd(change);
                  break;
              case QueueSyncChangeType.remove:
                  final item = queue.where((i) => i.id == change.episodeGuid).firstOrNull;
                  if (item != null) {
                      await _audioHandler.removeQueueItem(item);
                      Log.d('PlayerProvider', 'Queue sync: removed ${change.episodeTitle ?? change.episodeGuid}');
                  }
                  break;
              case QueueSyncChangeType.update:
                  final idx = queue.indexWhere((i) => i.id == change.episodeGuid);
                  if (idx >= 0 && change.serverPosition != null) {
                      final item = queue[idx];
                      final newExtras = Map<String, dynamic>.from(item.extras ?? {});
                      newExtras['position_seconds'] = change.serverPosition;
                      final updated = item.copyWith(extras: newExtras);
                      final updatedQueue = List<MediaItem>.from(queue);
                      updatedQueue[idx] = updated;
                      await _audioHandler.updateQueue(updatedQueue);
                      Log.d('PlayerProvider', 'Queue sync: updated position for ${change.episodeTitle ?? change.episodeGuid}');
                  }
                  break;
          }
      }
  }

  /// Add an episode to the queue from a queue sync change.
  Future<void> _applyQueueAdd(QueueSyncChange change) async {
      // Guard: skip if episode is already in the queue
      if (queue.any((i) => i.id == change.episodeGuid)) {
          Log.d('PlayerProvider', 'Queue sync: skipping add for ${change.episodeTitle ?? change.episodeGuid} (already in queue)');
          return;
      }
      // Look up the episode in subscriptions to get full metadata
      if (_podcastProvider == null) return;
      
      Podcast? podcast;
      Episode? episode;
      
      try {
          podcast = _podcastProvider!.subscriptions
              .where((p) => p.url == change.podcastUrl)
              .firstOrNull;
          
          if (podcast != null) {
              final episodes = await _podcastProvider!.getEpisodes(podcast.url);
              episode = episodes.where((e) => e.guid == change.episodeGuid).firstOrNull;
          }
      } catch (e) {
          Log.e('PlayerProvider', 'Error looking up episode for queue add: $e');
      }
      
      if (episode != null && podcast != null && episode.audioUrl != null) {
          final mediaItem = MediaItemBuilder.fromEpisode(
              podcast, episode,
              positionSeconds: change.serverPosition,
          );
          await _audioHandler.addQueueItem(mediaItem);
          Log.d('PlayerProvider', 'Queue sync: added ${episode.title}');
      } else {
          Log.w('PlayerProvider', 'Queue sync: could not resolve episode ${change.episodeGuid} for add');
      }
  }

  /// Remove duplicate episodes from the queue, keeping the first occurrence.
  Future<void> _deduplicateQueue() async {
      final seen = <String>{};
      final currentQueue = queue;
      final deduped = <MediaItem>[];
      for (final item in currentQueue) {
          if (seen.add(item.id)) {
              deduped.add(item);
          }
      }
      if (deduped.length < currentQueue.length) {
          Log.i('PlayerProvider', 'Queue dedup: removed ${currentQueue.length - deduped.length} duplicate(s)');
          await _audioHandler.updateQueue(deduped);
      }
  }

  Future<void> _enrichQueueFromProvider() async {
       if (queue.isEmpty || _podcastProvider == null) return;
       
       final currentlyPlayingId = _audioHandler.mediaItem.value?.id;
       bool hasUpdates = false;
       final updatedQueue = queue.map((item) {
           // Don't overwrite the currently playing episode's position —
           // the player's live position is authoritative, not the server's.
           if (item.id == currentlyPlayingId) return item;
           final action = _podcastProvider!.getLatestAction(item.id);
           if (action != null && action.position != null) {
               final currentPos = safeInt(item.extras?['position_seconds']);
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
           Log.d('PlayerProvider', 'Queue enriched with new actions from PodcastProvider');
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
      // Wait for AudioHandler._init() to finish (loads queue + last mediaItem
      // from disk). Without this, mediaItem.value may still be null, causing
      // step 2 to incorrectly call prepareMediaItem(queue[0]) and override
      // the restored state.
      await _audioHandler.ready;

      // 1. Current Loaded Item (Playing or Paused)
      if (_audioHandler.mediaItem.value != null) {
          _syncFromMediaItem(_audioHandler.mediaItem.value!, podcastProvider);
          return; 
      }
      
      // 2. Queue Top (Device Queue)
      if (_audioHandler.queue.value.isNotEmpty) {
          final item = _audioHandler.queue.value.first;
          // Only call prepareMediaItem if _loadLastState didn't already load
          // the same item (avoids a duplicate network request on cold start).
          final alreadyLoaded = _audioHandler.mediaItem.value;
          if (alreadyLoaded == null || alreadyLoaded.id != item.id) {
              await _audioHandler.prepareMediaItem(item);
          }
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
                   final mediaItem = MediaItemBuilder.fromEpisode(podcast, episode);
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
      Podcast? podcast;
      Episode? episode;

      if (item.extras?['podcastUrl'] != null) {
         final pUrl = item.extras!['podcastUrl'] as String;
         podcast = provider.subscriptions.where((p) => p.url == pUrl).firstOrNull 
             ?? Podcast(url: pUrl, title: item.album ?? 'Unknown');
         
         // Try to find full episode from provider's cache (includes description)
         final cachedEpisode = provider.findEpisodeInCache(pUrl, item.id);
         
         episode = cachedEpisode ?? Episode(
             guid: item.id,
             title: item.title,
             description: '',
             audioUrl: item.extras?['url'],
             imageUrl: item.artUri?.toString(),
             duration: item.duration,
             chaptersUrl: item.extras?['chaptersUrl'],
             transcriptUrl: item.extras?['transcriptUrl'],
             pubDate: item.extras?['pubDate'] != null 
                 ? DateTime.tryParse(item.extras!['pubDate']) 
                 : null,
         );
         
         // If not cached, warm up the cache for next time
         if (cachedEpisode == null) {
             provider.getEpisodes(pUrl).catchError((_) => <Episode>[]);
         }
      } else {
         // No podcastUrl — build a synthetic Episode from the MediaItem
         // so the mini player still shows the currently playing episode.
         Log.w('PlayerProvider', '_syncFromMediaItem: no podcastUrl for "${item.title}" — using fallback');
         podcast = Podcast(url: '', title: item.album ?? 'Unknown');
         episode = Episode(
             guid: item.id,
             title: item.title,
             description: '',
             audioUrl: item.extras?['url'],
             imageUrl: item.artUri?.toString(),
             duration: item.duration,
             pubDate: item.extras?['pubDate'] != null 
                 ? DateTime.tryParse(item.extras!['pubDate']) 
                 : null,
         );
      }

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
           final localPos = safeInt(queueItem.extras!['position_seconds']);
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
        'podcastUrl': podcast.url,
        if (episode.chaptersUrl != null) 'chaptersUrl': episode.chaptersUrl,
        if (episode.transcriptUrl != null) 'transcriptUrl': episode.transcriptUrl,
        if (episode.pubDate != null) 'pubDate': episode.pubDate!.toIso8601String(),
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
          // Retry loop for streaming: 2 attempts with 1s delay.
          // Only report error after both retries fail.
          const maxAttempts = 2;
          bool success = false;
          for (var attempt = 0; attempt < maxAttempts; attempt++) {
              if (attempt > 0) {
                  Log.i('PlayerProvider', 'play() retry ${attempt + 1}/$maxAttempts after 1s');
                  await Future.delayed(const Duration(seconds: 1));
              }
              try {
                  Log.d('PlayerProvider', 'Streaming (attempt ${attempt + 1}): ${episode.audioUrl}');
                  await _audioHandler.playEpisode(mediaItem, episode.audioUrl!, initialPosition: initialPosition);
                  success = true;
                  break; // Success
              } catch (e) {
                  Log.w('PlayerProvider', 'play() attempt ${attempt + 1} failed: $e');
                  if (attempt == maxAttempts - 1) {
                      rethrow; // Let outer catch handle final error
                  }
              }
          }
          if (!success) return; // Should not reach here, but safety guard
      }
      
      _lastSyncTime = DateTime.now();
      _lastSyncedPosition = initialPosition?.inSeconds ?? 0;
      _syncProgress(action: 'play');
      _startLiveActivity();
      
      notifyListeners();
    } catch (e) {
      Log.e('PlayerProvider', 'Error playing audio: $e');
      _audioHandler.reportError("Couldn't play episode — check your connection");
    }
  }

  void togglePlay() {
    if (_player.playing) {
      _audioHandler.pause();
      _syncProgress(action: 'play');
    } else if (_audioHandler.hasFailedItem) {
      // Player has no loaded source after a failed auto-advance/retry.
      // Calling _player.play() would be a no-op. Route to retry instead.
      Log.i('PlayerProvider', 'togglePlay: routing to retryPlayback (has failed item)');
      retryPlayback();
    } else {
      _audioHandler.play();
      _syncProgress(action: 'play');
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
       
       final mediaItem = MediaItemBuilder.fromEpisode(
         podcast, episode,
         positionSeconds: savedPosition,
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
          
          final savedPosition = positionMap[episode.guid];
          return MediaItemBuilder.fromEpisode(
            podcast, episode,
            positionSeconds: savedPosition,
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
       
       final mediaItem = MediaItemBuilder.fromEpisode(
         podcast, episode,
         positionSeconds: savedPosition,
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
      
      // Position not in extras — start playback immediately from 0,
      // then fetch position from server in background and seek if found.
      // This eliminates the "dead time" where the user sees nothing happen.
      Log.d('PlayerProvider', 'playMediaItem - position missing, playing immediately then fetching position in background');
      await _audioHandler.playMediaItem(item);
      
      // Background seek: fetch position from server and seek if found
      if (_api != null) {
          _fetchAndSeekPosition(item).catchError((e) {
              Log.d('PlayerProvider', 'Background position fetch failed (non-fatal): $e');
          });
      }
  }
  
  /// Helper to update current episode/podcast from MediaItem for UI display
  void _updateCurrentFromMediaItem(MediaItem item) {
      // Try to find the podcast from podcastUrl in extras
      if (item.extras?['podcastUrl'] != null && _podcastProvider != null) {
          final podcastUrl = item.extras!['podcastUrl'] as String;
          final podcast = _podcastProvider!.subscriptions
              .where((p) => p.url == podcastUrl)
              .firstOrNull ?? Podcast(url: podcastUrl, title: item.album ?? 'Unknown');
          
          // Try to find full episode from provider's cache (includes description)
          final cachedEpisode = _podcastProvider!.findEpisodeInCache(podcastUrl, item.id);
          
          final episode = cachedEpisode ?? Episode(
              guid: item.id,
              title: item.title,
              description: '',
              audioUrl: item.extras?['url'],
              imageUrl: item.artUri?.toString(),
              duration: item.duration,
              chaptersUrl: item.extras?['chaptersUrl'],
              transcriptUrl: item.extras?['transcriptUrl'],
              pubDate: item.extras?['pubDate'] != null 
                  ? DateTime.tryParse(item.extras!['pubDate']) 
                  : null,
          );
          
          // If not cached, warm up the cache for next time
          if (cachedEpisode == null) {
              _podcastProvider!.getEpisodes(podcastUrl).catchError((_) => <Episode>[]);
          }
          
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

  /// Background helper: fetch saved position from server and seek if found.
  /// Called after playback has already started so the user hears audio immediately.
  Future<void> _fetchAndSeekPosition(MediaItem item) async {
      try {
          final actions = await _api!.getEpisodeActions(_deviceId)
              .timeout(const Duration(seconds: 2));
          final relatedActions = actions.where((a) => a.episode == item.id).toList();
          
          if (relatedActions.isNotEmpty) {
              relatedActions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
              final latest = relatedActions.first;
              if (latest.position != null && latest.position! > 0) {
                  // Only seek if we're still playing the same episode
                  if (_audioHandler.mediaItem.value?.id == item.id) {
                      Log.i('PlayerProvider', 'Background seek to ${latest.position}s for ${item.title}');
                      await _audioHandler.seek(Duration(seconds: latest.position!));
                      
                      // Update queue item extras for future plays
                      final currentQueue = _audioHandler.queue.value;
                      final idx = currentQueue.indexWhere((i) => i.id == item.id);
                      if (idx >= 0) {
                          final newExtras = Map<String, dynamic>.from(currentQueue[idx].extras ?? {});
                          newExtras['position_seconds'] = latest.position!;
                          final updatedQueue = List<MediaItem>.from(currentQueue);
                          updatedQueue[idx] = currentQueue[idx].copyWith(extras: newExtras);
                          await _audioHandler.updateQueue(updatedQueue);
                      }
                  }
              }
          }
      } catch (e) {
          Log.d('PlayerProvider', 'Background position fetch failed: $e');
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
        episode: item.extras?['url'] as String? ?? item.id, 
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
    
    Future<void> _syncProgress({required String action, bool bypassDebounce = false}) async {
        final apiToUse = api;
        if (apiToUse == null || _currentPodcast == null || _currentEpisode == null) {
            return;
        }

        // Don't compete for bandwidth during active recovery or error state
        final processingState = _audioHandler.playbackState.value.processingState;
        if (processingState == AudioProcessingState.error) return;

        // B5: Debounce non-stop actions to avoid excessive server uploads.
        // forceSync calls bypass this gate to ensure data reaches the server
        // before the OS can kill the app.
        if (!bypassDebounce && action != 'stop' && DateTime.now().difference(_lastUploadTime).inSeconds < 30) return;

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
      episode: _currentEpisode!.audioUrl ?? episodeId,
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
