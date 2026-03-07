import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:watch_connectivity/watch_connectivity.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/download_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/podcast_provider.dart';
import '../services/audio_handler.dart';
import '../services/log_service.dart';

class WatchService {
  final _watch = WatchConnectivity();

  DownloadProvider? _downloadProvider;
  // ignore: unused_field — set via setPodcastProvider(), used for future on-demand episode resolution
  PodcastProvider? _podcastProvider;
  
  String? _lastContextJson;
  String? _lastLibraryJson;
  
  /// Merged application context — both queue and playback share this
  /// so one doesn't overwrite the other.
  final Map<String, dynamic> _currentContext = {};

  WatchService() {
    _init();
  }

  void _init() {
     if (!kIsWeb && (Platform.isIOS)) {
        // WatchConnectivity only works on iOS
        _watch.messageStream.listen(_handleMessage);
     }
  }

  Future<void> syncQueue({
    required List<MediaItem> queue,
    required DownloadProvider downloadProvider,
    required SettingsProvider settings,
    double speed = 1.0,
    bool skipSilence = false,
  }) async {
    _downloadProvider = downloadProvider;

    if (!settings.autoSyncToWatch) return;
    if (!Platform.isIOS) return;

    try {
      final isSupported = await _watch.isSupported;
      if (!isSupported) return;
      
      final isPaired = await _watch.isPaired;
      if (!isPaired) return;

      // Sync specific number of items for DOWNLOAD, but mirror ALL metadata
      // Actually, let's mirror a reasonable amount of metadata (e.g. 50) to keep context small
      final metadataLimit = 50;
      final downloadLimit = settings.watchSyncCount;
      
      final itemsToSync = queue.take(metadataLimit).toList();
      
      final List<Map<String, dynamic>> contextQueue = [];
      
      Log.d('WatchService', 'Syncing metadata for ${itemsToSync.length} items (Auto-download top $downloadLimit)...');

      for (int i = 0; i < itemsToSync.length; i++) {
         final item = itemsToSync[i];
         final shouldAutoDownload = i < downloadLimit;
         
         final url = item.extras?['url'] as String?;
         bool isDownloadedOnPhone = false;
         
         if (url != null) {
             isDownloadedOnPhone = await downloadProvider.isDownloaded(url);
         }

         // 1. Prepare Metadata
         // We add checks so UI on watch knows availability
         contextQueue.add({
             'id': item.id,
             'title': item.title,
             'album': item.album,
             'artist': item.artist,
             'duration': item.duration?.inSeconds ?? 0,
             'position': item.extras?['position_seconds'] ?? 0, // A5: include playback position
             'url': url,
             'artUri': item.artUri?.toString(),
             'isAvailableOnPhone': isDownloadedOnPhone,
             'autoDownload': shouldAutoDownload,
             // Include chapters if available in extras
             if (item.extras?['chapters'] != null)
               'chapters': item.extras!['chapters'],
         });
      }

      // 3. Update Application Context — merge into shared context
      _currentContext['queue'] = contextQueue;
      _currentContext['speed'] = speed;
      _currentContext['skipSilence'] = skipSilence;
      _currentContext['wifiOnly'] = settings.watchDownloadWiFiOnly;
      
      final jsonStr = json.encode(_currentContext);
      if (jsonStr == _lastContextJson) {
          Log.d('WatchService', 'Skipping sync (context unchanged)');
          return;
      }
      
      await _watch.updateApplicationContext(_currentContext);
      _lastContextJson = jsonStr;
      Log.d('WatchService', 'Application Context updated');
      
    } catch (e) {
      if (e.toString().contains('Watch app is not installed')) {
         Log.d('WatchService', 'Sync skipped (Watch app not installed)');
      } else {
         Log.e('WatchService', 'Sync failed: $e');
      }
    }
  }
  


  // Sync Playback State (Title, Artist, Playing Status)
  Future<void> updatePlaybackState({
    required MediaItem? mediaItem,
    required bool isPlaying,
  }) async {
      if (!Platform.isIOS) return;
      
      try {
          final isSupported = await _watch.isSupported;
          if (!isSupported) return;
          
          final isPaired = await _watch.isPaired;
          if (!isPaired) return;

          // Note: isReachable is flaky on simulators, but checking it or just catching the specific error is safer.
          // We will rely on try-catch to keep it robust against "Watch App Not Installed".

           // Merge playback_info into shared context so it doesn't overwrite queue
           _currentContext['playback_info'] = {
               'title': mediaItem?.title ?? 'Not Playing',
               'artist': mediaItem?.artist ?? '',
               'isPlaying': isPlaying,
               'episodeId': mediaItem?.id,
           };
           await _watch.updateApplicationContext(_currentContext);
      } catch (e) {
          // Suppress redundant logs for "Watch app is not installed" to avoid noise/crashes
          if (e.toString().contains('Watch app is not installed')) {
             Log.d('WatchService', 'Skipping update (Watch app not installed)');
          } else {
             Log.e('WatchService', 'Failed to update playback state: $e');
          }
      }
  }

  // Listen for commands from Watch
  void listenForCommands(PodcastAudioHandler audioHandler) {
      if (!Platform.isIOS) return;
      // We listen in init, but here we can bind the audioHandler if we want strict coupling,
      // or just use a shared reference. 
      // Current design: listenForCommands is called by PlayerProvider which passes the handler.
      // We'll reset the listener or use a closure.
      
      _audioHandler = audioHandler;
  }
  
  PodcastAudioHandler? _audioHandler;
  
