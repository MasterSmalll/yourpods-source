import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/podcast.dart';
import '../services/log_service.dart';

class PodcastAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  
  // Keep track of the current mapping to quickly find items if needed
  // In a real app with huge libraries, we'd need a more efficient way or rely on IDs.
  
  PodcastAudioHandler() {
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
    
    await _loadLastState();
    
    // Propagate all events from the audio player to AudioService clients
    _player.playbackEventStream.listen(_broadcastState);
    
    // Broadcast the current media item when the processing state changes
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
         _handlePlaybackCompleted();
      }
    });

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
      Log.d('AudioHandler', '_handlePlaybackCompleted() called');
      // Check if there is a next item in the queue
      if (queue.value.isNotEmpty) {
          final currentMedia = mediaItem.value;
          if (currentMedia != null) {
              final currentIndex = queue.value.indexWhere((item) => item.id == currentMedia.id);
              Log.d('AudioHandler', 'Current item index in queue: $currentIndex');
              
              // Remove the completed item from the queue
              if (currentIndex >= 0) {
                  final newQueue = List<MediaItem>.from(queue.value);
                  newQueue.removeAt(currentIndex);
                  queue.add(newQueue);
                  // Should we zero out position? Yes, for the *next* item usually, but here we just save the list update.
                  await _saveLastState(mediaItem.value, Duration.zero);
                  Log.d('AudioHandler', 'Removed completed episode from queue, ${newQueue.length} items remaining');
                  
                  // Play next item if there is one (it's now at currentIndex after removal)
                  if (currentIndex < newQueue.length) {
                      final nextItem = newQueue[currentIndex];
                      Log.i('AudioHandler', 'Playing next item: ${nextItem.title}');
                      playMediaItem(nextItem);
                      return;
                  } else {
                      Log.i('AudioHandler', 'Queue finished (no more items)');
                  }
              } else {
                  Log.w('AudioHandler', 'Current item not found in queue');
              }
              
              // End of queue or item not found
              stop();
              return;
          }
          // If we are not in the queue (e.g. played single episode), check if we should just stop
          // or if we should start the queue? For now, stop.
          Log.d('AudioHandler', 'No current media item, stopping');
          stop();
      } else {
          Log.d('AudioHandler', 'Queue is empty, stopping');
          stop();
      }
  }

  Future<void> _loadLastState() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          
          // Load Queue
          final queueString = prefs.getString('audio_queue');
          if (queueString != null) {
              final List<dynamic> queueJson = json.decode(queueString);
              final List<MediaItem> loadedQueue = queueJson.map((item) => MediaItem(
                id: item['id'],
                title: item['title'],
                album: item['album'],
                artist: item['artist'],
                artUri: item['artUri'] != null ? Uri.parse(item['artUri']) : null,
                duration: item['duration'] != null ? Duration(milliseconds: item['duration']) : null,
                extras: item['extras'],
                playable: item['playable'] ?? true,
              )).toList();
              // QueueHandler mixin provides 'queue' behavior subject
              queue.add(loadedQueue);
          }

          final jsonString = prefs.getString('last_media_item');
          final positionMs = prefs.getInt('last_position') ?? 0;
          
          if (jsonString != null) {
              final Map<String, dynamic> jsonMap = json.decode(jsonString);
              final item = MediaItem(
                id: jsonMap['id'],
                title: jsonMap['title'],
                album: jsonMap['album'],
                artist: jsonMap['artist'],
                artUri: jsonMap['artUri'] != null ? Uri.parse(jsonMap['artUri']) : null,
                duration: jsonMap['duration'] != null ? Duration(milliseconds: jsonMap['duration']) : null,
                extras: jsonMap['extras'],
                playable: jsonMap['playable'] ?? true,
              );
              
              mediaItem.add(item);
              
              // Restore player state (prepare only)
              if (item.extras?['url'] != null) {
                   await _prepPlayer(item.extras!['url'] as String, initialPosition: Duration(milliseconds: positionMs));
              }
          }
      } catch (e) {
          Log.e('AudioHandler', "Error restoring state: $e");
      }
  }

  Future<void> _saveLastState(MediaItem? item, Duration position) async {
       if (item == null) return;
       try {
          final prefs = await SharedPreferences.getInstance();
          final jsonMap = _mediaItemToJson(item);
          await prefs.setString('last_media_item', json.encode(jsonMap));
          await prefs.setInt('last_position', position.inMilliseconds);
          
          // Save Queue
          final queueJson = queue.value.map((i) => _mediaItemToJson(i)).toList();
          await prefs.setString('audio_queue', json.encode(queueJson));
          
       } catch (e) {
           // ignore
       }
  }
  
  Map<String, dynamic> _mediaItemToJson(MediaItem item) {
      return {
        'id': item.id,
        'title': item.title,
        'album': item.album,
        'artist': item.artist,
        'artUri': item.artUri?.toString(),
        'duration': item.duration?.inMilliseconds,
        'extras': item.extras,
        'playable': item.playable,
      };
  }


  @override
  Future<void> play() => _player.play();

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
      await _handlePlaybackCompleted(); // Logic is similar: play next in queue
  }

  @override
  Future<void> skipToQueueItem(int index) async {
      if (index < 0 || index >= queue.value.length) return;
      // Play specific item
      await playMediaItem(queue.value[index]);
  }

  @override
  Future<void> skipToPrevious() async {
     // If near start, replay. If distinct previous item, go to it.
     if (_player.position.inSeconds > 5) {
         seek(Duration.zero);
     } else {
        if (queue.value.isNotEmpty) {
            final currentMedia = mediaItem.value;
            if (currentMedia != null) {
                final currentIndex = queue.value.indexWhere((item) => item.id == currentMedia.id);
                if (currentIndex > 0) {
                    final prevItem = queue.value[currentIndex - 1];
                    playMediaItem(prevItem);
                } else {
                     seek(Duration.zero);
                }
            }
        }
     }
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

  // --- Queue Management ---
  
  @override
  Future<void> addQueueItem(MediaItem item) async {
      final newQueue = List<MediaItem>.from(queue.value)..add(item);
      queue.add(newQueue);
      await _saveLastState(mediaItem.value, _player.position); // Save queue persistence
  }
  
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
      final newQueue = List<MediaItem>.from(queue.value)..addAll(mediaItems);
      queue.add(newQueue);
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  @override
  Future<void> removeQueueItem(MediaItem item) async {
      // If the user removes the item currently playing, treating it as "skipping" to next
      if (mediaItem.value?.id == item.id) {
          Log.i('AudioHandler', 'Removing currently playing item, skipping to next/completing...');
          await _handlePlaybackCompleted(); // Use handlePlaybackCompleted to handle queue logic/next item
          return;
      }
      
      final newQueue = List<MediaItem>.from(queue.value)..removeWhere((i) => i.id == item.id);
      queue.add(newQueue);
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
      queue.add(newQueue);
      // Use explicit save to ensure extras (progress) are persisted
      await _saveQueue(newQueue);
      // Also save legacy state just in case
      await _saveLastState(mediaItem.value, _player.position);
  }
  
  // Custom helper for reordering
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final newQueue = List<MediaItem>.from(queue.value);
      final item = newQueue.removeAt(oldIndex);
      newQueue.insert(newIndex, item);
      queue.add(newQueue);
      await _saveLastState(mediaItem.value, _player.position);
  }

  /// Inserts a list of items immediately after the current item, or at the top if nothing is playing.
  Future<void> insertAfterCurrent(List<MediaItem> items) async {
      if (items.isEmpty) return;

      final newQueue = List<MediaItem>.from(queue.value);
      int insertIndex = 0;
      
      final currentMedia = mediaItem.value;
      if (currentMedia != null) {
          final currentIndex = newQueue.indexWhere((i) => i.id == currentMedia.id);
          if (currentIndex != -1) {
              insertIndex = currentIndex + 1;
          }
      }
      
      // Filter out duplicates (if they are already in the queue, we can decide to move them or skip. 
      // User intent usually implies specific addition, so moving seemingly creates "Play Next" effect best)
      final incomingIds = items.map((i) => i.id).toSet();
      
      // Remove any existing instances of these items so they can be moved to the new position
      newQueue.removeWhere((i) => incomingIds.contains(i.id));
      
      // Re-calculate index in case removal shifted things before it (unlikely if we insert after current, 
      // providing current is not one of the moved items!)
      // If current item was removed... that's a problem. 
      // But we shouldn't be "queueing next" the *current* item usually.
      
      // Re-find current index to be safe
      if (currentMedia != null) {
           final currentIndex = newQueue.indexWhere((i) => i.id == currentMedia.id);
           if (currentIndex != -1) {
               insertIndex = currentIndex + 1;
           } else {
               // Current was apparently removed or we are at start
               // If current was removed, we just insert at 0?
               insertIndex = 0;
           }
      } else {
        insertIndex = 0;
      }
      
      // Clamp
      if (insertIndex > newQueue.length) insertIndex = newQueue.length;
      
      // Insert
      newQueue.insertAll(insertIndex, items);
      
      await updateQueue(newQueue);
  }
  
  Future<void> playNext(MediaItem item) async {
      // Add to queue immediately after current item
      final currentMedia = mediaItem.value;
      final newQueue = List<MediaItem>.from(queue.value);
      
      int insertIndex = 0;
      if (currentMedia != null) {
          final currentIndex = newQueue.indexWhere((i) => i.id == currentMedia.id);
          if (currentIndex != -1) {
              insertIndex = currentIndex + 1;
          }
      }
      
      // If item already in queue, move it
      final existingIndex = newQueue.indexWhere((i) => i.id == item.id);
      if (existingIndex != -1) {
          newQueue.removeAt(existingIndex);
          if (existingIndex < insertIndex) insertIndex--; 
      }
      
      if (insertIndex > newQueue.length) insertIndex = newQueue.length;
      newQueue.insert(insertIndex, item);
      queue.add(newQueue);
      await _saveLastState(mediaItem.value, _player.position);
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
      final podcasts = await _loadLocalPodcasts();
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
    // 4. Episode List (specific podcast)
    else {
      // specific podcast URL
      // We assume the parentMediaId is the podcast URL from the step above
      final episodes = await _loadLocalEpisodes(parentMediaId);
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
      // CarPlay/Android Auto user tapped an item.
      
      // Check queue first
      final queueItem = queue.value.where((i) => i.id == mediaId).firstOrNull;
      if (queueItem != null) {
          playMediaItem(queueItem);
          return;
      }

      // Find the episode
      Episode? foundEpisode;
      Podcast? foundPodcast;
      
      final podcasts = await _loadLocalPodcasts();
      for (var p in podcasts) {
          final episodes = await _loadLocalEpisodes(p.url);
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
                      if (foundEpisode.pubDate != null) 'pubDate': foundEpisode.pubDate!.toIso8601String(),
                  }
              ),
              foundEpisode.audioUrl!,
          );
      }
  }

  // --- Helper Methods to Load Data ---
  
  Future<String?> _getCurrentProfileId() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('current_profile_id');
  }

  Future<List<Podcast>> _loadLocalPodcasts() async {
      try {
          final profileId = await _getCurrentProfileId();
          // If no profile, we can't show much, or show default?
          final safeId = profileId?.replaceAll(RegExp(r'[^\w]'), '_') ?? 'default';
          
          final directory = await getApplicationDocumentsDirectory();
          final file = File('${directory.path}/subs_$safeId.json');
          
          if (await file.exists()) {
              final jsonString = await file.readAsString();
              final List<dynamic> jsonList = json.decode(jsonString);
              return jsonList.map((j) => Podcast.fromJson(j)).toList();
          }
      } catch (e) {
          Log.e('AudioHandler', "Error loading podcasts: $e");
      }
      return [];
  }

  Future<List<Episode>> _loadLocalEpisodes(String podcastUrl) async {
       try {
          final directory = await getApplicationDocumentsDirectory();
          final filename = 'episodes_${const Uuid().v5(Uuid.NAMESPACE_URL, podcastUrl)}.json';
          final file = File('${directory.path}/$filename');
          
          if (await file.exists()) {
              final jsonString = await file.readAsString();
              final List<dynamic> jsonList = json.decode(jsonString);
              return jsonList.map((j) => Episode(
                  guid: j['guid'],
                  title: j['title'],
                  description: j['description'],
                  audioUrl: j['audioUrl'],
                  pubDate: j['pubDate'] != null ? DateTime.parse(j['pubDate']) : null,
                  imageUrl: j['imageUrl'],
                  duration: j['duration'] != null ? Duration(seconds: j['duration']) : null,
                  link: j['link'],
              )).toList();
          }
       } catch (e) {
           Log.e('AudioHandler', "Error loading episodes: $e");
       }
       return [];
  }

  // ------------------------------------

  /// Helper to start playback of a specific item found in queue or custom
