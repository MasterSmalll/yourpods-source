import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/podcast_provider.dart';
import '../services/log_service.dart';

/// Top-level headless callback for background fetch.
/// Must be a top-level or static function (Flutter requirement).
@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessTask task) async {
  final taskId = task.taskId;
  final isTimeout = task.timeout;

  if (isTimeout) {
    Log.w('BackgroundRefresh', 'Headless task timed out: $taskId');
    BackgroundFetch.finish(taskId);
    return;
  }

  Log.d('BackgroundRefresh', 'Headless task started: $taskId');

  try {
    // Create a standalone PodcastProvider to refresh feeds
    final provider = PodcastProvider();
    
    // Wait briefly for the provider to initialize from local storage
    await Future.delayed(const Duration(milliseconds: 500));

    // Load the device ID from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('last_device_id') ?? 'yourpods-ios';

    // Refresh all feeds (updates RSS cache, detects new auto-queue episodes)
    final newEpisodes = await provider.refreshAllFeeds(deviceId);
    
    if (newEpisodes.isNotEmpty) {
      Log.i('BackgroundRefresh', 'Found ${newEpisodes.length} new auto-queue episodes');
    } else {
      Log.d('BackgroundRefresh', 'Feeds refreshed, no new auto-queue episodes');
    }
  } catch (e) {
    Log.e('BackgroundRefresh', 'Headless task error: $e');
  }

  BackgroundFetch.finish(taskId);
}

/// Service that manages background feed refresh on iOS.
/// 
/// Uses the `background_fetch` package to periodically wake the app
/// and refresh podcast RSS feeds, keeping the cache fresh and detecting
/// new episodes for auto-queue.
class BackgroundRefreshService {
  static final BackgroundRefreshService _instance = BackgroundRefreshService._internal();
  factory BackgroundRefreshService() => _instance;
  BackgroundRefreshService._internal();

  bool _configured = false;

  /// Initialize background fetch. Call from main() after WidgetsFlutterBinding.
  Future<void> init() async {
    if (!_shouldRun()) return;

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('background_refresh_enabled') ?? true;
    final intervalMinutes = prefs.getInt('background_refresh_interval') ?? 15;

    if (!enabled) {
      Log.d('BackgroundRefresh', 'Disabled by user setting');
      return;
    }

    await _configure(intervalMinutes);
  }

  /// Configure and start background fetch with the given interval.
  Future<void> _configure(int intervalMinutes) async {
    if (_configured) return;

    try {
      final status = await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: intervalMinutes,
          stopOnTerminate: false,
          startOnBoot: false,
          enableHeadless: true,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresStorageNotLow: false,
          requiresDeviceIdle: false,
          requiredNetworkType: NetworkType.ANY,
        ),
        _onBackgroundFetch,
        _onBackgroundFetchTimeout,
      );

      _configured = true;
      Log.i('BackgroundRefresh', 'Configured with status: $status, interval: ${intervalMinutes}m');
    } catch (e) {
      Log.e('BackgroundRefresh', 'Configuration failed: $e');
    }
  }

  /// Foreground fetch callback.
  static void _onBackgroundFetch(String taskId) async {
    Log.d('BackgroundRefresh', 'Event received: $taskId');

    try {
      final provider = PodcastProvider();
      await Future.delayed(const Duration(milliseconds: 500));

      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('last_device_id') ?? 'yourpods-ios';

      final newEpisodes = await provider.refreshAllFeeds(deviceId);

      if (newEpisodes.isNotEmpty) {
        Log.i('BackgroundRefresh', 'Found ${newEpisodes.length} new auto-queue episodes');
      } else {
        Log.d('BackgroundRefresh', 'Feeds refreshed successfully');
      }
    } catch (e) {
      Log.e('BackgroundRefresh', 'Error during fetch: $e');
    }

    BackgroundFetch.finish(taskId);
  }

  /// Timeout callback — iOS gave us too long; finish immediately.
  static void _onBackgroundFetchTimeout(String taskId) {
    Log.w('BackgroundRefresh', 'Task timed out: $taskId');
    BackgroundFetch.finish(taskId);
  }

  /// Start background fetch (e.g., when user enables it in settings).
  Future<void> start({int intervalMinutes = 15}) async {
    if (!_shouldRun()) return;

    if (!_configured) {
      await _configure(intervalMinutes);
    }
    
    await BackgroundFetch.start();
    Log.i('BackgroundRefresh', 'Started');
  }

  /// Stop background fetch (e.g., when user disables it in settings).
  Future<void> stop() async {
    if (!_shouldRun()) return;

    await BackgroundFetch.stop();
    _configured = false;
    Log.i('BackgroundRefresh', 'Stopped');
  }

  /// Update the fetch interval. Requires reconfiguring.
  Future<void> updateInterval(int intervalMinutes) async {
    if (!_shouldRun()) return;
    
    _configured = false;
    await _configure(intervalMinutes);
    Log.i('BackgroundRefresh', 'Interval updated to ${intervalMinutes}m');
  }

  /// Only run on iOS (not web, not other platforms).
  bool _shouldRun() {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }
}
