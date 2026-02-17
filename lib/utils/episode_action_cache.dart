import '../api/gpodder_api.dart';
import '../services/log_service.dart';

/// Caches episode actions from the gPodder API with a configurable TTL
/// to avoid redundant HTTP calls during rapid UI interactions.
class EpisodeActionCache {
  Map<String, EpisodeAction>? _cache;
  DateTime _lastFetch = DateTime(0);
  final Duration ttl;

  EpisodeActionCache({this.ttl = const Duration(seconds: 30)});

  /// Returns cached actions if fresh, otherwise fetches from API.
  Future<Map<String, EpisodeAction>> getLatestActions(
    GPodderApi api, 
    String deviceId, {
    int since = 0,
  }) async {
    if (_cache != null && DateTime.now().difference(_lastFetch) < ttl) {
      Log.d('EpisodeActionCache', 'Cache hit (${_cache!.length} actions)');
      return _cache!;
    }

    Log.d('EpisodeActionCache', 'Cache miss, fetching from API...');
    final actions = await api.getEpisodeActions(deviceId, since: since);
    
    final Map<String, EpisodeAction> latestActions = {};
    for (var action in actions) {
      // Keep only the latest action per episode
      final existing = latestActions[action.episode];
      if (existing == null || action.timestamp > existing.timestamp) {
        latestActions[action.episode] = action;
      }
    }
    
    _cache = latestActions;
    _lastFetch = DateTime.now();
    return _cache!;
  }

  /// Invalidates the cache, forcing a fresh fetch on next access.
  void invalidate() {
    _cache = null;
    _lastFetch = DateTime(0);
  }

  /// Returns true if the cache is currently valid (not expired).
  bool get isFresh => 
      _cache != null && DateTime.now().difference(_lastFetch) < ttl;
}
