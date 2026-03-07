import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/log_service.dart';

enum DownloadState {
  none,
  downloading,
  downloaded,
  error,
  /// Download paused because device switched to cellular and
  /// the user has WiFi-only downloads enabled.
  pausedCellular,
}

class DownloadProvider with ChangeNotifier {
  final Dio _dio = Dio();
  final Map<String, DownloadState> _status = {};
  final Map<String, double> _progress = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, String> _errors = {};

  /// Whether downloads are allowed on cellular networks.
  /// Updated from SettingsProvider.
  bool _downloadOnCellular = false;
  bool get downloadOnCellular => _downloadOnCellular;

  /// Tracks URLs that were paused due to cellular switch so they can be
  /// automatically resumed when WiFi is restored.
  final Set<String> _cellularPausedUrls = {};

  // Throttle: only fire notifyListeners at most every 500ms for progress
  DateTime _lastProgressNotify = DateTime(0);

  DownloadState getStatus(String url) => _status[url] ?? DownloadState.none;
  double getProgress(String url) => _progress[url] ?? 0.0;
  String? getError(String url) => _errors[url];
  
  Set<String> get downloadedUrls {
      return _status.entries
          .where((e) => e.value == DownloadState.downloaded)
          .map((e) => e.key)
          .toSet();
  }

  DownloadProvider() {
    _listenToConnectivity();
  }

  /// Update the cellular download preference from settings.
  void setDownloadOnCellular(bool allowed) {
    _downloadOnCellular = allowed;
  }

  /// Listen for connectivity changes and pause/resume downloads accordingly.
  void _listenToConnectivity() {
    Connectivity().onConnectivityChanged.listen((results) {
      // connectivity_plus v6 sends a List<ConnectivityResult>
      final isWifi = results.contains(ConnectivityResult.wifi);
      final isNone = results.every((r) => r == ConnectivityResult.none);

      if (isNone) {
        // No connectivity — all active downloads will fail on their own
        return;
      }

      if (!isWifi && !_downloadOnCellular) {
        // Switched to cellular with WiFi-only downloads — pause active downloads
        _pauseActiveDownloads();
      } else if (isWifi && _cellularPausedUrls.isNotEmpty) {
        // WiFi restored — resume previously paused downloads
        _resumePausedDownloads();
      }
    });
  }

  void _pauseActiveDownloads() {
    final activeUrls = _status.entries
        .where((e) => e.value == DownloadState.downloading)
        .map((e) => e.key)
        .toList();

    for (final url in activeUrls) {
      if (_cancelTokens.containsKey(url)) {
        _cancelTokens[url]!.cancel('cellular_pause');
        _status[url] = DownloadState.pausedCellular;
        _cellularPausedUrls.add(url);
        Log.i('DownloadProvider', 'Paused download (cellular): $url');
      }
    }
    if (activeUrls.isNotEmpty) notifyListeners();
  }

  void _resumePausedDownloads() {
    final toResume = Set<String>.from(_cellularPausedUrls);
    _cellularPausedUrls.clear();
    for (final url in toResume) {
      Log.i('DownloadProvider', 'Resuming download (WiFi restored): $url');
      downloadEpisode(url);
    }
  }
  
  // Initialize by checking existing files
  Future<void> _checkExistingFile(String url) async {
      final path = await _getLocalPath(url);
      if (await File(path).exists()) {
          _status[url] = DownloadState.downloaded;
      }
  }

  Future<String> _getLocalPath(String url) async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${directory.path}/downloads');
    if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
    }
    // Stable, collision-resistant filename using sha256
    final hash = sha256.convert(utf8.encode(url)).toString().substring(0, 16);
    final newPath = '${downloadsDir.path}/ep_$hash.mp3';

    // If new file already exists, use it
    if (await File(newPath).exists()) return newPath;

    // Check for legacy hashCode-based filename and migrate it
    final legacyPath = '${downloadsDir.path}/ep_${url.hashCode}.mp3';
    if (await File(legacyPath).exists()) {
      await File(legacyPath).rename(newPath);
      Log.i('DownloadProvider', 'Migrated download to new filename scheme');
    }

    return newPath;
  }

  Future<String?> getDownloadedPath(String url) async {
      final path = await _getLocalPath(url);
      if (await File(path).exists()) {
          return path;
      }
      return null;
  }

  Future<bool> isDownloaded(String url) async {
    final path = await getDownloadedPath(url);
    return path != null;
  }

  // Check state for a list of URLs (e.g. when opening a screen)
  Future<void> checkDownloads(List<String> urls) async {
      for (var url in urls) {
          if (!_status.containsKey(url)) {
             await _checkExistingFile(url);
          }
      }
      notifyListeners();
  }

  Future<void> downloadEpisode(String url) async {
    if (_status[url] == DownloadState.downloading) return;

    _status[url] = DownloadState.downloading;
    _progress[url] = 0.0;
    _errors.remove(url);
    Log.i('DownloadProvider', 'Starting download: $url');
    notifyListeners();

    try {
      final savePath = await _getLocalPath(url);
      final cancelToken = CancelToken();
      _cancelTokens[url] = cancelToken;

      await _dio.download(
        url,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            _progress[url] = received / total;
            // Throttle UI notifications to ~2Hz to reduce widget rebuilds
            final now = DateTime.now();
            if (now.difference(_lastProgressNotify).inMilliseconds >= 500) {
              _lastProgressNotify = now;
              notifyListeners();
            }
          }
        },
      );

      _status[url] = DownloadState.downloaded;
      _cancelTokens.remove(url);
      notifyListeners(); // Always notify on completion
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
          // Check if this was a cellular pause vs user cancel
          if (e.message == 'cellular_pause') {
            // Already handled in _pauseActiveDownloads
          } else {
            _status[url] = DownloadState.none;
          }
      } else {
          Log.e('DownloadProvider', 'Download error for $url: $e');
          _status[url] = DownloadState.error;
          _errors[url] = e is DioException
              ? (e.message ?? 'Download failed')
              : e.toString();
      }
      _cancelTokens.remove(url);
      notifyListeners();
    }
  }

  Future<void> cancelDownload(String url) async {
      _cellularPausedUrls.remove(url);
      if (_cancelTokens.containsKey(url)) {
          _cancelTokens[url]!.cancel();
      }
  }

  Future<void> deletedownload(String url) async {
      try {
          final path = await _getLocalPath(url);
          final file = File(path);
          if (await file.exists()) {
              await file.delete();
          }
          _status[url] = DownloadState.none;
          _progress[url] = 0.0;
          notifyListeners();
      } catch (e) {
          Log.e('DownloadProvider', 'Error deleting file: $e');
      }
  }
}
