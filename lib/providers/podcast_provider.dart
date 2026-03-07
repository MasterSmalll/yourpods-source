import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../api/gpodder_api.dart';
import '../api/rss_service.dart';
import '../models/podcast.dart';
import '../services/opml_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'settings_provider.dart';
import '../services/log_service.dart';
import '../models/sync_conflict.dart';

class PodcastProvider with ChangeNotifier {
  List<Podcast> _subscriptions = [];
  bool _isLoading = false;
  String? _error;

  List<Podcast> get subscriptions => _subscriptions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  
  int _lastSyncTimestamp = 0;
  DateTime? _lastSyncedAt;
  
  // Episode Action Cache
  List<EpisodeAction> _cachedEpisodeActions = [];
  int _lastActionsFetchTime = 0;
  static const int _actionsCacheDuration = 300; // 5 minutes fresh
  final Map<String, EpisodeAction> _actionMap = {}; // Quick lookup by episode URL (or GUID for legacy entries)
  final Map<String, String> _guidToEpisodeUrl = {}; // Reverse map: GUID -> episode URL for dual-key lookup
  Map<String, EpisodeAction> get actionMap => Map.unmodifiable(_actionMap);

  // B4: Cached documents directory
  Directory? _docsDir;
  Future<Directory> get _documentsDir async {
    _docsDir ??= await getApplicationDocumentsDirectory();
    return _docsDir!;
  }

