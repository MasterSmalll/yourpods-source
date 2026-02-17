import '../api/gpodder_api.dart'; // For EpisodeAction
import 'podcast.dart';

enum SyncStrategy {
  serverWins,
  deviceWins,
  ask,
}

class SyncConflict {
  final String episodeGuid;
  final String podcastUrl;
  final EpisodeAction? localAction;
  final EpisodeAction? remoteAction;
  
  // Helper for UI
  final Podcast? podcast; 
  final String? episodeTitle;
  final String? podcastTitle;

  SyncConflict({
    required this.episodeGuid,
    required this.podcastUrl,
    this.localAction,
    this.remoteAction,
    this.podcast,
    this.episodeTitle,
    this.podcastTitle,
  });
  
  // Logic to determine if it's actually a conflict worth showing
  bool get isSignificant {
    if (localAction == null || remoteAction == null) return false;
    // Difference > 60 seconds
    final diff = (localAction!.position! - remoteAction!.position!).abs();
    return diff > 60;
  }
}