Future<void> playMediaItem(MediaItem item) async {
     Log.d('AudioHandler', "playMediaItem called for ${item.id} - URL: ${item.extras?['url']}");
     Log.d('AudioHandler', "Full extras: ${item.extras}");
     if (item.extras?['url'] != null) {
         // Extract saved position from extras if available
         final positionSeconds = item.extras?['position_seconds'];
         Log.d('AudioHandler', "position_seconds type: ${positionSeconds.runtimeType}, value: $positionSeconds");
         
         final initialPosition = positionSeconds != null ? Duration(seconds: positionSeconds as int) : null;
         
         Log.d('AudioHandler', "Saved position found: ${initialPosition?.inSeconds ?? 0} seconds");
         await playEpisode(item, item.extras!['url'], initialPosition: initialPosition);
     } else {
         Log.e('AudioHandler', "Error - No URL in extras for ${item.id}");
     }
}

  /// Helper to prepare playback of a specific item without playing
  Future<void> prepareMediaItem(MediaItem item) async {
       Log.d('AudioHandler', "prepareMediaItem called for ${item.id}");
       if (item.extras?['url'] != null) {
           await playEpisode(item, item.extras!['url'], autoPlay: false);
       }
  }

  /// Helper to start playback of a specific item
  Future<void> playEpisode(MediaItem item, String url, {Duration? initialPosition, bool autoPlay = true}) async {
    Log.d('AudioHandler', "playEpisode called. URL: $url, AutoPlay: $autoPlay");
    Log.d('AudioHandler', "MediaItem artUri: ${item.artUri}");
    
    try {
        mediaItem.add(item);
        
        // Check for downloaded file first
        String playUrl = url;
        try {
            final localPath = await _getDownloadedPath(url);
            if (localPath != null) {
                Log.d('AudioHandler', "Found local file, using: $localPath");
                playUrl = localPath;
            }
        } catch (e) {
            Log.e('AudioHandler', "Error checking for local file: $e");
        }
        
        Log.d('AudioHandler', "Preparing player with: $playUrl");
        await _prepPlayer(playUrl, initialPosition: initialPosition);
        
        if (autoPlay) {
            Log.d('AudioHandler', "Calling play()");
            await play();
            Log.d('AudioHandler', "play() completed, playing: ${_player.playing}");
        }
    } catch (e, stack) {
        Log.e('AudioHandler', "CRITICAL ERROR in playEpisode", e, stack);
    }
  }
  
  Future<String?> _getDownloadedPath(String url) async {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'ep_${url.hashCode}.mp3';
      final path = '${directory.path}/downloads/$filename';
      if (await File(path).exists()) {
          return path;
      }
      return null;
  }
  
  Future<void> _prepPlayer(String url, {Duration? initialPosition}) async {
      Log.d('AudioHandler', "_prepPlayer loading $url");
      try {
        if (url.startsWith('/')) {
             await _player.setFilePath(url, initialPosition: initialPosition);
        } else {
             await _player.setUrl(url, initialPosition: initialPosition);
        }
    } catch (e, stack) {
        Log.e('AudioHandler', "Error loading audio source", e, stack);
        // Attempt recovery or stop?
        // If we fail to load, we shouldn't crash, but maybe specific UI feedback is needed?
        // For now, ensuring we don't throw up the stack is good.
    }
  }
  
  // Expose the underlying player for advanced usage if absolutely necessary, 
  // but preferably keep logic encapsulated here or via mapped streams.
  AudioPlayer get internalPlayer => _player;

  /// Transform JustAudio state events into AudioService state events
  void _broadcastState(PlaybackEvent event) {
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
        MediaAction.fastForward, // Added
        MediaAction.rewind, // Added
        MediaAction.playFromMediaId, // IMPORTANT for CarPlay selection
        MediaAction.playPause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: queueIndex >= 0 ? queueIndex : null,
    ));
    
    // Save state if paused or stopped
    // We can also save periodically if needed, but this covers 'resuming later' mostly.
    if (!playing || _player.processingState == ProcessingState.completed) {
         _saveLastState(mediaItem.value, _player.position);
    }
  }

  Future<void> _saveQueue(List<MediaItem> items) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final queueJson = items.map((item) => {
              'id': item.id,
              'title': item.title,
              'album': item.album,
              'artist': item.artist,
              'artUri': item.artUri.toString(),
              'duration': item.duration?.inMilliseconds,
              'extras': item.extras,
              'playable': item.playable,
          }).toList();
          await prefs.setString('audio_queue', json.encode(queueJson));
          Log.d('AudioHandler', "Queue explicitly saved to storage (${items.length} items)");
      } catch (e) {
          Log.e('AudioHandler', "Error explicitly saving queue: $e");
      }
  }
}
