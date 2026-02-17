import 'package:audio_service/audio_service.dart';
import '../models/podcast.dart';

class MediaItemBuilder {
  static MediaItem fromEpisode(
    Podcast? podcast, 
    Episode episode, {
    Map<String, dynamic>? extras,
    Duration? duration,
    String? artUri,
  }) {
    // Prefer passed extras, then merge defaults if needed
    final finalExtras = Map<String, dynamic>.from(extras ?? {});
    
    // Ensure standard keys are present if not overridden
    if (!finalExtras.containsKey('url') && episode.audioUrl != null) {
      finalExtras['url'] = episode.audioUrl;
    }
    if (!finalExtras.containsKey('podcastUrl') && podcast?.url != null) {
      finalExtras['podcastUrl'] = podcast!.url;
    }

    // Use podcast title if album is missing
    final album = podcast?.title ?? '';

    // Art URI priority: passed arg -> episode image -> podcast logo
    Uri? finalArtUri;
    if (artUri != null) {
        finalArtUri = Uri.tryParse(artUri);
    } else if (episode.imageUrl != null) {
        finalArtUri = Uri.tryParse(episode.imageUrl!);
    } else if (podcast?.logoUrl != null) {
        finalArtUri = Uri.tryParse(podcast!.logoUrl!);
    }

    return MediaItem(
      id: episode.guid,
      album: album,
      title: episode.title,
      artist: '', // Podcast author could go here if available in model
      duration: duration ?? episode.duration,
      artUri: finalArtUri,
      extras: finalExtras,
    );
  }
}
