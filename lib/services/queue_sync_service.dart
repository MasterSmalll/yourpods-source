import 'package:audio_service/audio_service.dart';
import '../api/gpodder_api.dart';
import '../models/podcast.dart';
import '../models/queue_sync_change.dart';
import '../utils/safe_int.dart';

/// Pure logic class that computes queue changes from server episode actions.
/// No Flutter dependencies — fully testable.
class QueueSyncService {
  /// Compare server episode actions against the local queue and produce
  /// a list of proposed changes.
  ///
  /// - [localQueue]: current on-device queue items
  /// - [actionMap]: guid → EpisodeAction from the server (via PodcastProvider)
  /// - [subscriptions]: list of subscribed podcasts for metadata lookup
  static List<QueueSyncChange> computeChanges({
    required List<MediaItem> localQueue,
    required Map<String, EpisodeAction> actionMap,
    required List<Podcast> subscriptions,
  }) {
    final changes = <QueueSyncChange>[];
    final localGuids = localQueue.map((i) => i.id).toSet();
    final processedGuids = <String>{}; // Track to avoid duplicate proposals

    // Build a quick podcast lookup by URL
    final podcastByUrl = <String, Podcast>{};
    for (final p in subscriptions) {
      podcastByUrl[p.url] = p;
    }

    // 1. ADD: in-progress on server but absent from local queue
    for (final entry in actionMap.entries) {
      final guid = entry.key;
      final action = entry.value;

      if (localGuids.contains(guid)) continue; // already in queue
      if (!processedGuids.add(guid)) continue; // already proposed

      // Only consider truly in-progress episodes
      if (!_isInProgress(action)) continue;

      final podcast = podcastByUrl[action.podcast];

      changes.add(QueueSyncChange(
        type: QueueSyncChangeType.add,
        episodeGuid: guid,
        podcastUrl: action.podcast,
        podcastTitle: podcast?.title,
        audioUrl: action.podcast, // will be resolved later from RSS
        serverPosition: action.position,
        totalDuration: action.total,
        serverTimestamp: action.timestamp,
      ));
    }

    // 2. REMOVE: in local queue but completed on server
    // 3. UPDATE: in local queue with significantly different position on server
    for (final item in localQueue) {
      final action = actionMap[item.id];
      if (action == null) continue;

      final localPos = safeInt(item.extras?['position_seconds']);
      final serverPos = action.position ?? 0;
      final total = action.total ?? item.duration?.inSeconds ?? 0;
      final podcastUrl = item.extras?['podcastUrl'] as String? ?? action.podcast;
      final podcast = podcastByUrl[podcastUrl];

      if (_isCompleted(action)) {
        // Episode completed on server — propose removal
        changes.add(QueueSyncChange(
          type: QueueSyncChangeType.remove,
          episodeGuid: item.id,
          podcastUrl: podcastUrl,
          episodeTitle: item.title,
          podcastTitle: podcast?.title ?? item.album,
          imageUrl: item.artUri?.toString(),
          serverPosition: serverPos,
          localPosition: localPos,
          totalDuration: total,
          serverTimestamp: action.timestamp,
        ));
      } else if ((serverPos - localPos).abs() > 30) {
        // Significant position difference — propose update
        changes.add(QueueSyncChange(
          type: QueueSyncChangeType.update,
          episodeGuid: item.id,
          podcastUrl: podcastUrl,
          episodeTitle: item.title,
          podcastTitle: podcast?.title ?? item.album,
          imageUrl: item.artUri?.toString(),
          serverPosition: serverPos,
          localPosition: localPos,
          totalDuration: total,
          serverTimestamp: action.timestamp,
        ));
      }
    }

    // Sort by most recently interacted first
    changes.sort((a, b) => b.serverTimestamp.compareTo(a.serverTimestamp));

    return changes;
  }

  /// An episode is "in progress" if position is between 1 and (total - 5).
  static bool _isInProgress(EpisodeAction action) {
    final pos = action.position ?? 0;
    final total = action.total ?? 0;
    if (pos <= 0) return false;
    if (total <= 0) return pos > 0; // no total info but has position
    return pos < (total - 5);
  }

  /// An episode is "completed" if position is at or near total.
  static bool _isCompleted(EpisodeAction action) {
    final pos = action.position ?? 0;
    final total = action.total ?? 0;
    if (total <= 0) return false;
    return pos >= (total - 5);
  }
}
