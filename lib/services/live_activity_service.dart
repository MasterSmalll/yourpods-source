import 'dart:async';
import 'dart:io';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/live_activity_file.dart';
import 'package:live_activities/models/url_scheme_data.dart';
import '../services/log_service.dart';

/// Service that manages iOS Live Activities / Dynamic Island for podcast playback.
///
/// Sends playback state to the native Widget Extension via the `live_activities`
/// package.  Button taps on the Dynamic Island are received back via URL scheme
/// and forwarded to a callback so [PlayerProvider] can route them to the same
/// play/pause/skip methods used everywhere else.
class LiveActivityService {
  static const String _appGroupId = 'group.com.asecretcompany.yourpods';
  static const String _urlScheme = 'yourpods';
  static const String _activityId = 'yourpods-now-playing';

  final LiveActivities _liveActivities = LiveActivities();
  String? _currentActivityId;
  StreamSubscription<UrlSchemeData>? _urlSchemeSub;

  /// Callback invoked when a button on the Dynamic Island is tapped.
  /// The [action] will be one of: "togglePlay", "skipForward", "skipBackward".
  void Function(String action)? onAction;

  /// Whether the service has been initialised.
  bool _initialized = false;

  /// Initialise the plugin.  Safe to call multiple times — subsequent calls
  /// are no-ops.
  Future<void> init() async {
    if (!Platform.isIOS) return;
    if (_initialized) return;

    await _liveActivities.init(
      appGroupId: _appGroupId,
      urlScheme: _urlScheme,
    );

    _urlSchemeSub = _liveActivities.urlSchemeStream().listen((data) {
      // data.host == "action", data.path == "/togglePlay"
      if (data.host == 'action' && data.path != null && data.path!.isNotEmpty) {
        // Remove leading slash from path
        final action = data.path!.startsWith('/') 
            ? data.path!.substring(1) 
            : data.path!;
        if (action.isNotEmpty) {
          onAction?.call(action);
        }
      }
    });

    _initialized = true;
  }

  /// Start or create a new Live Activity for the currently-playing episode.
  Future<void> startActivity({
    required String episodeTitle,
    required String podcastName,
    String? artUrl,
    required bool isPlaying,
    required int positionSeconds,
    required int durationSeconds,
  }) async {
    if (!Platform.isIOS || !_initialized) return;

    final data = _buildDataMap(
      episodeTitle: episodeTitle,
      podcastName: podcastName,
      artUrl: artUrl,
      isPlaying: isPlaying,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
    );

    // If there is already an active Live Activity, update it instead of
    // creating a duplicate.
    if (_currentActivityId != null) {
      await updateActivity(
        episodeTitle: episodeTitle,
        podcastName: podcastName,
        artUrl: artUrl,
        isPlaying: isPlaying,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
      );
      return;
    }

    try {
      _currentActivityId = await _liveActivities.createActivity(
        _activityId,
        data,
      );
      Log.d('LiveActivityService', 'Created activity $_currentActivityId');
    } catch (e) {
      Log.e('LiveActivityService', 'Error creating activity: $e');
    }
  }

  /// Update the currently-active Live Activity with new state.
  Future<void> updateActivity({
    required String episodeTitle,
    required String podcastName,
    String? artUrl,
    required bool isPlaying,
    required int positionSeconds,
    required int durationSeconds,
  }) async {
    if (!Platform.isIOS || !_initialized) return;
    if (_currentActivityId == null) {
      // No activity running — create one instead.
      await startActivity(
        episodeTitle: episodeTitle,
        podcastName: podcastName,
        artUrl: artUrl,
        isPlaying: isPlaying,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
      );
      return;
    }

    final data = _buildDataMap(
      episodeTitle: episodeTitle,
      podcastName: podcastName,
      artUrl: artUrl,
      isPlaying: isPlaying,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
    );

    try {
      await _liveActivities.updateActivity(_currentActivityId!, data);
    } catch (e) {
      Log.e('LiveActivityService', 'Error updating activity: $e');
    }
  }

  /// End the current Live Activity (e.g. when playback stops).
  Future<void> endActivity() async {
    if (!Platform.isIOS || !_initialized) return;
    if (_currentActivityId == null) return;

    try {
      await _liveActivities.endActivity(_currentActivityId!);
      Log.d('LiveActivityService', 'Ended activity $_currentActivityId');
    } catch (e) {
      Log.e('LiveActivityService', 'Error ending activity: $e');
    }
    _currentActivityId = null;
  }

  /// Build the data map sent to the native Widget Extension via UserDefaults.
  Map<String, dynamic> _buildDataMap({
    required String episodeTitle,
    required String podcastName,
    String? artUrl,
    required bool isPlaying,
    required int positionSeconds,
    required int durationSeconds,
  }) {
    final progressFraction =
        durationSeconds > 0 ? positionSeconds / durationSeconds : 0.0;

    final map = <String, dynamic>{
      'episodeTitle': episodeTitle,
      'podcastName': podcastName,
      'isPlaying': isPlaying,
      'positionSeconds': positionSeconds,
      'durationSeconds': durationSeconds,
      'progressFraction': progressFraction,
    };

    if (artUrl != null && artUrl.isNotEmpty) {
      map['artUri'] = LiveActivityFileFromUrl.image(
        artUrl,
        imageOptions: LiveActivityImageFileOptions(
          resizeFactor: 0.3,
        ),
      );
    }

    return map;
  }

  /// Clean up subscriptions.
  void dispose() {
    _urlSchemeSub?.cancel();
    endActivity();
  }
}
