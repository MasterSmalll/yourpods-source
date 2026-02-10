import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:watch_connectivity/watch_connectivity.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/download_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_handler.dart';
import '../services/log_service.dart';

class WatchService {
  final _watch = WatchConnectivity();
  
  // Cache of sent episode IDs to avoid re-transferring same session
  final Set<String> _sentEpisodeIds = {};
  
  // Track items currently transferring to avoid duplicates
  final Set<String> _transferringIds = {};

  SettingsProvider? _settings;
  DownloadProvider? _downloadProvider;

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
  }) async {
    _settings = settings;
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
             'url': url,
             'artUri': item.artUri?.toString(),
             'isAvailableOnPhone': isDownloadedOnPhone,
             // Include chapters if available in extras
             if (item.extras?['chapters'] != null)
               'chapters': item.extras!['chapters'],
         });

         // 2. Transfer File if needed (and valid)
         if (shouldAutoDownload && isDownloadedOnPhone && url != null) {
             _transferFileIfNeeded(item.id, url, downloadProvider);
         }
      }

      // 3. Update Application Context
      await _watch.updateApplicationContext({'queue': contextQueue});
      Log.d('WatchService', 'Application Context updated');
      
    } catch (e) {
      if (e.toString().contains('Watch app is not installed')) {
         Log.d('WatchService', 'Sync skipped (Watch app not installed)');
      } else {
         Log.e('WatchService', 'Sync failed: $e');
      }
    }
  }
  
  Future<void> _transferFileIfNeeded(String id, String url, DownloadProvider downloadProvider) async {
       // functionality not available in watch_connectivity 0.2.6
       Log.w('WatchService', 'File transfer not supported in this version of watch_connectivity');
       /*
       if (_sentEpisodeIds.contains(id) || _transferringIds.contains(id)) return;
       
       final path = await downloadProvider.getDownloadedPath(url);
       if (path != null) {
           final file = File(path);
           if (await file.exists()) {
               Log.d('WatchService', 'Transferring file for episode $id');
               _transferringIds.add(id);
               
               // Transfer file with metadata so watch knows which episode it is
               _watch.transferFile(file, metadata: {
                   'id': id,
                   'url': url, // Key used to match streamUrl in watch
               }).then((_) {
                   Log.d('WatchService', 'Transfer initiated for $id');
                   _sentEpisodeIds.add(id);
                   _transferringIds.remove(id);
               }).catchError((e) {
                   Log.e('WatchService', 'Transfer failed for $id: $e');
                   _transferringIds.remove(id);
               });
           }
       }
       */
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

          final context = {
              'playback_info': {
                  'title': mediaItem?.title ?? 'Not Playing',
                  'artist': mediaItem?.artist ?? '',
                  'isPlaying': isPlaying,
              }
          };
          await _watch.updateApplicationContext(context);
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
      }
  }

  Function(String command, Map<String, dynamic> args)? _onCustomCommand;

  void setCustomCommandHandler(Function(String, Map<String, dynamic>) handler) {
      _onCustomCommand = handler;
  }
  
  Future<void> _handleManualDownloadRequest(String episodeId) async {
       if (_downloadProvider == null) return; // Can't do anything without provider
       
       // We need to find the item in current queue (or elsewhere) to get its URL
       // For now, assume it's in the queue since that's what we synced
       final queue = _audioHandler?.queue.value ?? [];
       final item = queue.where((i) => i.id == episodeId).firstOrNull;
       
       if (item != null) {
           final url = item.extras?['url'] as String?;
           if (url != null) {
               // Verify it is downloaded
               final isDownloaded = await _downloadProvider!.isDownloaded(url);
               if (isDownloaded) {
                   await _transferFileIfNeeded(episodeId, url, _downloadProvider!);
               } else {
                   Log.w('WatchService', 'Requested episode $episodeId is not downloaded on phone.');
                   // Optionally trigger download on phone? For now, just ignore or log.
               }
           }
       }
  }
}
