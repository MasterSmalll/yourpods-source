import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../providers/podcast_provider.dart';
import '../services/log_service.dart';
import '../models/server_profile.dart';
import '../api/gpodder_api.dart';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  ),
);

Future<void> _performMultiProfileSync() async {
  try {
    final jsonString = await _storage.read(key: 'server_profiles');
    if (jsonString == null) {
      Log.d('BackgroundRefresh', 'No profiles found, skipping sync.');
      return;
    }

    final List<dynamic> jsonList = json.decode(jsonString);
    final profiles = <ServerProfile>[];
    for (var item in jsonList) {
      try {
        profiles.add(ServerProfile.fromJson(item));
      } catch (e) {
        Log.e('BackgroundRefresh', 'Failed to parse a profile: $e');
      }
    }

    for (var profile in profiles) {
      if (profile.isLocal) {
        Log.d('BackgroundRefresh', 'Skipping local profile: ${profile.id}');
        continue;
      }

      Log.i('BackgroundRefresh', 'Syncing profile: ${profile.id}');

      final api = GPodderApi(
        baseUrl: profile.baseUrl,
        username: profile.username,
        password: profile.password ?? '',
      );

      final provider = PodcastProvider();
      provider.setApi(api, profile.id);

      // Wait briefly for the provider to load caches
      await Future.delayed(const Duration(milliseconds: 500));

      final newEpisodes = await provider.refreshAllFeeds(profile.deviceId);
      await provider.syncEpisodeActions(profile.deviceId);

      if (newEpisodes.isNotEmpty) {
        Log.i('BackgroundRefresh', 'Profile ${profile.id}: Found ${newEpisodes.length} new auto-queue episodes');
      } else {
        Log.d('BackgroundRefresh', 'Profile ${profile.id}: Feeds refreshed, no new auto-queue episodes');
      }
    }
  } catch (e) {
    Log.e('BackgroundRefresh', 'Sync error: $e');
  }
}

/// Top-level headless callback for background fetch.
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

  await _performMultiProfileSync();

  BackgroundFetch.finish(taskId);
}

/// Service that manages background feed refresh on iOS.
class BackgroundRefreshService {
  static final BackgroundRefreshService _instance = BackgroundRefreshService._internal();
  factory BackgroundRefreshService() => _instance;
  BackgroundRefreshService._internal();

  bool _configured = false;

  Future<void> init() async {
    if (!_shouldRun()) return;

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('background_refresh_enabled') ?? true;
    final intervalMinutes = prefs.getInt('background_refresh_interval') ?? 60;

    if (!enabled) {
      Log.d('BackgroundRefresh', 'Disabled by user setting');
      return;
    }

    await _configure(intervalMinutes);
  }

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

  static void _onBackgroundFetch(String taskId) async {
    Log.d('BackgroundRefresh', 'Event received: $taskId');

    await _performMultiProfileSync();

    BackgroundFetch.finish(taskId);
  }

  static void _onBackgroundFetchTimeout(String taskId) {
    Log.w('BackgroundRefresh', 'Task timed out: $taskId');
    BackgroundFetch.finish(taskId);
  }

  /// Start background fetch (e.g., when user enables it in settings).
  Future<void> start({int intervalMinutes = 60}) async {
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
