import 'package:audio_service/audio_service.dart';
import '../models/podcast.dart';

class MediaItemBuilder {
  /// Build a [MediaItem] from a [Podcast] and [Episode] with consistent extras.
  ///
  /// All queue, play-next, and add-to-queue code paths MUST use this method
  /// to guarantee that every MediaItem has the extras that auto-advance and
  /// pre-buffering depend on (especially `url`).
  static MediaItem fromEpisode(
    Podcast? podcast, 
    Episode episode, {
    Map<String, dynamic>? extras,
    Duration? duration,
    String? artUri,
    int? positionSeconds,
  }) {
    // Start with caller-provided extras, then fill in standard keys
    final finalExtras = Map<String, dynamic>.from(extras ?? {});
    
    // Ensure standard keys are present if not overridden
    if (!finalExtras.containsKey('url') && episode.audioUrl != null) {
      finalExtras['url'] = episode.audioUrl;
    }
    if (!finalExtras.containsKey('podcastUrl') && podcast?.url != null) {
      finalExtras['podcastUrl'] = podcast!.url;
    }
    if (!finalExtras.containsKey('pubDate') && episode.pubDate != null) {
      finalExtras['pubDate'] = episode.pubDate!.toIso8601String();
    }
    if (!finalExtras.containsKey('chaptersUrl') && episode.chaptersUrl != null) {
      finalExtras['chaptersUrl'] = episode.chaptersUrl;
    }
    if (!finalExtras.containsKey('transcriptUrl') && episode.transcriptUrl != null) {
      finalExtras['transcriptUrl'] = episode.transcriptUrl;
    }
    if (positionSeconds != null && !finalExtras.containsKey('position_seconds')) {
      finalExtras['position_seconds'] = positionSeconds;
    }
    if (!finalExtras.containsKey('chapters') && 
        episode.chapters != null && 
        episode.chapters!.isNotEmpty) {
      finalExtras['chapters'] = episode.chapters!.map((c) => c.toJson()).toList();
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
      artist: podcast?.author ?? '',
      duration: duration ?? episode.duration,
      artUri: finalArtUri,
      extras: finalExtras,
    );
  }
}