  void _handleMessage(Map<String, dynamic> message) {
      final command = message['command'];
      Log.d('WatchService', 'Received command $command');
      
      switch (command) {
          case 'play':
              _audioHandler?.play();
              break;
          case 'pause':
              _audioHandler?.pause();
              break;
          case 'skipForward':
              final current = _audioHandler?.playbackState.value.position ?? Duration.zero;
              _audioHandler?.seek(current + const Duration(seconds: 30));
              break;
          case 'skipBackward':
              final current = _audioHandler?.playbackState.value.position ?? Duration.zero;
              // Ensure we don't seek before 0
              final newPos = current - const Duration(seconds: 15);
              _audioHandler?.seek(newPos < Duration.zero ? Duration.zero : newPos);
              break;
          case 'request_download':
              final episodeId = message['episodeId'] as String?;
              if (episodeId != null) {
                  Log.d('WatchService', 'Received manual download request for $episodeId');
                  _handleManualDownloadRequest(episodeId);
              }
              break;
          case 'remove_from_queue':
              final episodeId = message['episodeId'] as String?;
              if (episodeId != null) {
                  Log.d('WatchService', 'Received remove_from_queue for $episodeId');
                  _onCustomCommand?.call('remove_from_queue', {'episodeId': episodeId});
              }
              break;
          case 'mark_as_played':
              final episodeId = message['episodeId'] as String?;
              if (episodeId != null) {
                  Log.d('WatchService', 'Received mark_as_played for $episodeId');
                  _onCustomCommand?.call('mark_as_played', {'episodeId': episodeId});
              }
              break;
          case 'refresh_queue':
              Log.d('WatchService', 'Received refresh_queue from watch background refresh');
              _onCustomCommand?.call('refresh_queue', {});
              break;
          case 'playQueue':
              Log.d('WatchService', 'Received playQueue from watch');
              _audioHandler?.play();
              break;
          case 'playLatest':
              final podcastName = message['podcastName'] as String?;
              Log.d('WatchService', 'Received playLatest from watch: $podcastName');
              if (podcastName != null) {
                  _onCustomCommand?.call('playLatest', {'podcastName': podcastName});
              }
              break;
          case 'update_progress':
               // Received progress update from Watch (offline playback)
               final episodeId = message['episodeId'] as String?;
               final position = message['position'] as int?;
               if (episodeId != null && position != null) {
                   Log.d('WatchService', 'Received update_progress for $episodeId: $position');
                   _onCustomCommand?.call('update_progress', {
                       'episodeId': episodeId, 
                       'position': position,
                   });
               }
               break;
           case 'request_library':
               Log.d('WatchService', 'Received request_library from watch');
               _onCustomCommand?.call('request_library', {});
               break;
           case 'request_episodes':
               final feedUrl = message['feedUrl'] as String?;
               if (feedUrl != null) {
                   Log.d('WatchService', 'Received request_episodes for $feedUrl');
                   _onCustomCommand?.call('request_episodes', {'feedUrl': feedUrl});
               }
               break;
      }
  }

  Function(String command, Map<String, dynamic> args)? _onCustomCommand;

  void setCustomCommandHandler(Function(String, Map<String, dynamic>) handler) {
      _onCustomCommand = handler;
  }
  
  Future<void> _handleManualDownloadRequest(String episodeId) async {
       if (_downloadProvider == null) return;
       
       // Episode downloads now happen directly on the watch via WatchDownloadManager.
       // This message is a legacy path — the watch should use its own downloadOnWatch().
       // We just log and acknowledge.
       Log.d('WatchService', 'Manual download request for $episodeId — watch should use direct download');
  }

  void setPodcastProvider(PodcastProvider provider) {
      _podcastProvider = provider;
  }

  /// Sync the podcast library (subscriptions) to the watch.
  /// Sends a compact payload with top-3 episodes per podcast.
  Future<void> syncLibrary(List<dynamic> subscriptions) async {
      if (!Platform.isIOS) return;

      try {
          final isSupported = await _watch.isSupported;
          if (!isSupported) return;

          final isPaired = await _watch.isPaired;
          if (!isPaired) return;

          final List<Map<String, dynamic>> libraryData = [];
          for (final podcast in subscriptions) {
              libraryData.add({
                  'title': podcast.title,
                  'feedUrl': podcast.url,
                  'artUri': podcast.logoUrl,
                  'author': podcast.author ?? '',
              });
          }

          final jsonStr = json.encode(libraryData);
          if (jsonStr == _lastLibraryJson) {
              Log.d('WatchService', 'Skipping library sync (unchanged)');
              return;
          }

          await _watch.sendMessage({
              'library': libraryData,
          });
          _lastLibraryJson = jsonStr;
          Log.d('WatchService', 'Library synced: ${libraryData.length} podcasts');
      } catch (e) {
          if (e.toString().contains('Watch app is not installed')) {
              Log.d('WatchService', 'Library sync skipped (Watch app not installed)');
          } else {
              Log.e('WatchService', 'Library sync failed: $e');
          }
      }
  }

  /// Send episodes for a specific podcast feed to the watch.
  Future<void> sendEpisodesToWatch(String feedUrl, List<Map<String, dynamic>> episodes) async {
      if (!Platform.isIOS) return;

      try {
          final isSupported = await _watch.isSupported;
          if (!isSupported) return;

          await _watch.sendMessage({
              'episodes_for_feed': {
                  'feedUrl': feedUrl,
                  'episodes': episodes,
              },
          });
          Log.d('WatchService', 'Sent ${episodes.length} episodes for $feedUrl to watch');
      } catch (e) {
          Log.e('WatchService', 'Failed to send episodes to watch: $e');
      }
  }
}