  // C2: Cached UUID v5 computations
  final Map<String, String> _uuidCache = {};
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );
  
  // Filter States
  final Set<String> _podcastsWithUnplayed = {};
  final Set<String> _podcastsWithDownloads = {};
  final Set<String> _podcastsWithInProgress = {};

  // In-Memory Cache for Episodes (LRU-like via LinkedHashMap implicitly if we manage order, or just simple Map for now)
  // We'll limit the size to avoid memory bloat.
  final Map<String, List<Episode>> _memoryEpisodeCache = {};
  final List<String> _memoryCacheKeys = [];
  static const int _maxMemoryCacheSize = 10; // Keep top 10 podcasts in memory

  bool hasUnplayed(String url) => _podcastsWithUnplayed.contains(url);
  bool hasDownloads(String url) => _podcastsWithDownloads.contains(url);
  bool hasInProgress(String url) => _podcastsWithInProgress.contains(url);
  
  // Public accessor for cached episodes (Read-through)
  Future<List<Episode>> getEpisodes(String podcastUrl, {bool forceRefresh = false}) async {
    // 1. Check Memory Cache
    if (!forceRefresh && _memoryEpisodeCache.containsKey(podcastUrl)) {
        // Move to end (most recently used)
        _memoryCacheKeys.remove(podcastUrl);
        _memoryCacheKeys.add(podcastUrl);
        return _memoryEpisodeCache[podcastUrl]!;
    }
    
    // 2. Check File Cache (via existing logic)
    // We reuse fetchEpisodes which checks file cache, but we want to populate memory cache too.
    final episodes = await fetchEpisodes(podcastUrl, forceRefresh: forceRefresh);
    
    return episodes; // fetchEpisodes updates memory cache now
  }

  /// Synchronous lookup of an episode in the memory cache.
  /// Returns null if the podcast or episode is not cached in memory.
  Episode? findEpisodeInCache(String podcastUrl, String guid) {
    final episodes = _memoryEpisodeCache[podcastUrl];
    if (episodes == null) return null;
    for (final ep in episodes) {
      if (ep.guid == guid) return ep;
    }
    return null;
  }

  GPodderApi? _api;
  final _rssService = RssService();
  String? _currentProfileId;
  SettingsProvider? _settings;

  String? get currentProfileId => _currentProfileId;
  GPodderApi? get api => _api;
  
  void updateSettings(SettingsProvider settings) {
      _settings = settings;
  }
  
  PodcastProvider() {
      _init();
  }
  
  Future<void> _init() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final storedId = prefs.getString('current_profile_id');
          if (storedId != null && _currentProfileId == null) {
              _currentProfileId = storedId;
              await _loadSubscriptions();
              await _loadSyncTimestamp(); 
              await _loadAutoQueueSettings();
              await _loadGroups();
              await _loadGroups();
              await _loadActionCache(); // Load persisted actions
              // Prefetch/warm up actions cache
              syncEpisodeActions(_currentProfileId!, force: false).catchError((e) { Log.e('PodcastProvider', 'Initial actions sync failed', e); return <SyncConflict>[]; });
              notifyListeners();
          }
      } catch (e) {
          Log.e('PodcastProvider', 'init failed: $e');
      }
  }

  void setApi(GPodderApi? api, String profileId) async {
  if (_currentProfileId == profileId && _api != null) {
      return;
  }
  
  Log.i('PodcastProvider', 'Switching to profile: $profileId (from $_currentProfileId)');
  
  // Clear memory caches so data doesn't leak between profiles
  _subscriptions = [];
  _groups = {};
  _autoQueuePodcastUrls.clear();
  _autoQueuePriorityUrls.clear();
  _actionMap.clear();
  _guidToEpisodeUrl.clear();
  _cachedEpisodeActions = [];
  _memoryEpisodeCache.clear();
  _memoryCacheKeys.clear();
  _lastSyncTimestamp = 0;
  
  // For local profiles, api might be null, but we still set profileId
  _api = api;
  _currentProfileId = profileId;
  
  // Load local data for the new profile
  _loadSubscriptions();
  _loadSyncTimestamp(); 
  await _loadAutoQueueSettings();
  _loadGroups();
  
  // Explicitly wait for action cache to load before doing subsequent sync operations
  // This ensures a clean slate before PlayerProvider tries to read actions
  await _loadActionCache();
  
  // Run one-time migration to fix GUID-based episode fields (fire-and-forget)
  _migrateEpisodeUrls().catchError((e) { Log.e('PodcastProvider', 'Episode URL migration failed: $e'); });
  
  syncEpisodeActions(profileId, force: true);
  notifyListeners();
}

  // Action Persistence
  Future<File> get _actionsFile async {
    final directory = await _documentsDir;
    final safeId = _currentProfileId?.replaceAll(RegExp(r'[^\w]'), '_') ?? 'default';
    return File('${directory.path}/actions_$safeId.json');
  }

  Future<void> _loadActionCache() async {
    try {
        final file = await _actionsFile;
        if (await file.exists()) {
            final jsonString = await file.readAsString();
            final List<dynamic> jsonList = json.decode(jsonString);
            _cachedEpisodeActions = jsonList.map((j) => EpisodeAction.fromJson(j)).toList();
            
            _actionMap.clear();
            for (var action in _cachedEpisodeActions) {
                _actionMap[action.episode] = action;
            }
            _rebuildGuidToUrlMap();
            notifyListeners();
        } else {
            // CRITICAL: if no file exists for this profile, ensure memory state is empty
            _cachedEpisodeActions = [];
            _actionMap.clear();
            _guidToEpisodeUrl.clear();
        }
    } catch (e) {
        Log.e('PodcastProvider', 'Error loading action cache: $e');
        _cachedEpisodeActions = [];
        _actionMap.clear();
        _guidToEpisodeUrl.clear();
    }
  }

  /// Rebuild the GUID -> episode URL reverse map from _actionMap.
  /// Called whenever _actionMap is fully rebuilt (load, sync).
  void _rebuildGuidToUrlMap() {
      _guidToEpisodeUrl.clear();
      for (var action in _actionMap.values) {
          if (action.guid != null && action.guid != action.episode) {
              _guidToEpisodeUrl[action.guid!] = action.episode;
          }
      }
  }

  /// One-time migration: re-upload cached episode actions that have a GUID
  /// as the `episode` field instead of the audio URL.
  /// This fixes compatibility with Repod and other gPodder clients.
  Future<void> _migrateEpisodeUrls() async {
      final prefs = await SharedPreferences.getInstance();
      final key = 'episode_url_migration_done_$_currentProfileId';
      if (prefs.getBool(key) == true) return;
      if (_api == null) return; // Only migrate for synced profiles
      
      final toMigrate = <EpisodeAction>[];
      for (var action in _cachedEpisodeActions) {
          // Heuristic: if 'episode' doesn't contain '://', it's a GUID not a URL
          if (!action.episode.contains('://')) {
              final episodes = await _loadEpisodeCache(action.podcast);
              final match = episodes.where((e) => e.guid == action.episode).firstOrNull;
              if (match?.audioUrl != null) {
                  toMigrate.add(EpisodeAction(
                      podcast: action.podcast,
                      episode: match!.audioUrl!,
                      guid: action.guid ?? action.episode,
                      action: action.action,
                      timestamp: action.timestamp,
                      position: action.position,
                      started: action.started,
                      total: action.total,
                      device: action.device,
                  ));
              }
          }
      }
      
      if (toMigrate.isNotEmpty) {
          Log.i('PodcastProvider', 'Migrating ${toMigrate.length} episode actions from GUID to URL format');
          // Update local state
          for (var fixed in toMigrate) {
              _actionMap[fixed.episode] = fixed;
          }
          _cachedEpisodeActions = _actionMap.values.toList();
          _rebuildGuidToUrlMap();
          await _saveActionCache();
          
          // Upload to server in batches of 50
          for (var i = 0; i < toMigrate.length; i += 50) {
              final batch = toMigrate.skip(i).take(50).toList();
              try {
                  await _api!.uploadEpisodeActions(batch);
              } catch (e) {
                  Log.e('PodcastProvider', 'Migration batch upload failed: $e');
                  // Continue with next batch — partial migration is better than none
              }
          }
          Log.i('PodcastProvider', 'Episode URL migration complete');
      }
      
      await prefs.setBool(key, true);
  }

  Future<void> _saveActionCache() async {
      try {
          final file = await _actionsFile;
          final jsonString = json.encode(_cachedEpisodeActions.map((a) => a.toJson()).toList());
          await file.writeAsString(jsonString);
      } catch (e) {
          Log.e('PodcastProvider', 'Error saving action cache: $e');
      }
  }

  /// Centralized Sync for Playback State (Episode Actions)
  /// 
  /// 1. Pushes any local pending actions (if we track them later, for now we rely on immediate push)
  /// 2. Pulls latest actions from server
  /// 3. Merges with local cache
  /// 4. Persists to disk
  Future<List<SyncConflict>> syncEpisodeActions(String deviceId, {bool force = false, SyncStrategy strategy = SyncStrategy.serverWins}) async {
      // Local account support: if no API, we just ensure local consistency if needed, but no sync
      if (_api == null) return [];
      
      // Rate limit unless forced
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (!force && (now - _lastActionsFetchTime < 60)) { 
          // 1 minute default throttle for background/start if already fresh
          return []; 
      }

      final conflicts = <SyncConflict>[];

      try {
          // Load timestamp
          await _loadSyncTimestamp(); // Ensure we have latest timestamp
          
          final prefs = await SharedPreferences.getInstance();
          final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
          int lastActionSync = prefs.getInt('last_action_sync_timestamp$suffix') ?? 0;
          
          Log.d('PodcastProvider', 'Syncing actions (since: $lastActionSync)...');
          
          final remoteActions = await _api!.getEpisodeActions(deviceId, since: lastActionSync);
          
          if (remoteActions.isNotEmpty) {
              // Merge strategy: 
              // 1. Sort remote by timestamp
              remoteActions.sort((a, b) => a.timestamp.compareTo(b.timestamp));
              
              // 2. Update map
              bool changed = false;
              for (var action in remoteActions) {
                  final existing = _actionMap[action.episode];
                  
                  // Check for conflict
                  if (existing != null) {
                      final diff = (action.position! - existing.position!).abs();
                      // Only consider conflict if diff > 60s AND remote is newer (if remote is older, we ignore it anyway usually)
                      // Actually, if remote is newer but significantly different, that's a conflict. 
                      // If remote is OLDER, we just keep ours.
                      
                      if (action.timestamp > existing.timestamp && diff > 60) {
                          // Potential Conflict
                      if (strategy == SyncStrategy.ask) {
                               // Look up titles
                               String? podTitle;
                               String? epTitle;
                               
                               try {
                                   final podcast = _subscriptions.firstWhere((p) => p.url == action.podcast);
                                   podTitle = podcast.title;
                                   
                                   final episodes = await _loadEpisodeCache(action.podcast);
                                   final episode = episodes.firstWhere((e) => e.guid == action.episode, orElse: () => Episode(guid: action.episode, title: action.episode, description: '', audioUrl: '', pubDate: DateTime.now(), duration: Duration.zero));
                                   if (episode.title != action.episode) {
                                       epTitle = episode.title;
                                   }
                               } catch (e) {
                                   // ignore lookup errors
                               }

                               final conflict = SyncConflict(
                                   episodeGuid: action.episode,
                                   podcastUrl: action.podcast, 
                                   localAction: existing,
                                   remoteAction: action,
                                   podcastTitle: podTitle,
                                   episodeTitle: epTitle,
                               );
                               conflicts.add(conflict);
                               continue; // optimizing: don't update map yet
                          } else if (strategy == SyncStrategy.deviceWins) {
                              Log.i('PodcastProvider', 'Conflict: Device wins for ${action.episode}');
                              // We keep ours. But maybe we should push ours to server to settle it?
                              // For now, just don't overwrite.
                              continue;
                          }
                          // strategy == serverWins -> fall through to update
                      }
                  }

                  if (existing == null || action.timestamp > existing.timestamp) {
                      _actionMap[action.episode] = action;
                      changed = true;
                  }
              }
              
              // 3. Rebuild list and save
              if (changed) {
                  _cachedEpisodeActions = _actionMap.values.toList();
                  _rebuildGuidToUrlMap();
                  await _saveActionCache();
                  
                  // Mark played episodes as interacted so NEW badge disappears
                  final playedByPodcast = <String, List<String>>{};
                  for (var action in remoteActions) {
                      final guid = action.guid ?? action.episode;
                      if (_isEpisodePlayed(guid)) {
                          playedByPodcast.putIfAbsent(action.podcast, () => []);
                          playedByPodcast[action.podcast]!.add(guid);
                      }
                  }
                  for (var entry in playedByPodcast.entries) {
                      await markAllEpisodesAsInteracted(entry.key, entry.value);
                  }
                  
                  // Update timestamp
                  final maxTs = remoteActions.last.timestamp;
                  if (maxTs > lastActionSync) {
                      await prefs.setInt('last_action_sync_timestamp$suffix', maxTs);
                  }
                  
                  notifyListeners();
              }
              Log.i('PodcastProvider', 'Synced actions. ${conflicts.length} conflicts detected.');
          } else {
             Log.d('PodcastProvider', 'No new actions on server.');
          }
          
          _lastActionsFetchTime = now;
          _lastSyncedAt = DateTime.now();
          notifyListeners();
          
      } catch (e) {
          Log.e('PodcastProvider', 'Action sync failed: $e');
      }
      
      return conflicts;
  }

  Future<void> resolveConflicts(List<SyncConflict> resolutions) async {
       bool changed = false;
       for (var resolution in resolutions) {
           // If we chose remote (which is stored in resolution.remoteAction)
           // But how do we know which one was chosen?
           // The caller passes back a modified list? Or list of "Resolved" objects?
           // Actually, the caller should probably pass the *Actions* to keep.
           
           // Simpler: resolveConflict(SyncConflict conflict, bool keepRemote)
       }
  }
  
  Future<void> applyConflictResolution(SyncConflict conflict, bool keepRemote) async {
      if (keepRemote && conflict.remoteAction != null) {
          _actionMap[conflict.remoteAction!.episode] = conflict.remoteAction!;
          if (conflict.remoteAction!.guid != null && conflict.remoteAction!.guid != conflict.remoteAction!.episode) {
              _guidToEpisodeUrl[conflict.remoteAction!.guid!] = conflict.remoteAction!.episode;
          }
          _cachedEpisodeActions = _actionMap.values.toList();
          await _saveActionCache();
          notifyListeners();
      } else if (!keepRemote && conflict.localAction != null) {
          // Keep local. Ensure server knows about it.
          await sendEpisodeAction(conflict.localAction!);
      }
  }

  /// Get the latest known state for an episode.
  /// Supports dual-key lookup: checks direct match (GUID or URL key),
  /// then falls back to reverse map (GUID -> URL -> action).
  EpisodeAction? getLatestAction(String episodeGuid) {
      final direct = _actionMap[episodeGuid];
      if (direct != null) return direct;
      // Reverse lookup: GUID -> URL -> action
      final url = _guidToEpisodeUrl[episodeGuid];
      if (url != null) return _actionMap[url];
      return null;
  }

  /// Resolve episode and podcast titles for display in sync UI.
  /// Checks local cache first, falls back to fetching from RSS.
  /// Returns null values for titles that can't be resolved.
  Future<Map<String, String?>> resolveEpisodeInfo(String podcastUrl, String episodeGuid) async {
      String? podTitle;
      String? epTitle;

      // 1. Check subscriptions for podcast title
      try {
          final podcast = _subscriptions.firstWhere((p) => p.url == podcastUrl);
          podTitle = podcast.title;
      } catch (_) {
          // Not subscribed — will try RSS below
      }

      // 2. Check local episode cache
      final cachedEpisodes = await _loadEpisodeCache(podcastUrl);
      if (cachedEpisodes.isNotEmpty) {
          try {
              final ep = cachedEpisodes.firstWhere((e) => e.guid == episodeGuid);
              epTitle = ep.title;
          } catch (_) {}
      }

      // 3. If episode title still missing, try fetching from RSS
      if (epTitle == null) {
          try {
              final episodes = await fetchEpisodes(podcastUrl, forceRefresh: true);
              final ep = episodes.firstWhere((e) => e.guid == episodeGuid);
              epTitle = ep.title;
              
              // Bonus: if we didn't have podcast title, we might get it from RSS metadata
              // (fetchEpisodes doesn't return podcast info, but at least we tried)
          } catch (_) {
              // Feed unavailable or episode not found — title stays null
          }
      }

      return {'episodeTitle': epTitle, 'podcastTitle': podTitle};
  }

  /// Send an action (played/progress) to the server and update local cache
  Future<void> sendEpisodeAction(EpisodeAction action) async {
      // Always update local cache first (critical for local-only accounts
      // and for sync resilience when the server is unreachable)
      _actionMap[action.episode] = action;
      // Update reverse map for dual-key lookup
      if (action.guid != null && action.guid != action.episode) {
          _guidToEpisodeUrl[action.guid!] = action.episode;
      }
      _cachedEpisodeActions = _actionMap.values.toList();
      notifyListeners(); // Notify UI immediately
      _saveActionCache(); // Persist to disk before attempting upload
      
      // Upload to server if connected
      if (_api == null) return;
      try {
          await _api!.uploadEpisodeActions([action]);
      } catch (e) {
          Log.e('PodcastProvider', 'Failed to upload action: $e');
          // TODO: Queue for retry? For now, we rely on next sync or user retry.
      }
  }

  
  // Persistence Helpers
  Future<File> get _localFile async {
    final directory = await _documentsDir;
    final safeId = _currentProfileId?.replaceAll(RegExp(r'[^\w]'), '_') ?? 'default';
    return File('${directory.path}/subs_$safeId.json');
  }

  Future<void> _saveSubscriptions() async {
      try {
          final file = await _localFile;
          final jsonString = json.encode(_subscriptions.map((p) => p.toJson()).toList());
          await file.writeAsString(jsonString);
      } catch (e) {
          Log.e('PodcastProvider', 'Error saving subscriptions: $e');
      }
  }

  String _normalizeUrl(String url) {
    var normalized = url.trim();
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // Could also lowercase schema (http/HTTPS) but be careful with case sensitive paths.
    // Usually RSS URLs are case sensitive in the path but not domain. 
    // For now, removing trailing slash is the most common fix.
    return normalized;
  }

  Future<void> _loadSubscriptions() async {
      try {
          final file = await _localFile;
          if (await file.exists()) {
              final jsonString = await file.readAsString();
              final List<dynamic> jsonList = json.decode(jsonString);
              final loaded = jsonList.map((j) => Podcast.fromJson(j)).toList();
              
              // Deduplicate on load
              final seen = <String>{};
              _subscriptions = [];
              for (var p in loaded) {
                  final norm = _normalizeUrl(p.url);
                  if (!seen.contains(norm)) {
                      seen.add(norm);
                      _subscriptions.add(p);
                  }
              }
              notifyListeners();
          }
      } catch (e) {
          Log.e('PodcastProvider', 'Error loading local subscriptions: $e');
      }
  }

  Future<void> _loadSyncTimestamp() async {
      if (_currentProfileId == null) return;
      final ts = await _storage.read(key: 'sync_ts_$_currentProfileId');
      if (ts != null) {
          _lastSyncTimestamp = int.tryParse(ts) ?? 0;
      }
  }

  Future<void> _saveSyncTimestamp(int ts) async {
      _lastSyncTimestamp = ts;
      if (_currentProfileId != null) {
          await _storage.write(key: 'sync_ts_$_currentProfileId', value: ts.toString());
      }
  }

  // Auto-Queue Logic
  Set<String> _autoQueuePodcastUrls = {};
  
  Set<String> get autoQueuePodcastUrls => _autoQueuePodcastUrls;



  Future<void> toggleAutoQueue(String url) async {
      // Directly use the URL as stored in subscriptions
      
      if (_autoQueuePodcastUrls.contains(url)) {
          _autoQueuePodcastUrls.remove(url);
          // If removing auto-queue, also remove priority? Or keep it as a setting?
          // Keeping it is fine.
      } else {
          _autoQueuePodcastUrls.add(url);
      }
      await _saveAutoQueueSettings();
  }

  bool isAutoQueueEnabled(String url) {
      return _autoQueuePodcastUrls.contains(url);
  }

  // Auto-Queue Priority Logic
  Set<String> _autoQueuePriorityUrls = {};
  bool _showQueueHelpDialog = true; // Default to true

  bool get showQueueHelpDialog => _showQueueHelpDialog;
  
  Future<void> _loadAutoQueueSettings() async {
      final prefs = await SharedPreferences.getInstance();
      final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
      
      // Subscriptions (with migration from global key)
      final scopedKey = 'auto_queue_subscriptions$suffix';
      List<String>? stored = prefs.getStringList(scopedKey);
      if (stored == null && suffix.isNotEmpty && prefs.containsKey('auto_queue_subscriptions')) {
          stored = prefs.getStringList('auto_queue_subscriptions');
          if (stored != null) await prefs.setStringList(scopedKey, stored);
      }
      if (stored != null) {
          _autoQueuePodcastUrls = stored.toSet();
      }
      
      // Priority (with migration)
      final priorityKey = 'auto_queue_priority_subscriptions$suffix';
      List<String>? storedPriority = prefs.getStringList(priorityKey);
      if (storedPriority == null && suffix.isNotEmpty && prefs.containsKey('auto_queue_priority_subscriptions')) {
          storedPriority = prefs.getStringList('auto_queue_priority_subscriptions');
          if (storedPriority != null) await prefs.setStringList(priorityKey, storedPriority);
      }
      if (storedPriority != null) {
          _autoQueuePriorityUrls = storedPriority.toSet();
      }

      // Help Dialog (with migration)
      final helpKey = 'queue_help_dialog_shown$suffix';
      if (!prefs.containsKey(helpKey) && suffix.isNotEmpty && prefs.containsKey('queue_help_dialog_shown')) {
          final val = prefs.getBool('queue_help_dialog_shown');
          if (val != null) await prefs.setBool(helpKey, val);
      }
      _showQueueHelpDialog = !(prefs.getBool(helpKey) ?? false);

      notifyListeners();
  }

  Future<void> _saveAutoQueueSettings() async {
      final prefs = await SharedPreferences.getInstance();
      final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
      await prefs.setStringList('auto_queue_subscriptions$suffix', _autoQueuePodcastUrls.toList());
      await prefs.setStringList('auto_queue_priority_subscriptions$suffix', _autoQueuePriorityUrls.toList());
      notifyListeners();
  }

  Future<void> toggleAutoQueuePriority(String url) async {
      if (_autoQueuePriorityUrls.contains(url)) {
          _autoQueuePriorityUrls.remove(url);
      } else {
          _autoQueuePriorityUrls.add(url);
      }
      await _saveAutoQueueSettings();
  }

  bool isAutoQueuePriorityEnabled(String url) {
      return _autoQueuePriorityUrls.contains(url);
  }
  
  Future<void> setQueueHelpDialogShown(bool value) async {
      // value = true means "Don't show again" basically (we record that it WAS shown/handled)
      final prefs = await SharedPreferences.getInstance();
      final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
      await prefs.setBool('queue_help_dialog_shown$suffix', value);
      _showQueueHelpDialog = !value;
      notifyListeners();
  }

  // Groups Data
  Map<String, List<String>> _groups = {};
  Map<String, List<String>> get groups => _groups;

  Future<void> _loadGroups() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
          final scopedKey = 'podcast_groups$suffix';
          String? storedString = prefs.getString(scopedKey);
          // Migration from global key
          if (storedString == null && suffix.isNotEmpty && prefs.containsKey('podcast_groups')) {
              storedString = prefs.getString('podcast_groups');
              if (storedString != null) await prefs.setString(scopedKey, storedString);
          }
          if (storedString != null) {
              final Map<String, dynamic> jsonMap = json.decode(storedString);
              _groups = jsonMap.map((key, value) => MapEntry(key, List<String>.from(value)));
          } else {
              _groups = {};
          }
      } catch (e) {
          Log.d('PodcastProvider', 'Error loading groups: $e');
      }
      notifyListeners();
  }

  Future<void> _saveGroups() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
          final jsonString = json.encode(_groups);
          await prefs.setString('podcast_groups$suffix', jsonString);
      } catch (e) {
          Log.e('PodcastProvider', 'Error saving groups: $e');
      }
      notifyListeners();
  }

  Future<void> createGroup(String name) async {
      if (!_groups.containsKey(name)) {
          _groups[name] = [];
          await _saveGroups();
      }
  }

  Future<void> deleteGroup(String name) async {
      _groups.remove(name);
      await _saveGroups();
  }

  Future<void> togglePodcastInGroup(String groupName, String podcastUrl) async {
      if (_groups.containsKey(groupName)) {
          final list = _groups[groupName]!;
          if (list.contains(podcastUrl)) {
              list.remove(podcastUrl);
          } else {
              list.add(podcastUrl);
          }
          await _saveGroups();
      }
  }
  
  bool isPodcastInGroup(String groupName, String podcastUrl) {
      return _groups[groupName]?.contains(podcastUrl) ?? false;
  }

  Future<void> updateGroupMembers(String groupName, List<String> urls) async {
       if (_groups.containsKey(groupName)) {
           _groups[groupName] = urls;
           await _saveGroups();
       }
  }

  /// Forces a refresh of all subscribed feeds.
  /// If auto-queue is enabled for a podcast, it detects new episodes,
  /// persists them to the pending auto-queue buffer, and returns them.
  Future<List<Map<String, dynamic>>> refreshAllFeeds(String deviceId) async {
       await _ensureInteractedKeysLoaded();
       await _ensureAutoQueuedKeysLoaded();
       final List<Map<String, dynamic>> newFoundEpisodes = [];

       for (var podcast in _subscriptions) {
           final url = podcast.url;
           try {
               // Force fetch latest episodes from network
               final episodes = await fetchEpisodes(url, forceRefresh: true);

               // If Auto-Queue is enabled, detect candidates using interacted-keys
               if (_autoQueuePodcastUrls.contains(url)) {
                   final candidates = await getAutoQueueCandidates(podcast, episodes);
                   newFoundEpisodes.addAll(candidates);
               }
           } catch (e) {
               Log.e('PodcastProvider', 'Feed refresh failed for $url: $e');
           }
       }
       
       // Persist new episodes to the pending auto-queue buffer so they
       // survive background fetch and are drained on next app launch/resume.
       if (newFoundEpisodes.isNotEmpty) {
           await _savePendingAutoQueue(newFoundEpisodes);
           // Mark these episodes as auto-queued so they won't be re-queued
           for (var item in newFoundEpisodes) {
               final podcast = item['podcast'] as Podcast;
               final episode = item['episode'] as Episode;
               await markAsAutoQueued(podcast.url, episode.guid);
           }
           Log.i('PodcastProvider', 'Persisted ${newFoundEpisodes.length} episodes to pending auto-queue');
       }
       
       return newFoundEpisodes;
  }

  /// Determine which episodes from a podcast are candidates for auto-queueing.
  /// Uses interacted-keys (same as NEW badge) rather than cache-diff.
  /// Skips played and already-auto-queued episodes. Caps at 3 most recent.
  Future<List<Map<String, dynamic>>> getAutoQueueCandidates(
      Podcast podcast, List<Episode> episodes) async {
      await _ensureInteractedKeysLoaded();
      await _ensureAutoQueuedKeysLoaded();

      final candidates = <Map<String, dynamic>>[];
      for (var episode in episodes) {
          final interactedKey = 'interacted_${podcast.url}_${episode.guid}';
          final autoQueuedKey = 'auto_queued_${podcast.url}_${episode.guid}';

          // Skip interacted, played, or already-auto-queued episodes
          if (_interactedKeys.contains(interactedKey)) continue;
          if (_isEpisodePlayed(episode.guid)) continue;
          if (_autoQueuedKeys.contains(autoQueuedKey)) continue;

          candidates.add({
              'podcast': podcast,
              'episode': episode,
          });
      }

      // Sort by pubDate descending, cap at 3
      candidates.sort((a, b) {
          final dateA = (a['episode'] as Episode).pubDate ?? DateTime(1970);
          final dateB = (b['episode'] as Episode).pubDate ?? DateTime(1970);
          return dateB.compareTo(dateA);
      });

      return candidates.take(3).toList();
  }

  /// Mark an episode as auto-queued to prevent re-queueing on subsequent refreshes.
  Future<void> markAsAutoQueued(String podcastUrl, String episodeGuid) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final key = 'auto_queued_${podcastUrl}_$episodeGuid';
          await prefs.setBool(key, true);

          await _ensureAutoQueuedKeysLoaded();
          _autoQueuedKeys.add(key);
      } catch (e) {
          Log.e('PodcastProvider', 'Error marking episode as auto-queued: $e');
      }
  }

  // --- Pending Auto-Queue Buffer ---

  String get _pendingAutoQueueKey {
      final suffix = _currentProfileId != null ? '_$_currentProfileId' : '';
      return 'pending_auto_queue$suffix';
  }

  /// Append new episodes to the pending auto-queue list in SharedPreferences.
  /// Each entry is serialized with enough metadata for PlayerProvider to
  /// build MediaItems without any network calls.
  Future<void> _savePendingAutoQueue(List<Map<String, dynamic>> items) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          
          // Load existing pending items to append (don't overwrite)
          final existing = prefs.getString(_pendingAutoQueueKey);
          final List<Map<String, dynamic>> pending = existing != null
              ? List<Map<String, dynamic>>.from(
                    (json.decode(existing) as List).map((e) => Map<String, dynamic>.from(e)))
              : [];

          for (var item in items) {
              final podcast = item['podcast'] as Podcast;
              final episode = item['episode'] as Episode;
              
              // Skip if already pending (by guid)
              if (pending.any((p) => p['guid'] == episode.guid)) continue;
              
              pending.add({
                  'guid': episode.guid,
                  'title': episode.title,
                  'audioUrl': episode.audioUrl,
                  'imageUrl': episode.imageUrl,
                  'duration': episode.duration?.inSeconds,
                  'pubDate': episode.pubDate?.toIso8601String(),
                  'chaptersUrl': episode.chaptersUrl,
                  'transcriptUrl': episode.transcriptUrl,
                  'podcastUrl': podcast.url,
                  'podcastTitle': podcast.title,
                  'podcastLogoUrl': podcast.logoUrl,
                  'priority': _autoQueuePriorityUrls.contains(podcast.url),
              });
          }
          
          await prefs.setString(_pendingAutoQueueKey, json.encode(pending));
      } catch (e) {
          Log.e('PodcastProvider', 'Error saving pending auto-queue: $e');
      }
  }

  /// Load all pending auto-queue episodes. Returns a list of serialized maps.
  /// Does NOT clear the list — call [clearPendingAutoQueue] after processing.
  Future<List<Map<String, dynamic>>> loadPendingAutoQueue() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final stored = prefs.getString(_pendingAutoQueueKey);
          if (stored == null) return [];
          
          final List<dynamic> jsonList = json.decode(stored);
          return jsonList.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (e) {
          Log.e('PodcastProvider', 'Error loading pending auto-queue: $e');
          return [];
      }
  }

  /// Clear the pending auto-queue buffer after episodes have been queued.
  Future<void> clearPendingAutoQueue() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_pendingAutoQueueKey);
      } catch (e) {
          Log.e('PodcastProvider', 'Error clearing pending auto-queue: $e');
      }
  }

  // Deprecated/Internal: Use refreshAllFeeds instead for global checks
  // Kept valid if needed for specific logic, but now largely redundant for the "Refresh All" use case.
  Future<List<Map<String, dynamic>>> checkAutoQueueEpisodes() async {
      await _ensureInteractedKeysLoaded();
      final List<Map<String, dynamic>> newFoundEpisodes = [];

      for (var url in _autoQueuePodcastUrls) {
          try {
              // 1. Load current cache (Old state)
              final oldEpisodes = await _loadEpisodeCache(url);
              final oldGuids = oldEpisodes.map((e) => e.guid).toSet();

              // 2. Force fetch (New state)
              final newEpisodes = await fetchEpisodes(url, forceRefresh: true);
              
              // 3. Find diff (Present in New, NOT in Old), cap at 3 most recent
              final diff = newEpisodes.where((e) => !oldGuids.contains(e.guid)).toList();
              diff.sort((a, b) => (b.pubDate ?? DateTime(1970)).compareTo(a.pubDate ?? DateTime(1970)));
              final capped = diff.take(3);

              if (capped.isNotEmpty) {
                  final podcast = _subscriptions.firstWhere(
                      (p) => p.url == url,
                      orElse: () => Podcast(url: url, title: 'Unknown Podcast'),
                  );

                  for (var episode in capped) {
                      newFoundEpisodes.add({
                          'podcast': podcast,
                          'episode': episode,
                      });
                  }
              }
          } catch (e) {
              Log.d('PodcastProvider', 'Auto-queue check failed for $url: $e');
          }
      }
      
      return newFoundEpisodes;
  }

  // Episode Caching Helpers
  Future<File> _getEpisodeCacheFile(String url) async {
      final directory = await _documentsDir;
      // C2: Use cached UUID v5 for stable filenames
      final uuid = _uuidCache[url] ??= const Uuid().v5(Uuid.NAMESPACE_URL, url);
      final filename = 'episodes_$uuid.json';
      return File('${directory.path}/$filename');
  }

  Future<void> _saveEpisodeCache(String url, List<Episode> episodes) async {
      try {
          final file = await _getEpisodeCacheFile(url);
          final jsonString = json.encode(episodes.map((e) => {
              'guid': e.guid,
              'title': e.title,
              'description': e.description,
              'audioUrl': e.audioUrl,
              'pubDate': e.pubDate?.toIso8601String(),
              'imageUrl': e.imageUrl,
              'duration': e.duration?.inSeconds,
              'link': e.link,
              'chaptersUrl': e.chaptersUrl,
              'transcriptUrl': e.transcriptUrl,
          }).toList());
          await file.writeAsString(jsonString);
      } catch (e) {
          Log.e('PodcastProvider', 'Error caching episodes for $url: $e');
      }
  }

  Future<List<Episode>> _loadEpisodeCache(String url) async {
      try {
          final file = await _getEpisodeCacheFile(url);
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
                  chaptersUrl: j['chaptersUrl'],
                  transcriptUrl: j['transcriptUrl'],
              )).toList();
          }
      } catch (e) {
          Log.e('PodcastProvider', 'Error loading episode cache for $url: $e');
      }
      return [];
  }

  Future<List<Episode>> fetchEpisodes(String rssUrl, {bool forceRefresh = false, bool ignoreCacheAge = false}) async {
    // 0. Check Memory Cache (First line of defense)
    if (!forceRefresh && !ignoreCacheAge && _memoryEpisodeCache.containsKey(rssUrl)) {
        // We trust memory cache if we aren't forcing refresh. 
        // Logic: if it's in memory, we likely just loaded it or used it.
        // If the user wants to be sure about "Age", they might need to check file timestamp, 
        // but for general UI browsing, memory is king.
        _memoryCacheKeys.remove(rssUrl);
        _memoryCacheKeys.add(rssUrl);
        return _memoryEpisodeCache[rssUrl]!;
    }
    
    List<Episode>? result;

    // 1. Check local file cache
    try {
        final cacheFile = await _getEpisodeCacheFile(rssUrl);
        if (await cacheFile.exists()) {
            final lastModified = await cacheFile.lastModified();
            final age = DateTime.now().difference(lastModified);
            
            final cacheDurationHours = _settings?.feedCacheDuration ?? 24;
            
            // If cache is fresh OR we ignore cache age, and we aren't forcing a refresh, return it
            if (!forceRefresh && (age.inHours < cacheDurationHours || ignoreCacheAge)) {
                 final cached = await _loadEpisodeCache(rssUrl);
                 if (cached.isNotEmpty) {
                    result = cached;
                 }
            }
        }
    } catch (e) {
        Log.d('PodcastProvider', 'Cache check failed for $rssUrl: $e');
    }

    if (result != null) {
        _updateMemoryCache(rssUrl, result);
        return result;
    }

    // 2. Network fetch
    try {
        // Look up feed credentials for authenticated feeds
        final creds = await getFeedCredentials(rssUrl);
        final episodes = await _rssService.fetchEpisodes(rssUrl, username: creds?['username'], password: creds?['password']);
        // Cache success
        await _saveEpisodeCache(rssUrl, episodes);
        _updateMemoryCache(rssUrl, episodes);
        return episodes;
    } catch (e) {
        Log.w('PodcastProvider', 'Network fetch failed for $rssUrl, trying cache fallback. Error: $e');
        // Fallback to cache even if stale (logic above handles success case, this handles failure case)
        final cached = await _loadEpisodeCache(rssUrl);
        if (cached.isNotEmpty) {
            _updateMemoryCache(rssUrl, cached);
            return cached;
        }
        rethrow;
    }
  }

  void _updateMemoryCache(String url, List<Episode> episodes) {
      if (_memoryEpisodeCache.containsKey(url)) {
          _memoryCacheKeys.remove(url);
      } else if (_memoryCacheKeys.length >= _maxMemoryCacheSize) {
          final lru = _memoryCacheKeys.removeAt(0);
          _memoryEpisodeCache.remove(lru);
      }
      _memoryCacheKeys.add(url);
      _memoryEpisodeCache[url] = episodes;
  }

  Future<void> refreshSubscriptions(String deviceId) async {
    // Local account support: if no API, we just refresh feeds locally
    if (_api == null) {
       // Just refresh all feeds metadata/content
       await refreshAllFeeds(deviceId);
       return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final delta = await _api!.getSubscriptionChanges(deviceId, _lastSyncTimestamp);
      
      bool changed = false;

      // 1. Remove
      if (delta.remove.isNotEmpty) {
          final initialLength = _subscriptions.length;
          final removeSet = delta.remove.map((u) => _normalizeUrl(u)).toSet();
          _subscriptions.removeWhere((p) => removeSet.contains(_normalizeUrl(p.url)));
          if (_subscriptions.length != initialLength) changed = true;
      }
      
        // 2. Add
      if (delta.add.isNotEmpty) {
         final existingUrls = _subscriptions.map((s) => _normalizeUrl(s.url)).toSet();
         final newRawUrls = delta.add.where((url) => !existingUrls.contains(_normalizeUrl(url))).toList();
         
         // Dedup the new list itself
         final uniqueNewUrls = <String>{};
         final finalNewUrls = <String>[];
         for (var url in newRawUrls) {
             final norm = _normalizeUrl(url);
             if (!uniqueNewUrls.contains(norm)) {
                 uniqueNewUrls.add(norm);
                 finalNewUrls.add(url);
             }
         }
         
         if (finalNewUrls.isNotEmpty) {
             // Fetch metadata in parallel
             final futures = finalNewUrls.map((url) async {
                try {
                  final creds = await getFeedCredentials(url);
                  return await _rssService.getFeedMetadata(url, username: creds?['username'], password: creds?['password']);
                } catch (e) {
                  Log.e('PodcastProvider', 'Failed to fetch metadata for $url: $e');
                  return Podcast(url: url, title: url);
                }
              });
              
              final newPodcasts = await Future.wait(futures);
              _subscriptions.addAll(newPodcasts);
              changed = true;
         }
      }
      
      if (changed) {
          await _saveSubscriptions();
      }
      
      await _saveSyncTimestamp(delta.timestamp);

    } catch (e) {
    Log.e('PodcastProvider', 'Sync failed: $e');
    // Only surface error to UI if we have no cached subscriptions to show
    if (_subscriptions.isEmpty) {
      _error = e.toString();
    }
    // Don't rethrow — let callers and UI degrade gracefully
  } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> subscribe(String url, String deviceId, {String? feedUsername, String? feedPassword}) async {
    // Local support: Allow if no API
    // if (_api == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final normalizedUrl = _normalizeUrl(url);

      // Check existence first
      if (_subscriptions.any((p) => _normalizeUrl(p.url) == normalizedUrl)) {
          // Already subscribed
          return;
      }

      // 1. Store feed credentials securely if provided (Approach 2)
      final bool hasExplicitAuth = feedUsername != null && feedPassword != null;
      if (hasExplicitAuth) {
          await saveFeedCredentials(url, feedUsername, feedPassword);
      }

      // 2. Tell API to add subscription (if syncing)
      if (_api != null) {
          await _api!.updateSubscriptions(
            deviceId,
            add: [url],
          );
      }

      // 3. Fetch metadata for local use (with auth if needed)
      final newPodcast = await _rssService.getFeedMetadata(
        url, 
        username: feedUsername, 
        password: feedPassword,
      );
      
      // 4. Add to local list with requiresAuth flag
      if (!_subscriptions.any((p) => _normalizeUrl(p.url) == _normalizeUrl(newPodcast.url))) {
        _subscriptions.add(Podcast(
          url: newPodcast.url,
          title: newPodcast.title,
          description: newPodcast.description,
          logoUrl: newPodcast.logoUrl,
          website: newPodcast.website,
          requiresAuth: hasExplicitAuth || Uri.parse(url).userInfo.isNotEmpty,
        ));
        await _saveSubscriptions();
      }
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // --- Feed Credential Storage (Approach 2) ---
  
  /// Save per-feed credentials to secure storage.
  Future<void> saveFeedCredentials(String feedUrl, String username, String password) async {
      final key = 'feed_auth_${feedUrl.hashCode}';
      await _storage.write(key: '${key}_user', value: username);
      await _storage.write(key: '${key}_pass', value: password);
  }

  /// Retrieve per-feed credentials from secure storage.
  /// Returns null if no credentials are stored.
  Future<Map<String, String>?> getFeedCredentials(String feedUrl) async {
      final key = 'feed_auth_${feedUrl.hashCode}';
      final username = await _storage.read(key: '${key}_user');
      final password = await _storage.read(key: '${key}_pass');
      if (username != null && password != null) {
          return {'username': username, 'password': password};
      }
      // Also check for URL-embedded credentials
      final uri = Uri.parse(feedUrl);
      if (uri.userInfo.isNotEmpty) {
          final parts = uri.userInfo.split(':');
          return {
              'username': Uri.decodeComponent(parts[0]),
              'password': parts.length > 1 ? Uri.decodeComponent(parts.sublist(1).join(':')) : '',
          };
      }
      return null;
  }

  /// Delete per-feed credentials from secure storage.
  Future<void> deleteFeedCredentials(String feedUrl) async {
      final key = 'feed_auth_${feedUrl.hashCode}';
      await _storage.delete(key: '${key}_user');
      await _storage.delete(key: '${key}_pass');
  }

  Future<void> removePodcast(String url, String deviceId) async {
    // Local support
    // if (_api == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      // 1. Tell API to remove subscription
      if (_api != null) {
          await _api!.updateSubscriptions(
            deviceId,
            remove: [url],
          );
      }

      // 2. Remove from local list and clean up credentials
      _subscriptions.removeWhere((p) => p.url == url);
      await deleteFeedCredentials(url);
      await _saveSubscriptions();
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> pushToServer(String deviceId) async {
    if (_api == null) return;
    _isLoading = true;
    notifyListeners();

    try {
      final currentUrls = _subscriptions.map((s) => s.url).toList();
      if (currentUrls.isNotEmpty) {
        await _api!.updateSubscriptions(deviceId, add: currentUrls);
      }
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> pullFromServer(String deviceId) async {
    if (_api == null) return;
    _isLoading = true;
    notifyListeners();

    try {
      await refreshSubscriptions(deviceId);
    } catch (e) {
      // refreshSubscriptions handles _error internally
      Log.e('PodcastProvider', 'Pull from server failed: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, List<Episode>>> _fetchFeedsWithCache(Set<String> urls) async {
    final Map<String, List<Episode>> results = {};
    final List<String> toFetch = [];
    toFetch.addAll(urls);

    final futures = toFetch.map((url) async {
      try {
        // Try cache first inside fetchEpisodes now
        final episodes = await fetchEpisodes(url); 
        return MapEntry(url, episodes);
      } catch (e) {
        Log.e('PodcastProvider', 'Failed to fetch feed $url: $e');
        return MapEntry(url, <Episode>[]);
      }
    });

    final entries = await Future.wait(futures);
    results.addEntries(entries);
    
    return results;
  }

  Future<List<Map<String, dynamic>>> fetchInProgressEpisodes(String deviceId) async {
    // Local account support: build in-progress from local cache
    if (_api == null) {
        return _fetchLocalInProgressEpisodes();
    }
    
    try {
      final actions = await _api!.getEpisodeActions(deviceId);
      final Map<String, EpisodeAction> latestActions = {};
      
      for (var action in actions) {
        final key = '${action.podcast}:${action.episode}';
        final existing = latestActions[key];
        
        if (existing == null || action.timestamp > existing.timestamp) {
          latestActions[key] = action;
        }
      }

      final uniquePodcasts = <String>{};
      final relevantActions = <EpisodeAction>[];

      for (var action in latestActions.values) {
          // Check if finished:
          // 1. Within 15 seconds of end
          // 2. Or > 99% complete
          bool isFinished = false;
          if (action.total != null && action.total! > 0 && action.position != null) {
              if (action.position! >= action.total! - 15) {
                  isFinished = true;
              } else if (action.position! / action.total! > 0.99) {
                  isFinished = true;
              }
          }

          if (action.position != null && action.position! > 0 && !isFinished) {
              uniquePodcasts.add(action.podcast);
              relevantActions.add(action);
          }
      }

      final feedCache = await _fetchFeedsWithCache(uniquePodcasts);
      final inProgress = <Map<String, dynamic>>[];
      
      for (var action in relevantActions) {
           try {
               final podcast = _subscriptions.firstWhere(
                 (p) => p.url == action.podcast, 
                 orElse: () => Podcast(url: action.podcast, title: 'Unknown Podcast'),
               );

               final episodes = feedCache[action.podcast] ?? [];
               
               final episode = episodes.firstWhere(
                   (e) => (e.guid == action.episode) || (e.audioUrl == action.episode) || (e.link == action.episode),
                   orElse: () => Episode(
                       guid: action.episode, 
                       title: 'Unknown Episode', 
                       audioUrl: action.episode, 
                       description: ''
                   ),
               );
               
               inProgress.add({
                 'podcast': podcast,
                 'action': action,
                 'episode': episode,
               });
           } catch (e) {
               Log.e('PodcastProvider', 'Error processing in-progress item ${action.podcast}: $e');
           }
      }
      return inProgress;
    } catch (e) {
      Log.e('PodcastProvider', 'Error fetching in-progress: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchListeningHistory(String deviceId) async {
    // Local Support: Generate history from local cache if API missing
    if (_api == null) {
        return _fetchLocalListeningHistory();
    }

    try {
      final actions = await _api!.getEpisodeActions(deviceId);
      actions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final history = <Map<String, dynamic>>[];
      
      final recentActions = actions.take(50).toList();
      final olderActions = actions.skip(50).toList();

      final uniquePodcasts = recentActions.map((a) => a.podcast).toSet();
      final feedCache = await _fetchFeedsWithCache(uniquePodcasts);

      for (var action in recentActions) {
          try {
             final podcast = _subscriptions.firstWhere(
               (p) => p.url == action.podcast, 
               orElse: () => Podcast(url: action.podcast, title: 'Unknown Podcast'),
             );
             final episodes = feedCache[action.podcast] ?? [];
             final episode = episodes.firstWhere(
                (e) => (e.guid == action.episode) || (e.audioUrl == action.episode) || (e.link == action.episode),
                orElse: () => Episode(guid: action.episode, title: action.episode, audioUrl: action.episode),
             );
             history.add({
               'podcast': podcast,
               'action': action,
               'episode': episode,
             });
          } catch (e) {
              Log.e('PodcastProvider', 'Error processing history item: $e');
          }
      }
      
      for (var action in olderActions) {
           final podcast = _subscriptions.firstWhere(
             (p) => p.url == action.podcast, 
             orElse: () => Podcast(url: action.podcast, title: 'Unknown Podcast'),
           );
           history.add({
             'podcast': podcast,
             'action': action,
             'episode': Episode(guid: action.episode, title: action.episode, audioUrl: action.episode),
           });
      }
      return history;
    } catch (e) {
      Log.e('PodcastProvider', 'Error fetching history: $e');
      return [];
    }
  }

  Future<void> removeInProgressEpisode(Podcast podcast, Episode episode, String deviceId) async {
    _isLoading = true;
    notifyListeners();
    
    try {
        final action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? episode.guid,
            guid: episode.guid,
            action: 'play',
            device: deviceId,
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            started: 0,
            position: 0,
            total: episode.duration?.inSeconds ?? 0,
        );

        // Always update local cache first
        _actionMap[action.episode] = action;
        _cachedEpisodeActions = _actionMap.values.toList();
        _saveActionCache();

        // Upload to server if connected
        if (_api != null) {
          await _api!.uploadEpisodeActions([action]);
        }
    } catch (e) {
       _error = e.toString();
       rethrow;
    } finally {
        _isLoading = false;
        notifyListeners();
    }
  }

  Future<void> markEpisodesAsPlayed(List<Map<String, dynamic>> items, String deviceId) async {
    _isLoading = true;
    notifyListeners();

    try {
      final actions = items.map((item) {
        final podcast = item['podcast'] as Podcast;
        final episode = item['episode'] as Episode;
        final duration = episode.duration?.inSeconds ?? 0;
        // Use sentinel 1 for episodes without duration metadata so
        // getEpisodeStatuses recognizes them as fully played (total > 0).
        final effectiveDuration = duration > 0 ? duration : 1;
        
        return EpisodeAction(
          podcast: podcast.url,
          episode: episode.audioUrl ?? episode.guid,
          guid: episode.guid,
          action: 'play',
          device: deviceId,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          started: effectiveDuration,
          position: effectiveDuration,
          total: effectiveDuration,
        );
      }).toList();

      // Always update local cache first (before server upload)
      for (var action in actions) {
          _actionMap[action.episode] = action;
      }
      _cachedEpisodeActions = _actionMap.values.toList();
      _saveActionCache(); // Persist to disk

      // Upload to server if connected
      if (_api != null) {
        await _api!.uploadEpisodeActions(actions);
      }

      // Also mark as interacted locally so "New" badge disappears
      // Optimization: Group by podcast to batch updates
      final Map<String, List<String>> podcastToEpisodes = {};
      
      for (var item in items) {
          final podcast = item['podcast'] as Podcast;
          final episode = item['episode'] as Episode;
          
          if (!podcastToEpisodes.containsKey(podcast.url)) {
              podcastToEpisodes[podcast.url] = [];
          }
          podcastToEpisodes[podcast.url]!.add(episode.guid);
      }
      
      for (var entry in podcastToEpisodes.entries) {
          await markAllEpisodesAsInteracted(entry.key, entry.value);
      }
      
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // In-memory cache for interaction keys to avoid hitting SharedPreferences repeatedly
  final Set<String> _interactedKeys = {};
  bool _interactedKeysLoaded = false;

  // In-memory cache for auto-queued episode keys
  final Set<String> _autoQueuedKeys = {};
  bool _autoQueuedKeysLoaded = false;

  Future<void> _ensureInteractedKeysLoaded() async {
      if (_interactedKeysLoaded) return;
      try {
          final prefs = await SharedPreferences.getInstance();
          final keys = prefs.getKeys();
          _interactedKeys.addAll(keys.where((k) => k.startsWith('interacted_')));
          _interactedKeysLoaded = true;
      } catch (e) {
          Log.d('PodcastProvider', 'Error loading interaction cache: $e');
      }
  }

  Future<void> _ensureAutoQueuedKeysLoaded() async {
      if (_autoQueuedKeysLoaded) return;
      try {
          final prefs = await SharedPreferences.getInstance();
          final keys = prefs.getKeys();
          _autoQueuedKeys.addAll(keys.where((k) => k.startsWith('auto_queued_')));
          _autoQueuedKeysLoaded = true;
      } catch (e) {
          Log.d('PodcastProvider', 'Error loading auto-queued keys: $e');
      }
  }

  /// Check if an episode has been fully played based on _actionMap.
  bool _isEpisodePlayed(String episodeGuid) {
      final action = getLatestAction(episodeGuid);
      if (action == null) return false;
      if (action.total == null || action.total! <= 0) return false;
      if (action.position == null) return false;
      // Within 15 seconds of end
      if (action.position! >= action.total! - 15) return true;
      // > 99% complete
      if (action.position! / action.total! > 0.99) return true;
      return false;
  }

  Future<void> markAllEpisodesAsInteracted(String podcastUrl, List<String> episodeGuids) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          
          await _ensureInteractedKeysLoaded();
          
          for (var guid in episodeGuids) {
              final key = 'interacted_${podcastUrl}_$guid';
              prefs.setBool(key, true);  // Memory-sync, disk-async
              _interactedKeys.add(key);
          }
          
          notifyListeners();
      } catch (e) {
          Log.e('PodcastProvider', 'Error marking all episodes as interacted: $e');
      }
  }

  Future<void> markEpisodeAsInteracted(String podcastUrl, String episodeGuid) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final key = 'interacted_${podcastUrl}_$episodeGuid';
          await prefs.setBool(key, true);
          
          await _ensureInteractedKeysLoaded();
          _interactedKeys.add(key);
          
          notifyListeners();
      } catch (e) {
          Log.e('PodcastProvider', 'Error marking episode as interacted: $e');
      }
  }

  Future<void> markEpisodeAsUnplayed(String podcastUrl, String episodeGuid) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final key = 'interacted_${podcastUrl}_$episodeGuid';
          await prefs.remove(key);
          
          await _ensureInteractedKeysLoaded();
          _interactedKeys.remove(key);
          
          notifyListeners();
      } catch (e) {
          Log.e('PodcastProvider', 'Error marking episode as unplayed: $e');
      }
  }

  Future<bool> isEpisodeNew(String podcastUrl, String episodeGuid) async {
       await _ensureInteractedKeysLoaded();
       final key = 'interacted_${podcastUrl}_$episodeGuid';
       if (_interactedKeys.contains(key)) return false;
       // Also check if the episode has been fully played (e.g., on another device via sync)
       if (_isEpisodePlayed(episodeGuid)) return false;
       return true;
  }

  Future<bool> hasAnyNewEpisodes(String podcastUrl) async {
      // 1. Load cache if needed
      await _ensureInteractedKeysLoaded();

      // 2. Load episodes from disk cache (fast)
      // Do NOT trigger network fetch here
      try {
          final episodes = await _loadEpisodeCache(podcastUrl);
          if (episodes.isEmpty) return false;

          for (var episode in episodes) {
             final key = 'interacted_${podcastUrl}_${episode.guid}';
             if (!_interactedKeys.contains(key) && !_isEpisodePlayed(episode.guid)) {
                 return true;
             }
          }
      } catch (e) {
          // ignore cache errors
      }
      return false;
  }

  Future<void> updateFilterStatuses(Set<String> downloadedUrls, String deviceId) async {
      // Clear current state
      _podcastsWithUnplayed.clear();
      _podcastsWithDownloads.clear();
      _podcastsWithInProgress.clear();

      await _ensureInteractedKeysLoaded();
      
      // We need in-progress actions to check "In Progress"
      // Optimization: Fetch once.
      Map<String, EpisodeAction> inProgressActions = {};
      try {
           if (_api != null) {
              final actions = await _api!.getEpisodeActions(deviceId);
              // Filter for latest action per episode
              for (var action in actions) {
                  final key = '${action.podcast}:${action.episode}';
                  final existing = inProgressActions[key];
                  if (existing == null || action.timestamp > existing.timestamp) {
                      inProgressActions[key] = action;
                  }
              }
           }
      } catch (e) {
          // Ignore network errors, proceed with partial data if possible
      }

      for (var podcast in _subscriptions) {
          try {
              final episodes = await _loadEpisodeCache(podcast.url);
              if (episodes.isEmpty) continue; // Skip if no episodes loaded
              
              bool hasUnplayed = false;
              bool hasDownload = false;
              bool hasInProg = false;

              for (var episode in episodes) {
                  // Check Download
                  if (!hasDownload && episode.audioUrl != null && downloadedUrls.contains(episode.audioUrl)) {
                      hasDownload = true;
                  }

                  // Check Unplayed
                  // "Unplayed" = Not Interacted AND Not Played on Server
                  // Simplified: Just Not Interacted (New)
                  if (!hasUnplayed) {
                       final key = 'interacted_${podcast.url}_${episode.guid}';
                       if (!_interactedKeys.contains(key)) {
                           hasUnplayed = true;
                       }
                  }
                  
                  // Check In Progress
                  if (!hasInProg) {
                      final key = '${podcast.url}:${episode.guid}';
                      final action = inProgressActions[key];
                      if (action != null && action.position != null && action.total != null && action.total! > 0) {
                          final p = action.position!;
                          final t = action.total!;
                          // Not finished ( < 99% and not within 15s of end) AND started (> 0)
                          final isFinished = (p >= t - 15) || (p / t > 0.99);
                          if (p > 0 && !isFinished) {
                              hasInProg = true;
                          }
                      }
                  }

                  if (hasUnplayed && hasDownload && hasInProg) break; // Found all 3, next podcast
              }

              if (hasUnplayed) _podcastsWithUnplayed.add(podcast.url);
              if (hasDownload) _podcastsWithDownloads.add(podcast.url);
              if (hasInProg) _podcastsWithInProgress.add(podcast.url);

          } catch (e) {
              // Ignore individual podcast errors
          }
      }
      notifyListeners();
  }


  Future<Map<String, String>> getEpisodeStatuses(String podcastUrl, String deviceId) async {
      final statuses = <String, String>{};
      
      // Use cached actions if available (syncEpisodeActions should be called by lifecycle/screens)
      // Fallback to simpler check or empty if no cache? 
      // If the cache is empty but we have an API, maybe we should fetch?
      // For CarPlay, we expect syncEpisodeActions to be called on init.
      
      if (_cachedEpisodeActions.isEmpty && _api != null) {
          // Try a quick fetch if we have nothing
           await syncEpisodeActions(deviceId, force: false);
      }

      try {
          // Filter actions for this podcast from CACHE
          // Key by GUID (not action.episode which may be a URL after the Repod fix)
          final simpleActions = <String, EpisodeAction>{};
          for (var action in _cachedEpisodeActions) {
              if (action.podcast == podcastUrl) {
                  final guid = action.guid ?? action.episode;
                  final existing = simpleActions[guid];
                  if (existing == null || action.timestamp > existing.timestamp) {
                      simpleActions[guid] = action;
                  }
              }
          }
          
          for (var entry in simpleActions.entries) {
              final action = entry.value;
              final guid = entry.key;
              
              bool isFinished = false;
              if (action.total != null && action.total! > 0 && action.position != null) {
                  if (action.position! >= action.total! - 15) {
                      isFinished = true;
                  } else if (action.position! / action.total! > 0.99) {
                      isFinished = true;
                  }
              }

              if (isFinished) {
                  statuses[guid] = 'played';
              } else if (action.position != null && action.position! > 0) {
                  statuses[guid] = 'in_progress';
              } else {
                  // started but pos 0? unplayed or interacted.
                  statuses[guid] = 'interacted'; 
              }
          }
          
          return statuses;

      } catch (e) {
          Log.e('PodcastProvider', 'Error getting statuses: $e');
          return statuses;
      }
  }

  Future<List<Map<String, dynamic>>> getNewEpisodesForPodcast(String podcastUrl) async {
      await _ensureInteractedKeysLoaded();
      final List<Map<String, dynamic>> newEpisodes = [];
      
      try {
          // Find podcast object
          final podcast = _subscriptions.firstWhere(
            (p) => p.url == podcastUrl, 
            orElse: () => Podcast(url: podcastUrl, title: 'Unknown'),
          );

          final episodes = await _loadEpisodeCache(podcastUrl);
          
          for (final episode in episodes) {
              final key = 'interacted_${podcastUrl}_${episode.guid}';
              if (!_interactedKeys.contains(key)) {
                  newEpisodes.add({
                      'podcast': podcast,
                      'episode': episode,
                  });
              }
          }
      } catch (e) {
          // ignore
      }
      
      // Sort by pubDate desc
      newEpisodes.sort((a, b) {
          final dateA = (a['episode'] as Episode).pubDate ?? DateTime(1970);
          final dateB = (b['episode'] as Episode).pubDate ?? DateTime(1970);
          return dateB.compareTo(dateA);
      });
      
      return newEpisodes;
  }

  Future<List<Map<String, dynamic>>> getAllNewEpisodes() async {
      await _ensureInteractedKeysLoaded();
      final List<Map<String, dynamic>> newEpisodes = [];
      
      for (final podcast in _subscriptions) {
          try {
              final episodes = await _loadEpisodeCache(podcast.url);
              // Filter for new: not in _interactedKeys
              
              for (final episode in episodes) {
                  final key = 'interacted_${podcast.url}_${episode.guid}';
                  if (!_interactedKeys.contains(key)) {
                      newEpisodes.add({
                          'podcast': podcast,
                          'episode': episode,
                      });
                  }
              }
          } catch (e) {
              // ignore
          }
      }
      
      // Sort globally by pubDate desc (newest first)
      newEpisodes.sort((a, b) {
          final dateA = (a['episode'] as Episode).pubDate ?? DateTime(1970);
          final dateB = (b['episode'] as Episode).pubDate ?? DateTime(1970);
          return dateB.compareTo(dateA);
      });
      
      return newEpisodes;
  }


  Future<List<Map<String, dynamic>>> _fetchLocalListeningHistory() async {
      try {
          // Sort cached actions by timestamp desc
          final actions = List<EpisodeAction>.from(_cachedEpisodeActions);
          actions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          
          final history = <Map<String, dynamic>>[];
          
          // Take top 100 for local history
          final recentActions = actions.take(100).toList();
          final uniquePodcasts = recentActions.map((a) => a.podcast).toSet();
          final feedCache = await _fetchFeedsWithCache(uniquePodcasts);

          for (var action in recentActions) {
              try {
                 final podcast = _subscriptions.firstWhere(
                   (p) => p.url == action.podcast, 
                   orElse: () => Podcast(url: action.podcast, title: 'Unknown Podcast'),
                 );
                 final episodes = feedCache[action.podcast] ?? [];
                 final episode = episodes.firstWhere(
                    (e) => (e.guid == action.episode) || (e.audioUrl == action.episode) || (e.link == action.episode),
                    orElse: () => Episode(guid: action.episode, title: action.episode, audioUrl: action.episode),
                 );
                 history.add({
                   'podcast': podcast,
                   'action': action,
                   'episode': episode,
                 });
              } catch (e) {
                  // ignore bad items
              }
          }
          return history;
      } catch (e) {
          Log.e('PodcastProvider', 'Error fetching local history: $e');
          return [];
      }
  }

  Future<List<Map<String, dynamic>>> _fetchLocalInProgressEpisodes() async {
      try {
          // Build in-progress from local action cache (same logic as server version)
          final Map<String, EpisodeAction> latestActions = {};
          for (var action in _cachedEpisodeActions) {
              final key = '${action.podcast}:${action.episode}';
              final existing = latestActions[key];
              if (existing == null || action.timestamp > existing.timestamp) {
                  latestActions[key] = action;
              }
          }

          final uniquePodcasts = <String>{};
          final relevantActions = <EpisodeAction>[];

          for (var action in latestActions.values) {
              bool isFinished = false;
              if (action.total != null && action.total! > 0 && action.position != null) {
                  if (action.position! >= action.total! - 15) {
                      isFinished = true;
                  } else if (action.position! / action.total! > 0.99) {
                      isFinished = true;
                  }
              }

              if (action.position != null && action.position! > 0 && !isFinished) {
                  uniquePodcasts.add(action.podcast);
                  relevantActions.add(action);
              }
          }

          final feedCache = await _fetchFeedsWithCache(uniquePodcasts);
          final inProgress = <Map<String, dynamic>>[];

          for (var action in relevantActions) {
              try {
                  final podcast = _subscriptions.firstWhere(
                    (p) => p.url == action.podcast,
                    orElse: () => Podcast(url: action.podcast, title: 'Unknown Podcast'),
                  );
                  final episodes = feedCache[action.podcast] ?? [];
                  final episode = episodes.firstWhere(
                      (e) => (e.guid == action.episode) || (e.audioUrl == action.episode) || (e.link == action.episode),
                      orElse: () => Episode(guid: action.episode, title: 'Unknown Episode', audioUrl: action.episode, description: ''),
                  );
                  inProgress.add({
                    'podcast': podcast,
                    'action': action,
                    'episode': episode,
                  });
              } catch (e) {
                  Log.e('PodcastProvider', 'Error processing local in-progress item: $e');
              }
          }
          return inProgress;
      } catch (e) {
          Log.e('PodcastProvider', 'Error fetching local in-progress: $e');
          return [];
      }
  }

  // --- OPML Import / Export ---

  final OpmlService _opmlService = OpmlService();

  /// Parse OPML content and return feeds that are NOT already in the user's subscriptions.
  /// Returns all parsed feeds with an `isSubscribed` flag for UI display.
  List<Map<String, dynamic>> parseOpmlForImport(String opmlContent) {
    final feeds = _opmlService.parseOpml(opmlContent);
    final existingUrls = _subscriptions.map((s) => _normalizeUrl(s.url)).toSet();

    return feeds.map((feed) {
      final isSubscribed = existingUrls.contains(_normalizeUrl(feed.xmlUrl));
      return {
        'feed': feed,
        'isSubscribed': isSubscribed,
      };
    }).toList();
  }

  /// Subscribe to a list of OPML feeds in batch.
/// Calls [onProgress] with (completed, total) for UI progress updates.
/// Skips feeds that are already subscribed. Continues on individual failures.
Future<ImportResult> subscribeToFeeds(
  List<OpmlFeed> feeds,
  String deviceId, {
  Function(int completed, int total)? onProgress,
}) async {
  int successCount = 0;
  int failureCount = 0;
  int skippedCount = 0;
  final failedFeeds = <String>[];
  final existingUrls = _subscriptions.map((s) => _normalizeUrl(s.url)).toSet();

  // Filter out already-subscribed feeds first
  final feedsToProcess = <OpmlFeed>[];
  for (var feed in feeds) {
    if (existingUrls.contains(_normalizeUrl(feed.xmlUrl))) {
      skippedCount++;
    } else {
      feedsToProcess.add(feed);
    }
  }

  // Process in parallel batches of 3
  const batchSize = 3;
  int completed = skippedCount;
  onProgress?.call(completed, feeds.length);

  for (int i = 0; i < feedsToProcess.length; i += batchSize) {
    final batch = feedsToProcess.skip(i).take(batchSize).toList();
    final results = await Future.wait(
      batch.map((feed) async {
        try {
          await subscribe(feed.xmlUrl, deviceId);
          return (true, feed.title, feed.xmlUrl); // Include xmlUrl for existingUrls update
        } catch (e) {
          Log.e('PodcastProvider', 'Failed to import feed ${feed.xmlUrl}: $e');
          return (false, feed.title, feed.xmlUrl);
        }
      }),
    );

    for (var (success, title, xmlUrl) in results) {
      if (success) {
        successCount++;
        existingUrls.add(_normalizeUrl(xmlUrl));
      } else {
        failureCount++;
        failedFeeds.add(title);
      }
    }

    completed += batch.length;
    onProgress?.call(completed, feeds.length);
  }

  onProgress?.call(feeds.length, feeds.length);
  notifyListeners();

  return ImportResult(
    successCount: successCount,
    failureCount: failureCount,
    skippedCount: skippedCount,
    failedFeeds: failedFeeds,
  );
}

  /// Export current subscriptions as an OPML XML string.
  String exportToOpml() {
    return _opmlService.generateOpml(_subscriptions);
  }
}
