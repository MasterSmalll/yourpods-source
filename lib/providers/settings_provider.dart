import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/log_service.dart';
import '../models/sync_conflict.dart';

enum ActionButtonStyle {
  textAndIcon,
  iconOnly,
  textOnly
}

class SettingsProvider with ChangeNotifier {
  ActionButtonStyle _actionButtonStyle = ActionButtonStyle.textAndIcon;
  bool _hidePlayedEpisodes = false;
  int _syncInterval = 30;
  int _feedCacheDuration = 24;
  bool _showPercentListened = false;
  bool _enableListenerStats = false;

  ActionButtonStyle get actionButtonStyle => _actionButtonStyle;
  bool get hidePlayedEpisodes => _hidePlayedEpisodes;
  int get syncInterval => _syncInterval;
  int get feedCacheDuration => _feedCacheDuration;
  bool get showPercentListened => _showPercentListened;
  bool get enableListenerStats => _enableListenerStats;

  bool _autoSyncToWatch = false;
  int _watchSyncCount = 3;

  bool _backgroundRefreshEnabled = true;
  int _backgroundRefreshInterval = 15; // minutes

  bool get autoSyncToWatch => _autoSyncToWatch;
  int get watchSyncCount => _watchSyncCount;

  bool get backgroundRefreshEnabled => _backgroundRefreshEnabled;
  int get backgroundRefreshInterval => _backgroundRefreshInterval;

  // Search Provider Settings
  String _searchProviderId = 'itunes'; // default
  String _podcastIndexApiKey = '';
  String _podcastIndexApiSecret = '';

  String get searchProviderId => _searchProviderId;
  String get podcastIndexApiKey => _podcastIndexApiKey;
  String get podcastIndexApiSecret => _podcastIndexApiSecret;

  SyncStrategy _syncConflictStrategy = SyncStrategy.ask;
  SyncStrategy get syncConflictStrategy => _syncConflictStrategy;


  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  SettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load Action Button Style
    final styleIndex = prefs.getInt('action_button_style') ?? 0;
    if (styleIndex >= 0 && styleIndex < ActionButtonStyle.values.length) {
        _actionButtonStyle = ActionButtonStyle.values[styleIndex];
    }

    // Load Hide Played Episodes
    _hidePlayedEpisodes = prefs.getBool('hide_played_episodes') ?? false;

    // Load Sync Interval
    _syncInterval = prefs.getInt('sync_interval') ?? 30;

    // Load Feed Cache Duration
    _feedCacheDuration = prefs.getInt('feed_cache_hours') ?? 24;

    // Load Show Percent Listened
    _showPercentListened = prefs.getBool('show_percent_listened') ?? false;

    // Load Enable Listener Stats
    _enableListenerStats = prefs.getBool('enable_listener_stats') ?? false;

    // Load Watch Settings
    _autoSyncToWatch = prefs.getBool('auto_sync_to_watch') ?? false;
    _watchSyncCount = prefs.getInt('watch_sync_count') ?? 3;

    // Load Background Refresh Settings
    _backgroundRefreshEnabled = prefs.getBool('background_refresh_enabled') ?? true;
    _backgroundRefreshInterval = prefs.getInt('background_refresh_interval') ?? 15;

    // Load Search Provider Settings
    _searchProviderId = prefs.getString('search_provider_id') ?? 'itunes';
    _podcastIndexApiKey = await _secureStorage.read(key: 'podcastindex_api_key') ?? '';
    _podcastIndexApiSecret = await _secureStorage.read(key: 'podcastindex_api_secret') ?? '';

    _podcastIndexApiSecret = await _secureStorage.read(key: 'podcastindex_api_secret') ?? '';

    // Load Sync Conflict Strategy
    final syncStratIndex = prefs.getInt('sync_conflict_strategy') ?? SyncStrategy.ask.index;
    if (syncStratIndex >= 0 && syncStratIndex < SyncStrategy.values.length) {
        _syncConflictStrategy = SyncStrategy.values[syncStratIndex];
    }

    notifyListeners();
  }

  Future<void> setActionButtonStyle(ActionButtonStyle style) async {
    _actionButtonStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('action_button_style', style.index);
  }

  Future<void> setHidePlayedEpisodes(bool hide) async {
    _hidePlayedEpisodes = hide;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_played_episodes', hide);
  }

  Future<void> setSyncInterval(int seconds) async {
    if (seconds < 10) seconds = 10; // Minimum limit
    _syncInterval = seconds;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sync_interval', seconds);
  }

  Future<void> setFeedCacheDuration(int hours) async {
    _feedCacheDuration = hours;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('feed_cache_hours', hours);
  }

  Future<void> setShowPercentListened(bool show) async {
    _showPercentListened = show;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_percent_listened', show);
  }

  Future<void> setAutoSyncToWatch(bool enabled) async {
    _autoSyncToWatch = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync_to_watch', enabled);
  }

  Future<void> setWatchSyncCount(int count) async {
    if (count < 1) count = 1;
    if (count > 10) count = 10;
    _watchSyncCount = count;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('watch_sync_count', count);
  }

  Future<void> setBackgroundRefreshEnabled(bool enabled) async {
    _backgroundRefreshEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_refresh_enabled', enabled);
  }

  Future<void> setBackgroundRefreshInterval(int minutes) async {
    if (minutes < 15) minutes = 15; // iOS minimum
    _backgroundRefreshInterval = minutes;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('background_refresh_interval', minutes);
  }

  Future<void> setSearchProviderId(String providerId) async {
    _searchProviderId = providerId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('search_provider_id', providerId);
  }

  Future<void> setPodcastIndexApiKey(String key) async {
    _podcastIndexApiKey = key;
    notifyListeners();
    await _secureStorage.write(key: 'podcastindex_api_key', value: key);
  }

  Future<void> setPodcastIndexApiSecret(String secret) async {
    _podcastIndexApiSecret = secret;
    notifyListeners();
    await _secureStorage.write(key: 'podcastindex_api_secret', value: secret);
  }

  Future<void> setEnableListenerStats(bool enabled) async {
    _enableListenerStats = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('enable_listener_stats', enabled);

    if (!enabled) {
      // Clear local stats cache when disabled
      // Note: ListeningStatsService.clearCache() will be implemented next
      Log.i('SettingsProvider', 'Listener stats disabled, clearing cache...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('listening_stats_cache');
    }
  }

  Future<void> setSyncConflictStrategy(SyncStrategy strategy) async {
      _syncConflictStrategy = strategy;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('sync_conflict_strategy', strategy.index);
  }
}
