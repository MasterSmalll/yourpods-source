import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import '../models/podcast.dart';
import '../providers/podcast_provider.dart';
import '../services/log_service.dart';
import '../services/queue_manager.dart';
import '../utils/safe_int.dart';
import '../utils/user_agent.dart';

class PodcastAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final QueueManager _queueManager = QueueManager();

  /// Completes when _init() finishes. Public methods that depend on
  /// loaded state (play, playMediaItem, etc.) await this before proceeding.
  final Completer<void> _ready = Completer<void>();
  /// Resolves when init (including _loadLastState) is complete. External
  /// callers that need the restored queue/mediaItem should await this.
  Future<void> get ready => _ready.future;

  /// Stream of user-visible error messages (e.g. network failures during
  final _playbackErrorController = StreamController<String>.broadcast();
  Stream<String> get playbackError => _playbackErrorController.stream;
  
  /// Public method to report errors to the UI via the NowPlayingBar snackbar.
  /// Routed through [_emitError] to prevent cascading banners.
  void reportError(String message) {
    _emitError(message);
  }

  /// Expose QueueManager for direct access by PlayerProvider.
  QueueManager get queueManager => _queueManager;

  PodcastProvider? _podcastProvider;
  
  // B8: Debounce timestamp for _saveLastState in _broadcastState
  DateTime _lastBroadcastSaveTime = DateTime(0);

  // Error debounce: suppress cascading banners from multiple independent
  // error paths (stream error handler + buffer health + playMediaItem)
  DateTime _lastErrorEmitTime = DateTime(0);
  static const _errorDebounceWindow = Duration(seconds: 3);

  // Stream recovery state
  int _recoveryAttempts = 0;
  bool _isRecovering = false;
  static const int _maxRecoveryAttempts = 5;
  /// Current recovery attempt count (0 = not recovering). Exposed for UI/testing.
  int get recoveryAttempts => _recoveryAttempts;

  // Queue auto-advance guard (prevents duplicate ProcessingState.completed events)
  bool _isAdvancingQueue = false;

  // Remembers the item that failed during auto-advance so Retry can re-attempt.
  MediaItem? _lastFailedItem;

  /// Whether there is a pending failed item that needs retrying.
  /// Used by PlayerProvider to route Play button taps to retry logic.
  bool get hasFailedItem => _lastFailedItem != null;

  // Tracks the episode ID of the currently active source-load in playEpisode.
  // Used instead of a depth counter to prevent race conditions when the user
  // rapidly taps play on different episodes.  _broadcastState skips saves
  // when this is non-null (source swap in progress).
  String? _activeTransitionId;
  bool get _isTransitioning => _activeTransitionId != null;

  // Suppresses error snackbars until the user actually initiates playback.
  // Prevents network errors appearing on cold start from _prepPlayer / stream
  // recovery when the app is just restoring last state.
  bool _hasPlayedOnce = false;

  // Buffer health monitoring
  Duration _lastHealthCheckPosition = Duration.zero;
  int _stallCount = 0;
  // Retained for lifecycle; cancel in dispose if handler is ever torn down.
  // ignore: unused_field
  Timer? _bufferHealthTimer;



  void setPodcastProvider(PodcastProvider provider) {
      _podcastProvider = provider;
  }

  /// Saved position from _loadLastState, used by play() on first resume.
  Duration? _restoredPosition;

  /// Set the active profile and reload queue/state from profile-scoped storage.
  Future<void> setProfileId(String profileId) async {
      if (_queueManager.profileId == profileId) return;
      
      // Save current profile's state before switching
      if (_queueManager.profileId != null) {
          final currentItem = mediaItem.value;
          final currentPosition = _player.position;
          if (currentItem != null) {
              await _queueManager.saveState(currentItem, currentPosition);
          } else {
              await _queueManager.saveQueue(queue.value);
          }
          
          // Stop playback so old profile's audio doesn't bleed into new one
          await _player.stop();
          mediaItem.add(null);
      }
      
      // QueueManager handles migration + loading; its queue stream
      // is already piped to BaseAudioHandler.queue.
      await _queueManager.setProfileId(profileId);
      await _loadLastState();
  }
  
  PodcastAudioHandler() {
    // Pipe QueueManager.queue → BaseAudioHandler.queue so all existing
    // consumers (CarPlay, PlayerProvider, etc.) see the same data.
    _queueManager.queue.listen((q) => queue.add(q));
    _init();
  }

  Future<void> _init() async {
    Log.d('AudioHandler', 'Initializing...');
    
    // Configure audio session for podcast/spoken audio
    try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.speech());
        Log.i('AudioHandler', 'Audio session configured');
    } catch (e) {
        Log.e('AudioHandler', 'Error configuring audio session: $e');
    }
    
    // Clean up old stream cache files from previous sessions
    _cleanStreamCache();
    
    // NOTE: _loadLastState() is NOT called here — profile ID hasn't been
    // set yet, so all profile-scoped keys return null.  State loading 
    // happens in setProfileId(), called from PlayerProvider.setApi().
    
    // Signal that initialization is complete — unblocks play/playMediaItem/etc.
    _ready.complete();
    
    // Propagate all events from the audio player to AudioService clients.
    // The onError handler catches stream-level failures (network drops,
    // server resets) that just_audio exposes as stream errors.
    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        Log.e('AudioHandler', 'Playback stream error — attempting recovery', e, st);
        if (_hasPlayedOnce) {
          _attemptStreamRecovery();
        } else {
          Log.w('AudioHandler', 'Suppressing stream recovery (no user-initiated playback yet)');
        }
      },
    );
    
    // Broadcast the current media item when the processing state changes
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
         _handlePlaybackCompleted();
      }
    });

    // Buffer health monitor: every 10s, check that position is advancing
    // while the player claims to be playing. Two consecutive stalls (20s
    // of no progress) trigger automatic stream recovery.
    _bufferHealthTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkBufferHealth());

    // Update duration when available (important for streams/files where duration isn't known upfront)
    _player.durationStream.listen((duration) {
        if (duration != null) {
            final current = mediaItem.value;
            if (current != null && current.duration != duration) {
                mediaItem.add(current.copyWith(duration: duration));
            }
        }
    });
  }

  Future<void> _handlePlaybackCompleted() async {
      // Guard against duplicate ProcessingState.completed events from just_audio.
      if (_isAdvancingQueue) {
          Log.d('AudioHandler', '_handlePlaybackCompleted() skipped — already advancing');
          return;
      }
      _isAdvancingQueue = true;

      try {
        Log.d('AudioHandler', '_handlePlaybackCompleted() called');
        final currentMedia = mediaItem.value;
        if (currentMedia == null) {
            Log.d('AudioHandler', 'No current media item, stopping');
            stop();
            return;
        }

        // --- Unified advance: QueueManager handles both "in-queue" and
        // "not-in-queue" (direct play) scenarios in one atomic operation. ---
        final result = _queueManager.advanceFrom(currentMedia.id);
        final nextItem = result.next;

        if (nextItem == null) {
            Log.i('AudioHandler', 'Queue finished (no more items)');
            stop();
            return;
        }

        Log.i('AudioHandler', 'Auto-advancing to: ${nextItem.title} (${result.updatedQueue.length} remaining)');

        // Set next item immediately so lock screen / CarPlay don't see a null gap.
        mediaItem.add(nextItem);
        _queueManager.saveState(nextItem, Duration.zero);

        // Extract URL — bail early on data issues
        final nextUrl = nextItem.extras?['url'] as String?;
        if (nextUrl == null) {
            Log.e('AudioHandler', 'Next item "${nextItem.title}" has no URL — stopping');
            stop();
            return;
        }

        // Clear any previous failed item on new advance attempt
        _lastFailedItem = null;

        // Retry loop with exponential backoff.
        // Audio session re-activation is INSIDE the loop because
        // _player.stop() (called on failure) deactivates the session.
        const maxRetries = 5;
        for (var attempt = 0; attempt < maxRetries; attempt++) {
            if (attempt > 0) {
                final backoff = Duration(seconds: min(2 << (attempt - 1), 30)); // 2s, 4s, 8s, 16s, 30s
                Log.i('AudioHandler', 'Auto-advance retry ${attempt + 1}/$maxRetries in ${backoff.inSeconds}s');
                await Future.delayed(backoff);
                // Bail if user started something else while we were waiting
                if (mediaItem.value?.id != nextItem.id) {
                    Log.i('AudioHandler', 'Auto-advance retry cancelled — different episode now active');
                    return;
                }
            }

            // Re-activate the audio session BEFORE each attempt.
            // iOS deactivates AVAudioSession when a track completes AND
            // when _player.stop() is called (which happens on failure).
            try {
                final session = await AudioSession.instance;
                await session.setActive(true);
                Log.d('AudioHandler', 'Audio session re-activated (attempt ${attempt + 1})');
            } catch (e) {
                Log.w('AudioHandler', 'Failed to re-activate audio session: $e');
            }

            try {
                await playEpisode(nextItem, nextUrl, isAutoAdvance: true);
                // Force a full state broadcast so Dynamic Island /
                // lock screen picks up the new episode immediately.
                _broadcastState(_player.playbackEvent);
                return; // Success
            } catch (e) {
                Log.w('AudioHandler', 'Auto-advance attempt ${attempt + 1} failed: $e');
                if (attempt == maxRetries - 1) {
                    Log.e('AudioHandler', 'Auto-advance failed after $maxRetries attempts');
                    // Don't call stop() — keep the next item visible in
                    // lock screen / Dynamic Island so Retry can work.
                    _lastFailedItem = nextItem;
                    _emitError(_describeError(e));
                    return;
                }
            }
        }
      } finally {
        _isAdvancingQueue = false;
      }
  }

  Future<void> _loadLastState() async {
      // Delegate queue loading to QueueManager
      await _queueManager.loadQueue();

      // Load last playing item and position — metadata only, no network.
      // The player stays in idle state. When the user taps Play,
      // playEpisode handles loading the source (~1-2s with streaming).
      final savedState = await _queueManager.loadLastState();
      if (savedState != null) {
          mediaItem.add(savedState.item);
          _restoredPosition = savedState.position;
          Log.i('AudioHandler', 'Restored last state: "${savedState.item.title}" at ${savedState.position.inSeconds}s (metadata only, no pre-buffer)');
      } else {
          mediaItem.add(null);
      }
  }

  /// Save current state; delegates to QueueManager.
  Future<void> _saveLastState(MediaItem? item, Duration position) async {
      if (item == null) return;
      await _queueManager.saveState(item, position);
  }


  /// Force a fresh playback state broadcast to update MPNowPlayingInfoCenter.
  /// Call after re-presenting the CarPlay Now Playing template so the system
  /// gets current position/rate data for the progress bar.
  void refreshNowPlayingInfo() {
    Log.d('AudioHandler', "refreshNowPlayingInfo: playing=${_player.playing}, speed=${_player.speed}, pos=${_player.position}");
    _broadcastState(_player.playbackEvent);
    // Also re-set the media item to ensure duration is current
    final current = mediaItem.value;
    if (current != null) {
      mediaItem.add(current);
    }
  }

  @override
  Future<void> play() async {
    await _ready.future;

    // After force-quit restore, the player has mediaItem metadata but no
    // audio source loaded (processingState == idle).  Calling _player.play()
    // would be a no-op.  Detect this and route through playEpisode so the
    // source is loaded (~1-2s with streaming AudioSource.uri).
    if (_player.processingState == ProcessingState.idle && mediaItem.value != null) {
        Log.i('AudioHandler', 'play(): player idle with restored mediaItem — loading source');
        final item = mediaItem.value!;
        final url = item.extras?['url'] as String?;
        if (url != null) {
            final pos = _restoredPosition;
            _restoredPosition = null; // Clear after first use
            await playEpisode(item, url, autoPlay: true, initialPosition: pos);
            return;
        }
    }

    final pos = _player.position;
    final dur = mediaItem.value?.duration;
    if (dur != null && pos.inSeconds >= dur.inSeconds - 5) {
        Log.i('AudioHandler', 'play() called on completed item. Seeking to 0:00.');
        await _player.seek(Duration.zero);
    }
    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
  
  @override
  Future<void> skipToNext() async {
      // Map to fastForward (+30s) so Bluetooth/CarPlay next-track buttons
      // seek within the episode instead of jumping to the next episode.
      // Actual queue advancement happens via _handlePlaybackCompleted()
      // when an episode finishes, or via playMediaItem() from the UI.
      await fastForward();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
      if (index < 0 || index >= queue.value.length) return;
      // Play specific item
      await playMediaItem(queue.value[index]);
  }

  @override
  Future<void> skipToPrevious() async {
      // Map to rewind (-15s) so Bluetooth/CarPlay prev-track buttons
      // seek within the episode instead of jumping to the previous episode.
      await rewind();
  }

  @override
  Future<void> fastForward() async {
    final seekPos = _player.position + const Duration(seconds: 30);
    // Clamp to duration if available
    final duration = _player.duration;
    if (duration != null && seekPos > duration) {
       await seek(duration);
    } else {
       await seek(seekPos);
    }
  }

  @override
  Future<void> rewind() async {
    final seekPos = _player.position - const Duration(seconds: 15);
    if (seekPos < Duration.zero) {
       await seek(Duration.zero);
    } else {
       await seek(seekPos);
    }
  }
  
  // --- Playback Speed ---
  
  @override
  Future<void> setSpeed(double speed) async {
      await _player.setSpeed(speed);
  }
  
  double get currentSpeed => _player.speed;
  
  /// Cycle through common playback speeds: 1.0 -> 1.25 -> 1.5 -> 2.0 -> 1.0
  Future<double> cycleSpeed() async {
      final speeds = [1.0, 1.25, 1.5, 2.0];
      final currentIndex = speeds.indexOf(_player.speed);
      final nextIndex = (currentIndex + 1) % speeds.length;
      final newSpeed = speeds[nextIndex];
      await setSpeed(newSpeed);
      return newSpeed;
  }
  
  // --- Silence Skipping ---
  
  Future<void> setSkipSilenceEnabled(bool enabled) async {
      await _player.setSkipSilenceEnabled(enabled);
  }
  
  bool get skipSilenceEnabled => _player.skipSilenceEnabled;

  // --- Queue Management (delegated to QueueManager) ---
  
  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
      await _queueManager.addItem(mediaItem);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(this.mediaItem.value, _player.position);
  }
  
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
      await _queueManager.addItems(mediaItems);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
      // If the user removes the item currently playing, treating it as "skipping" to next
      if (this.mediaItem.value?.id == mediaItem.id) {
          Log.i('AudioHandler', 'Removing currently playing item, skipping to next/completing...');
          await _handlePlaybackCompleted();
          return;
      }
      await _queueManager.removeItem(mediaItem.id);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(this.mediaItem.value, _player.position);
  }
  
  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
      await _queueManager.updateQueue(newQueue);
      await _queueManager.saveQueue(newQueue);
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
      await _queueManager.reorder(oldIndex, newIndex);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(mediaItem.value, _player.position);
  }

  Future<void> insertAfterCurrent(List<MediaItem> items) async {
      if (items.isEmpty) return;
      await _queueManager.insertAfterCurrent(items, mediaItem.value?.id);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  Future<void> playNext(MediaItem item) async {
      await _queueManager.playNext(item, mediaItem.value?.id);
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(mediaItem.value, _player.position);
  }

  /// Force-save current queue and playback state to disk immediately.
  /// Called from lifecycle handlers to ensure no data is lost on force-quit.
  Future<void> forceSaveState() async {
      await _queueManager.saveQueue(queue.value);
      await _saveLastState(mediaItem.value, _player.position);
      Log.d('AudioHandler', 'Force-saved queue (${queue.value.length} items) and playback state');
  }

  // --- browsing methods for CarPlay/Android Auto ---

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    Log.d('AudioHandler', 'getChildren called for $parentMediaId');
    final List<MediaItem> children = [];
    
    // 1. Root Level
    if (parentMediaId == AudioService.browsableRootId) {
      Log.d('AudioHandler', 'Building Root');
      // Create tabs/root items
      children.add(const MediaItem(
        id: 'podcasts_root',
        album: '',
        title: 'Podcasts',
        playable: false,
      ));
      children.add(const MediaItem(
        id: 'queue_root',
        album: '',
        title: 'Queue',
        playable: false,
      ));
    } 
    // 2. Queue
    else if (parentMediaId == 'queue_root') {
        return queue.value;
    }
    // 3. Podcast List
    else if (parentMediaId == 'podcasts_root') {
      if (_podcastProvider != null) {
          final podcasts = _podcastProvider!.subscriptions;
          for (var p in podcasts) {
            children.add(MediaItem(
              id: p.url, // Using URL as ID for checking against
              album: '',
              title: p.title,
              artUri: p.logoUrl != null ? Uri.parse(p.logoUrl!) : null,
              playable: false,
            ));
          }
      }
    }
    // 4. Episode List (specific podcast)
    else {
      // specific podcast URL
      if (_podcastProvider != null) {
          // Use cached accessor
          final episodes = await _podcastProvider!.getEpisodes(parentMediaId);
          
          for (var e in episodes) {
            if (e.audioUrl == null) continue; // Skip episodes without audio
            children.add(MediaItem(
              id: e.guid, // Unique ID for the episode
              album: '',
              title: e.title,
              artist: '', 
              // We need to pass the audio URL in extras or handle it via lookup
              extras: {
                'url': e.audioUrl, 
                'podcastUrl': parentMediaId,
                if (e.pubDate != null) 'pubDate': e.pubDate!.toIso8601String(),
              },
              artUri: e.imageUrl != null ? Uri.parse(e.imageUrl!) : null,
              playable: true,
              duration: e.duration,
            ));
          }
      }
    }
    
    Log.d('AudioHandler', 'Returning ${children.length} items for $parentMediaId');
    return children;
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    // This is called when the OS needs details about a specific item
    return null;
  }
  
  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
      await _ready.future;
      // CarPlay/Android Auto user tapped an item.
      
      // Check queue first
      final queueItem = queue.value.where((i) => i.id == mediaId).firstOrNull;
      if (queueItem != null) {
          playMediaItem(queueItem);
          return;
      }

      if (_podcastProvider == null) return;

      // Find the episode logic using provider
      Episode? foundEpisode;
      Podcast? foundPodcast;
      
      final podcasts = _podcastProvider!.subscriptions;
      for (var p in podcasts) {
          // Use cached accessor
          final episodes = await _podcastProvider!.getEpisodes(p.url);
          try {
             foundEpisode = episodes.firstWhere((e) => e.guid == mediaId);
             foundPodcast = p;
             break;
          } catch (e) {
             // continue
          }
      }
      
      if (foundEpisode != null && foundPodcast != null && foundEpisode.audioUrl != null) {
          // Play it
          try {
              await playEpisode(
                  MediaItem(
                      id: foundEpisode.guid,
                      title: foundEpisode.title,
                      album: foundPodcast.title,
                      artist: '',
                      artUri: foundEpisode.imageUrl != null ? Uri.parse(foundEpisode.imageUrl!) : null,
                      duration: foundEpisode.duration,
                       extras: {
                           'url': foundEpisode.audioUrl,
                           'podcastUrl': foundPodcast.url,
                           if (foundEpisode.pubDate != null) 'pubDate': foundEpisode.pubDate!.toIso8601String(),
                       }
                  ),
                  foundEpisode.audioUrl!,
              );
          } catch (e) {
              Log.e('AudioHandler', 'playFromMediaId failed for $mediaId: $e');
          }
      }
  }

  // --- Helper Methods to Load Data ---
  


  // ------------------------------------

  /// Retry the last failed auto-advance. Called by the Retry SnackBar button.
  /// Re-activates the audio session (which may have been deactivated by the
  /// failed attempt) and tries playMediaItem on the remembered item.
  Future<void> retryLastAutoAdvance() async {
      final item = _lastFailedItem;
      if (item == null) {
          Log.w('AudioHandler', 'retryLastAutoAdvance: no failed item to retry');
          return;
      }
      Log.i('AudioHandler', 'Retrying failed auto-advance: ${item.title}');

      // Retry loop with backoff — gives the network time to reconnect.
      // _lastFailedItem is only cleared on success so the user can re-tap Retry.
      const maxRetries = 3;
      for (var attempt = 0; attempt < maxRetries; attempt++) {
          if (attempt > 0) {
              final backoff = Duration(seconds: 3 << (attempt - 1)); // 3s, 6s
              Log.i('AudioHandler', 'Retry attempt ${attempt + 1}/$maxRetries in ${backoff.inSeconds}s');
              await Future.delayed(backoff);
          }

          // Re-activate the audio session before each attempt
          try {
              final session = await AudioSession.instance;
              await session.setActive(true);
          } catch (e) {
              Log.w('AudioHandler', 'Failed to re-activate audio session on retry: $e');
          }

          try {
              await playMediaItem(item);
              _lastFailedItem = null; // Success — clear for next cycle
              _playbackErrorController.add(''); // Dismiss error banner
              Log.i('AudioHandler', 'Retry succeeded on attempt ${attempt + 1}');
              return;
          } catch (e) {
              Log.w('AudioHandler', 'Retry attempt ${attempt + 1} failed: $e');
              if (attempt == maxRetries - 1) {
                  _lastFailedItem = item; // Preserve so Retry button works again
                  _emitError(_describeError(e));
              }
          }
      }
  }

  /// Helper to start playback of a specific item found in queue or custom.
  /// Retries once before showing an error banner.
  @override
  Future<void> playMediaItem(MediaItem item) async {
     await _ready.future;
     Log.d('AudioHandler', "playMediaItem called for ${item.id} - URL: ${item.extras?['url']}");
     if (item.extras?['url'] != null) {
         final positionSeconds = item.extras?['position_seconds'];
         final initialPosition = positionSeconds != null ? Duration(seconds: safeInt(positionSeconds)) : null;
         
         Log.d('AudioHandler', "Saved position: ${initialPosition?.inSeconds ?? 0}s");

         // Retry loop: 2 attempts with 1s delay. Only show error after both fail.
         const maxAttempts = 2;
         for (var attempt = 0; attempt < maxAttempts; attempt++) {
             if (attempt > 0) {
                 Log.i('AudioHandler', 'playMediaItem retry ${attempt + 1}/$maxAttempts after 1s');
                 await Future.delayed(const Duration(seconds: 1));
             }
             try {
                 await playEpisode(item, item.extras!['url'], initialPosition: initialPosition);
                 _lastFailedItem = null;
                 return; // Success
             } catch (e) {
                 Log.w('AudioHandler', 'playMediaItem attempt ${attempt + 1} failed for ${item.id}: $e');
                 if (attempt == maxAttempts - 1) {
                     Log.e('AudioHandler', 'playMediaItem failed after $maxAttempts attempts');
                     _lastFailedItem = item;
                     _emitError(_describeError(e));
                 }
             }
         }
     } else {
         Log.e('AudioHandler', "Error - No URL in extras for ${item.id}");
     }
}

  /// Helper to prepare playback of a specific item without playing.
  /// Wrapped in runZonedGuarded because just_audio can throw
  /// 'Loading interrupted' exceptions in async microtasks that escape
  /// normal try/catch when the user taps play during preparation.
  Future<void> prepareMediaItem(MediaItem item) async {
       Log.d('AudioHandler', "prepareMediaItem called for ${item.id}");
       if (item.extras?['url'] != null) {
           final completer = Completer<void>();
           runZonedGuarded(() async {
               try {
                   await playEpisode(item, item.extras!['url'], autoPlay: false);
               } catch (e) {
                   Log.e('AudioHandler', 'prepareMediaItem failed for ${item.id}: $e');
                   _lastFailedItem = item; // Enable Retry button
                   if (_hasPlayedOnce) _emitError(_describeError(e));
               } finally {
                   if (!completer.isCompleted) completer.complete();
               }
           }, (error, stack) {
               // Catch zone-escaping 'Loading interrupted' from just_audio
               Log.w('AudioHandler', 'prepareMediaItem zone error (safe to ignore): $error');
               if (!completer.isCompleted) completer.complete();
           });
           await completer.future;
       }
  }

  /// Helper to start playback of a specific item.
  /// [isAutoAdvance] – set to true when called from _handlePlaybackCompleted.
  /// When true, the re-queue logic is skipped (the completed episode was
  /// already removed) and the pre-buffer is not invalidated (it may be
  /// consumed by _prepPlayer).
  Future<void> playEpisode(MediaItem item, String url, {Duration? initialPosition, bool autoPlay = true, bool isAutoAdvance = false}) async {
    await _ready.future;
    // Mark that the user (or auto-advance) has initiated real playback.
    // Error snackbars are suppressed until this point.
    if (autoPlay) _hasPlayedOnce = true;
    Log.d('AudioHandler', "playEpisode called. URL: $url, AutoPlay: $autoPlay, isAutoAdvance: $isAutoAdvance");
    Log.d('AudioHandler', "MediaItem artUri: ${item.artUri}");

      // If we are already playing THIS EXACT item from THIS EXACT url, just play.
      if (_activeTransitionId == null && mediaItem.value?.id == item.id && _player.audioSource != null) {
          Log.i('AudioHandler', 'playEpisode: Same item and source already set, just playing');
          if (initialPosition != null) {
              await _player.seek(initialPosition);
          }
          if (autoPlay) {
              _player.play();
          }
          return;
      }
    
    // Clear any previous error states on manual play.
    if (!isAutoAdvance) {
        _lastFailedItem = null;
        _isRecovering = false;
        _recoveryAttempts = 0;
    }
    
    // If we are resuming a finished episode, start from the beginning.
    Duration? safePosition = initialPosition;
    final dur = item.duration;
    if (safePosition != null && dur != null && dur.inSeconds > 0) {
        if (safePosition.inSeconds >= dur.inSeconds - 5) {
            safePosition = Duration.zero;
            Log.i('AudioHandler', 'Episode previously finished. Resetting initialPosition to 0:00.');
        }
    }
    
    // Re-queue the currently playing episode if it's unfinished and different from the new one.
    // Skip this during auto-advance — the completed episode was already removed from the queue
    // by _handlePlaybackCompleted, so there is nothing to re-queue.
    if (!isAutoAdvance) {
        final currentItem = mediaItem.value;
        if (currentItem != null && currentItem.id != item.id) {
            final pos = _player.position;
            final dur = _player.duration ?? currentItem.duration;
            final isFinished = dur != null && pos.inSeconds >= dur.inSeconds - 5;
            if (!isFinished) {
                // Save current position into extras and re-insert at top of queue
                final updatedExtras = <String, dynamic>{...?currentItem.extras, 'position_seconds': pos.inSeconds};
                final requeued = currentItem.copyWith(extras: updatedExtras);
                final newQueue = List<MediaItem>.from(queue.value);
                newQueue.removeWhere((i) => i.id == requeued.id);
                newQueue.insert(0, requeued);
                await updateQueue(newQueue);
                Log.i('AudioHandler', 'Re-queued unfinished episode "${currentItem.title}" at position ${pos.inSeconds}s (persisted)');
            }
        }
    }

    try {
        _activeTransitionId = item.id;
        mediaItem.add(item);
        
        // In 1.3.0 there was no explicit stop() before loading a new source.
        // just_audio's setAudioSource() implicitly replaces the old source.
        // Calling stop() here was destroying the loaded source and resetting
        // the player to idle state, adding unnecessary latency.
        
        Log.d('AudioHandler', "Preparing player with: $url");
        final prepFuture = _prepPlayer(url, initialPosition: safePosition);
        
        // Await source load first, then check if we should still play.
        // This prevents "ghost plays" where the user pauses/switches
        // during a slow network load but audio blasts on anyway.
        await prepFuture;

        // Only clear the transition flag if WE are still the active request.
        // If the user tapped a different episode during our load, leave the
        // flag for the newer request to clear.
        if (_activeTransitionId == item.id) {
            _activeTransitionId = null;
        }

        if (autoPlay) {
            // Ghost play guard: if the user switched to a different episode
            // while we were loading, don't start playback.
            if (mediaItem.value?.id != item.id) {
                Log.i('AudioHandler', 'Ghost play prevented: user switched episodes during load');
                return;
            }
            // Duplicate-tap guard: if another load for the same episode is
            // already active (e.g. rapid CarPlay taps), bail out.
            if (_activeTransitionId == item.id) {
                Log.i('AudioHandler', 'Duplicate load detected for ${item.id}, skipping play');
                return;
            }
            if (isAutoAdvance) {
                Log.d('AudioHandler', 'Auto-advance: source loaded, starting playback');
            } else {
                Log.d('AudioHandler', 'Starting playback after source load');
            }
            await _player.play();
        }
        Log.d('AudioHandler', "Player source set and playing");
    } catch (e, stack) {
        if (_activeTransitionId == item.id) {
            _activeTransitionId = null;
        }
        if (!isAutoAdvance) {
            // For manual play: stop to clean up the bad state.
            // For auto-advance: DON'T stop — it deactivates the iOS
            // audio session, making the next retry silently fail.
            try { await _player.stop(); } catch (_) {}
        }
        Log.e('AudioHandler', "CRITICAL ERROR in playEpisode", e, stack);
        rethrow; // Let auto-advance retry loop and PlayerProvider catch this
    }
  }
  
  static const _sourceLoadTimeout = Duration(seconds: 10);

  /// Timeout wrapper for setAudioSource / setFilePath.
  ///
  /// Uses a Completer to race the load against a timeout, then throws
  /// TimeoutException if the timeout wins.  Does NOT call _player.stop()
  /// from the timer — that triggers just_audio's internal 'Loading
  /// interrupted' exception in a microtask zone that escapes try/catch.
  /// Instead the caller (playEpisode) handles the TimeoutException and
  /// calls stop() from its own catch block where the exception is local.
  Future<Duration?> _loadSourceWithTimeout(
      Future<Duration?> Function() loadFactory) async {
    try {
      return await loadFactory().timeout(_sourceLoadTimeout);
    } on TimeoutException {
      // Kill the native engine's pending download to prevent a
      // "zombie" play that starts after we've already shown an error.
      Log.w('AudioHandler', 'Source load timed out after $_sourceLoadTimeout — stopping player');
      try { await _player.stop(); } catch (_) {}
      rethrow;
    }
  }

  Future<void> _prepPlayer(String url, {Duration? initialPosition, Map<String, String>? headers}) async {
      final stopwatch = Stopwatch()..start();
      Log.d('AudioHandler', "_prepPlayer loading $url (pos: $initialPosition)");
      try {
        if (url.startsWith('/')) {
             await _loadSourceWithTimeout(
                 () => _player.setFilePath(url, initialPosition: initialPosition));
        } else {
             // Build auth headers from URL userinfo if present
             final uri = Uri.parse(url);
             final Map<String, String> authHeaders = {'User-Agent': yourPodsUserAgent, ...?headers};
             if (!authHeaders.containsKey('Authorization')) {
                 String userInfo = uri.userInfo;
                 
                 // If the audio URL doesn't have credentials, inherit from the podcast feed URL
                 if (userInfo.isEmpty) {
                     final podcastUrl = mediaItem.value?.extras?['podcastUrl'] as String?;
                     if (podcastUrl != null) {
                         final podcastUri = Uri.tryParse(podcastUrl);
                         if (podcastUri != null && podcastUri.userInfo.isNotEmpty) {
                             userInfo = podcastUri.userInfo;
                         }
                     }
                 }
                 
                 if (userInfo.isNotEmpty) {
                     final parts = userInfo.split(':');
                     final user = Uri.decodeComponent(parts[0]);
                     final pass = parts.length > 1 ? Uri.decodeComponent(parts.sublist(1).join(':')) : '';
                     final encoded = base64Encode(utf8.encode('$user:$pass'));
                     authHeaders['Authorization'] = 'Basic $encoded';
                 }
             }
             // Strip userinfo from URL for the player
             final cleanUrl = uri.userInfo.isNotEmpty ? uri.replace(userInfo: '').toString() : url;

             // ⚠️  DO NOT SWITCH TO LockCachingAudioSource WITHOUT EXPLICIT
             // USER PERMISSION.  It downloads the ENTIRE file to disk before
             // playback begins, which caused 30s+ stalls on cold start and
             // queue play.  AudioSource.uri() streams directly and plays in
             // ~1-2 seconds, matching 1.3.0 behaviour.  If you believe
             // caching is needed, discuss with the project owner first and
             // reference conversation 755eb5a9 for the full regression history.
             //
             // Stream directly using AudioSource.uri — just_audio begins
             // playback as soon as enough data is buffered (~1-2 seconds),
             // matching the 1.3.0 behaviour that worked reliably.
             final source = AudioSource.uri(
               Uri.parse(cleanUrl),
               headers: authHeaders.isNotEmpty ? authHeaders : null,
             );
             await _loadSourceWithTimeout(
                 () => _player.setAudioSource(source, initialPosition: initialPosition));
             Log.i('AudioHandler', '_prepPlayer source loaded in ${stopwatch.elapsedMilliseconds}ms');
        }
    } on PlayerInterruptedException {
        Log.d('AudioHandler', '_prepPlayer interrupted (normal — new source replacing old)');
        return;
    } catch (e, stack) {
        if (e.toString().contains('Loading interrupted')) {
            Log.d('AudioHandler', '_prepPlayer interrupted via generic Exception (normal)');
            return;
        }
        Log.e('AudioHandler', "Error loading audio source", e, stack);
        playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            playing: false,
        ));
        rethrow;
    }
  }

  /// Classify an exception into a user-friendly error message.
  static String _describeError(Object e) {
    if (e is TimeoutException) {
      return 'Episode server is too slow — try again later';
    }
    if (e is SocketException) {
      return 'No internet connection';
    }
    final msg = e.toString();
    // just_audio wraps HTTP errors in PlayerException
    if (msg.contains('403')) {
      return 'Episode blocked by server (403 Forbidden)';
    }
    if (msg.contains('404')) {
      return 'Episode not found on server (404)';
    }
    if (msg.contains('429')) {
      return 'Server is rate-limiting requests — try again later';
    }
    if (msg.contains('5') && (msg.contains('500') || msg.contains('502') || msg.contains('503') || msg.contains('504'))) {
      return 'Podcast server error — try again later';
    }
    if (msg.contains('Connection refused') || msg.contains('Connection reset')) {
      return 'Podcast server is unreachable';
    }
    return "Couldn't load episode — check your connection";
  }

  /// Debounced error emission to prevent cascading red banners.
  /// Multiple error paths (stream error handler, buffer health, playMediaItem)
  /// can fire within milliseconds of each other. This ensures only one banner
  /// is shown per [_errorDebounceWindow].
  void _emitError(String message) {
    final now = DateTime.now();
    if (now.difference(_lastErrorEmitTime) < _errorDebounceWindow) {
      Log.d('AudioHandler', 'Error debounced (suppressed): $message');
      return;
    }
    _lastErrorEmitTime = now;
    _playbackErrorController.add(message);
  }
  
  // --------------- Stream health & recovery ---------------

  /// Checks whether the player position is advancing during playback.
  /// Two consecutive stalls (20s of no forward progress) trigger recovery.
  void _checkBufferHealth() {
    if (!_player.playing || _isRecovering) return;
    
    final currentPosition = _player.position;
    if (currentPosition == _lastHealthCheckPosition) {
      _stallCount++;
      Log.w('AudioHandler', 'Buffer stall detected ($_stallCount consecutive, pos=${currentPosition.inSeconds}s)');
      if (_stallCount >= 2) {
        Log.e('AudioHandler', 'Buffer stalled for 20s+ — attempting stream recovery');
        _stallCount = 0;
        _attemptStreamRecovery();
      }
    } else {
      _stallCount = 0;
    }
    _lastHealthCheckPosition = currentPosition;
  }

  /// Attempts to recover a failed/stalled stream by re-loading the audio
  /// source at the last known good position, with exponential backoff.
  /// After [_maxRecoveryAttempts] failures, broadcasts an error state.
  Future<void> _attemptStreamRecovery() async {
    if (_isRecovering) return;
    
    final currentMedia = mediaItem.value;
    final url = currentMedia?.extras?['url'] as String?;
    if (currentMedia == null || url == null) return;
    
    _isRecovering = true;
    final savedPosition = _player.position;
    
    // Pause immediately to stop broken audio output
    try { await _player.pause(); } catch (_) {}

    // Don't show banner yet — let retries attempt recovery silently.
    Log.i('AudioHandler', 'Stream recovery starting (silent until retries exhausted)');
    
    Object? lastError;
    for (var attempt = 0; attempt < _maxRecoveryAttempts; attempt++) {
      _recoveryAttempts = attempt + 1;
      final backoff = Duration(seconds: 2 << attempt); // 2s, 4s, 8s
      Log.i('AudioHandler', 'Stream recovery attempt ${attempt + 1}/$_maxRecoveryAttempts (backoff: ${backoff.inSeconds}s)');
      
      await Future.delayed(backoff);

      // Re-activate the audio session before each attempt.
      // iOS may have deactivated it during the stall or pause.
      try {
          final session = await AudioSession.instance;
          await session.setActive(true);
      } catch (e) {
          Log.w('AudioHandler', 'Failed to re-activate audio session during recovery: $e');
      }
      
      try {
        // Clean any leftover cache files from the old LockCachingAudioSource
        // system (removed). Safe to skip if no cache dir exists.
        if (!url.startsWith('/')) {
            try {
                final cacheDir = Directory('${Directory.systemTemp.path}/yourpods_stream_cache');
                if (await cacheDir.exists()) {
                    await cacheDir.delete(recursive: true);
                    Log.d('AudioHandler', 'Cleaned stream cache dir for recovery');
                }
            } catch (_) {}
        }
        await _prepPlayer(url, initialPosition: savedPosition);
        await _player.play();
        Log.i('AudioHandler', 'Stream recovery succeeded on attempt ${attempt + 1}');
        _recoveryAttempts = 0;
        _isRecovering = false;
        _stallCount = 0;
        // Dismiss any prior error banner on success
        _playbackErrorController.add('');
        return;
      } catch (e) {
        lastError = e;
        Log.w('AudioHandler', 'Recovery attempt ${attempt + 1} failed: $e');
      }
    }
    
    // All retries exhausted — NOW show error banner + keep episode for Retry
    Log.e('AudioHandler', 'Stream recovery failed after $_maxRecoveryAttempts attempts');
    _isRecovering = false;
    _recoveryAttempts = 0;
    _lastFailedItem = currentMedia;
    _emitError(lastError != null ? _describeError(lastError) : 'Playback interrupted — check your connection');
  }

  // Expose the underlying player for advanced usage if absolutely necessary, 
  // but preferably keep logic encapsulated here or via mapped streams.
  AudioPlayer get internalPlayer => _player;

  /// Transform JustAudio state events into AudioService state events
  void _broadcastState(PlaybackEvent event) {
    if (mediaItem.value == null) return;
    // Don't save state during source transitions — position may be
    // stale (0:00 from new source while mediaItem points to old episode).
    // We still broadcast the playback state for UI updates, but skip
    // the persistence at the bottom of this method.
    final shouldSave = !_isTransitioning;
    final playing = _player.playing;
    final queueIndex = queue.value.indexWhere((i) => i.id == mediaItem.value?.id);
    
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.rewind, // Added Rewind -15
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.fastForward, // Added FF +30
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.fastForward,
        MediaAction.rewind,
        MediaAction.playFromMediaId, // IMPORTANT for CarPlay selection
        MediaAction.playPause,
        // Kept so Bluetooth next/prev buttons work — their overrides now
        // call fastForward()/rewind() instead of skipping episodes.
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 3],
      // When the player reaches 'completed' and we are advancing the queue,
      // or when we briefly call stop() and reach 'idle', broadcast 'loading'
      // instead. This prevents iOS from deactivating the AVAudioSession
      // and suspending the app before the next track starts.
      processingState: () {
        final rawState = _player.processingState;
        if (_isAdvancingQueue && (rawState == ProcessingState.completed || rawState == ProcessingState.idle)) {
            return AudioProcessingState.loading;
        }
        return const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[rawState]!;
      }(),
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: queueIndex >= 0 ? queueIndex : null,
    ));
    
    // Persist queue and position to disk. iOS force-quit does NOT trigger
    // lifecycle callbacks, so frequent saves are the only safety net.
    // SharedPreferences on iOS is NSUserDefaults — writes are fast.
    if (shouldSave) {
        final now = DateTime.now();
        final interval = playing ? 5 : 5;
        if (now.difference(_lastBroadcastSaveTime).inSeconds >= interval) {
             _saveLastState(mediaItem.value, _player.position);
             _lastBroadcastSaveTime = now;
        }
    }
  }



  // --------------- Stream cache helpers ---------------

  /// Remove stale stream cache files from previous sessions.
  /// Called once during [_init] to prevent unbounded disk growth.
  void _cleanStreamCache() {
    try {
      final cacheDir = Directory('${Directory.systemTemp.path}/yourpods_stream_cache');
      if (cacheDir.existsSync()) {
        final now = DateTime.now();
        for (final entity in cacheDir.listSync()) {
          if (entity is File) {
            final age = now.difference(entity.lastModifiedSync());
            if (age.inHours > 24) {
              entity.deleteSync();
            }
          }
        }
        Log.d('AudioHandler', 'Stream cache cleaned');
      }
    } catch (e) {
      Log.w('AudioHandler', 'Stream cache cleanup failed (non-fatal): $e');
    }
  }

  /// Cancel background timers. Call if the handler is ever torn down.
  void dispose() {
    _bufferHealthTimer?.cancel();
    _bufferHealthTimer = null;
    _playbackErrorController.close();
    _queueManager.dispose();
  }
}
