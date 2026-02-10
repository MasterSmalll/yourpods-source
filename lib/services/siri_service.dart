
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/podcast_provider.dart';
import '../services/audio_handler.dart';

import '../services/log_service.dart';

class SiriService {
  static final SiriService _instance = SiriService._internal();
  factory SiriService() => _instance;
  SiriService._internal();

  static const MethodChannel _channel = MethodChannel('com.asecretcompany.yourpods/siri');

  BuildContext? _context;
  PodcastAudioHandler? _audioHandler;

  void setAudioHandler(PodcastAudioHandler handler) {
    _audioHandler = handler;
  }

  void init(BuildContext context) {
    _context = context;
    _channel.setMethodCallHandler(_handleMethodCall);
    Log.i("SiriService", "Initialized and listening");
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    Log.d("SiriService", "Received method call ${call.method}");
    
    switch (call.method) {
      case 'playMedia':
        final String query = call.arguments as String;
        await _handlePlayMedia(query);
        break;
      default:
        throw MissingPluginException();
    }
  }

  Future<void> _handlePlayMedia(String query) async {
    if (_context == null || _audioHandler == null) {
      Log.e("SiriService", "Error - Context or AudioHandler not available");
      return;
    }

    Log.d("SiriService", "Searching for podcast matching '$query'");

    try {
      final provider = Provider.of<PodcastProvider>(_context!, listen: false);
      final subscriptions = provider.subscriptions;

      // 1. Find Podcast
      final normalizedQuery = query.toLowerCase();
      final matchingPodcast = subscriptions.cast<dynamic>().firstWhere(
            (p) => p.title.toLowerCase().contains(normalizedQuery),
            orElse: () => null,
      );

      if (matchingPodcast == null) {
        Log.i("SiriService", "No podcast found for '$query'");
        return;
      }

      Log.i("SiriService", "Found podcast '${matchingPodcast.title}'");

      // 2. Fetch/Get Episodes
      // Use ignoreCacheAge: false to use cache if available quickly
      final episodes = await provider.fetchEpisodes(matchingPodcast.url);

      if (episodes.isEmpty) {
        Log.w("SiriService", "No episodes found for podcast");
        return;
      }

      // 3. Pick latest episode
      // Assuming episodes are sorted by date desc
      final latestEpisode = episodes.first;
      
      Log.i("SiriService", "Playing latest episode '${latestEpisode.title}'");

      // 4. Play
      final mediaItem = MediaItem(
          id: latestEpisode.guid,
          album: matchingPodcast.title,
          title: latestEpisode.title,
          artist: '',
          artUri: latestEpisode.imageUrl != null || matchingPodcast.logoUrl != null
              ? Uri.parse(latestEpisode.imageUrl ?? matchingPodcast.logoUrl!)
              : null,
          duration: latestEpisode.duration,
          extras: {'url': latestEpisode.audioUrl},
      );
      
      // Stop current playback and play this
      await _audioHandler!.stop();
      await _audioHandler!.playMediaItem(mediaItem);
      
    } catch (e) {
      Log.e("SiriService", "Error handling PlayMedia: $e");
    }
  }
}
