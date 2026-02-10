import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../api/gpodder_api.dart';
import '../api/rss_service.dart';
import '../models/podcast.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'settings_provider.dart';
import '../services/log_service.dart';

class PodcastProvider with ChangeNotifier {
  List<Podcast> _subscriptions = [];
  bool _isLoading = false;
  String? _error;

  List<Podcast> get subscriptions => _subscriptions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  
  int _lastSyncTimestamp = 0;
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

  bool hasUnplayed(String url) => _podcastsWithUnplayed.contains(url);
  bool hasDownloads(String url) => _podcastsWithDownloads.contains(url);
  bool hasInProgress(String url) => _podcastsWithInProgress.contains(url);

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
              notifyListeners();
          }
      } catch (e) {
          Log.e('PodcastProvider', 'init failed: $e');
      }
  }

  void setApi(GPodderApi api, String profileId) {
    if (_currentProfileId == profileId && _api != null) {
        _api = api;
        return;
    }
    
    _api = api;
    _currentProfileId = profileId;
    _subscriptions = [];
    _lastSyncTimestamp = 0;
    
    // Load local data immediately for start UI
    _loadSubscriptions();
    _loadSyncTimestamp(); 
    _loadAutoQueueSettings();
    _loadGroups();
    notifyListeners();
  }
  
  // Persistence Helpers
  Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
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
      
      // Subscriptions
      final List<String>? stored = prefs.getStringList('auto_queue_subscriptions');
      if (stored != null) {
          _autoQueuePodcastUrls = stored.toSet();
      }
      
      // Priority
      final List<String>? storedPriority = prefs.getStringList('auto_queue_priority_subscriptions');
      if (storedPriority != null) {
          _autoQueuePriorityUrls = storedPriority.toSet();
      }

      // Help Dialog
      _showQueueHelpDialog = !(prefs.getBool('queue_help_dialog_shown') ?? false); // key stores if *shown*, so invert

      notifyListeners();
  }

  Future<void> _saveAutoQueueSettings() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('auto_queue_subscriptions', _autoQueuePodcastUrls.toList());
      await prefs.setStringList('auto_queue_priority_subscriptions', _autoQueuePriorityUrls.toList());
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
      await prefs.setBool('queue_help_dialog_shown', value);
      _showQueueHelpDialog = !value;
      notifyListeners();
  }

  // Groups Data
  Map<String, List<String>> _groups = {};
  Map<String, List<String>> get groups => _groups;

  Future<void> _loadGroups() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final storedString = prefs.getString('podcast_groups');
          if (storedString != null) {
              final Map<String, dynamic> jsonMap = json.decode(storedString);
              // Convert dynamic list to String list
              _groups = jsonMap.map((key, value) => MapEntry(key, List<String>.from(value)));
          }
      } catch (e) {
          Log.d('PodcastProvider', 'Error loading groups: $e');
      }
      notifyListeners();
  }

  Future<void> _saveGroups() async {
      try {
          final prefs = await SharedPreferences.getInstance();
          final jsonString = json.encode(_groups);
          await prefs.setString('podcast_groups', jsonString);
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
  /// If auto-queue is enabled for a podcast, it detects new episodes and returns them.
  Future<List<Map<String, dynamic>>> refreshAllFeeds(String deviceId) async {
       await _ensureInteractedKeysLoaded();
       final List<Map<String, dynamic>> newFoundEpisodes = [];

       for (var podcast in _subscriptions) {
           final url = podcast.url;
           try {
               // If Auto-Queue is enabled, we need "Diff" logic
               if (_autoQueuePodcastUrls.contains(url)) {
                   // 1. Load current cache (Old state)
                   final oldEpisodes = await _loadEpisodeCache(url);
                   final oldGuids = oldEpisodes.map((e) => e.guid).toSet();

                   // 2. Force fetch (New state)
                   // forceRefresh: true ensures we hit the network regardless of cache age
                   final newEpisodes = await fetchEpisodes(url, forceRefresh: true);
                   
                   // 3. Find diff (Present in New, NOT in Old)
                   final diff = newEpisodes.where((e) => !oldGuids.contains(e.guid)).toList();

                   if (diff.isNotEmpty) {
                       for (var episode in diff) {
                           newFoundEpisodes.add({
                               'podcast': podcast,
                               'episode': episode,
                           });
                       }
                   }
               } else {
                   // Just refresh cache, minimal processing
                   await fetchEpisodes(url, forceRefresh: true);
               }
           } catch (e) {
               Log.e('PodcastProvider', 'Feed refresh failed for $url: $e');
           }
       }
       
       // Update filters after content refresh
       // Need downloadedUrls... slightly inefficient to fetch here but safer for consistency.
       // Ideally LibraryScreen calls it, but let's leave it to the caller (LibraryScreen) 
       // to allow UI feedback before/after filters update.
       
       return newFoundEpisodes;
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
              
              // 3. Find diff (Present in New, NOT in Old)
              final diff = newEpisodes.where((e) => !oldGuids.contains(e.guid)).toList();

              if (diff.isNotEmpty) {
                  final podcast = _subscriptions.firstWhere(
                      (p) => p.url == url,
                      orElse: () => Podcast(url: url, title: 'Unknown Podcast'),
                  );

                  for (var episode in diff) {
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
      final directory = await getApplicationDocumentsDirectory();
      // Use Uuid v5 (Name based) for stable filenames across isolates
      final filename = 'episodes_${const Uuid().v5(Uuid.NAMESPACE_URL, url)}.json';
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
              )).toList();
          }
      } catch (e) {
          Log.e('PodcastProvider', 'Error loading episode cache for $url: $e');
      }
      return [];
  }

  Future<List<Episode>> fetchEpisodes(String rssUrl, {bool forceRefresh = false, bool ignoreCacheAge = false}) async {
    // 1. Check local cache first
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
                    return cached;
                 }
            }
        }
    } catch (e) {
        Log.d('PodcastProvider', 'Cache check failed for $rssUrl: $e');
    }

    // 2. Network fetch
    try {
        final episodes = await _rssService.fetchEpisodes(rssUrl);
        // Cache success
        await _saveEpisodeCache(rssUrl, episodes);
        return episodes;
    } catch (e) {
        Log.w('PodcastProvider', 'Network fetch failed for $rssUrl, trying cache fallback. Error: $e');
        // Fallback to cache even if stale (logic above handles success case, this handles failure case)
        final cached = await _loadEpisodeCache(rssUrl);
        if (cached.isNotEmpty) {
            return cached;
        }
        rethrow;
    }
  }

  Future<void> refreshSubscriptions(String deviceId) async {
    if (_api == null) return;

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
                  return await _rssService.getFeedMetadata(url);
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
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> subscribe(String url, String deviceId) async {
    if (_api == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final normalizedUrl = _normalizeUrl(url);

      // Check existence first
      if (_subscriptions.any((p) => _normalizeUrl(p.url) == normalizedUrl)) {
          // Already subscribed
          return;
      }

      // 1. Tell API to add subscription
      await _api!.updateSubscriptions(
        deviceId,
        add: [url],
      );

      // 2. Fetch metadata for local use
      final newPodcast = await _rssService.getFeedMetadata(url);
      
      // 3. Add to local list if not already there (check again)
      if (!_subscriptions.any((p) => _normalizeUrl(p.url) == _normalizeUrl(newPodcast.url))) {
        _subscriptions.add(newPodcast);
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

  Future<void> removePodcast(String url, String deviceId) async {
    if (_api == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      // 1. Tell API to remove subscription
      await _api!.updateSubscriptions(
        deviceId,
        remove: [url],
      );

      // 2. Remove from local list
      _subscriptions.removeWhere((p) => p.url == url);
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
      _error = e.toString();
      rethrow;
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
    if (_api == null) return [];
    
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
    if (_api == null) return [];

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
    if (_api == null) return;
    
    _isLoading = true;
    notifyListeners();
    
    try {
        final action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.guid,
            action: 'play',
            device: deviceId,
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            started: 0,
            position: 0,
            total: episode.duration?.inSeconds ?? 0,
        );
        await _api!.uploadEpisodeActions([action]);
    } catch (e) {
       _error = e.toString();
       rethrow;
    } finally {
        _isLoading = false;
        notifyListeners();
    }
  }

  Future<void> markEpisodesAsPlayed(List<Map<String, dynamic>> items, String deviceId) async {
    if (_api == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final actions = items.map((item) {
        final podcast = item['podcast'] as Podcast;
        final episode = item['episode'] as Episode;
        final duration = episode.duration?.inSeconds ?? 0;
        
        return EpisodeAction(
          podcast: podcast.url,
          episode: episode.guid,
          action: 'play',
          device: deviceId,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          started: 0,
          position: duration, // Mark as fully played
          total: duration,
        );
      }).toList();

      await _api!.uploadEpisodeActions(actions);

      await _api!.uploadEpisodeActions(actions);

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

  Future<void> markAllEpisodesAsInteracted(String podcastUrl, List<String> episodeGuids) async {
      try {
          final prefs = await SharedPreferences.getInstance();
          
          await _ensureInteractedKeysLoaded();
          
          for (var guid in episodeGuids) {
              final key = 'interacted_${podcastUrl}_$guid';
              await prefs.setBool(key, true);
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
       return !_interactedKeys.contains(key);
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
             if (!_interactedKeys.contains(key)) {
                 // Found one that we haven't interacted with!
                 // Wait, we also need to check if it's "Played" or "In Progress" on server?
                 // Technically "New" implies not played.
                 // But fetching server status for every podcast in the library is too heavy.
                 // Simplification: If local interaction is missing, we assume "New".
                 // The standard behavior is: "New" means I haven't clicked it. 
                 // If I listened on another device, it might still show as "New" here until a full sync.
                 // That is acceptable for this feature (Library view).
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
      if (_api == null) return statuses;

      try {
          // 1. Get Actions (server state)
          // Ideally we cache this too, but for now fetch fresh or rely on what we have if we cached actions separately
          // Optimization: fetchInProgressEpisodes uses getEpisodeActions which might be heavy for a list.
          // Let's assume we want to call getEpisodeActions once per screen load or cache it.
          // For now, let's just fetch actions. To avoid hitting server too hard, maybe we should cache actions in the provider?
          // But getEpisodeActions is per device. 
          
          List<EpisodeAction> actions = [];
          try {
             actions = await _api!.getEpisodeActions(deviceId);
          } catch(e) {
             Log.d('PodcastProvider', 'Error fetching actions for status: $e');
             // Proceed with empty actions (offline/error)
          }

          // Filter actions for this podcast
          final simpleActions = <String, EpisodeAction>{};
          for (var action in actions) {
              if (action.podcast == podcastUrl) {
                  final key = action.episode;
                  final existing = simpleActions[key];
                  if (existing == null || action.timestamp > existing.timestamp) {
                      simpleActions[key] = action;
                  }
              }
          }

          // We don't have the list of episodes here, we return a map for the UI to use
          // UI iterates its episodes and checks this map.
          // Wait, we need to know all episode GUIDs to check "New".
          // Actually, "New" is the absence of interaction AND absence of server action.
          // But the UI needs to know if it should populate "New".
          // The UI calls this, gets a map: GUID -> 'played' | 'in_progress' | 'new' | 'unplayed'
          
          // Since we can't iterate all possible episodes here easily without fetching the feed again,
          // we will provide a helper function or assume UI checks individual "isNew" logic.
          // Better: Return a Map containing known states for GUIDs. 
          // If a GUID is NOT in the map, the UI checks 'interacted' storage. If not interacted, it's New.
          
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
}
