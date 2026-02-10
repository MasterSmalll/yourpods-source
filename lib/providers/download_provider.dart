import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../services/log_service.dart';

enum DownloadState {
  none,
  downloading,
  downloaded,
  error,
}

class DownloadProvider with ChangeNotifier {
  final Dio _dio = Dio();
  final Map<String, DownloadState> _status = {};
  final Map<String, double> _progress = {};
  final Map<String, CancelToken> _cancelTokens = {};

  DownloadState getStatus(String url) => _status[url] ?? DownloadState.none;
  double getProgress(String url) => _progress[url] ?? 0.0;
  
  Set<String> get downloadedUrls {
      return _status.entries
          .where((e) => e.value == DownloadState.downloaded)
          .map((e) => e.key)
          .toSet();
  }
  
  // Initialize by checking existing files
  // (In a real app, we'd persist a map of downloaded IDs, but checking files is a decent MVP)
  Future<void> _checkExistingFile(String url) async {
      final path = await _getLocalPath(url);
      if (await File(path).exists()) {
          _status[url] = DownloadState.downloaded;
          // No notify here to avoid build loops if called during build, 
          // usually called on init.
      }
  }

  Future<String> _getLocalPath(String url) async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${directory.path}/downloads');
    if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
    }
    // Safe filename
    final filename = 'ep_${url.hashCode}.mp3';
    return '${downloadsDir.path}/$filename';
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
            notifyListeners();
          }
        },
      );

      _status[url] = DownloadState.downloaded;
      _cancelTokens.remove(url);
      notifyListeners();
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
          _status[url] = DownloadState.none;
      } else {
          Log.e('DownloadProvider', 'Download error for $url: $e');
          _status[url] = DownloadState.error;
      }
      _cancelTokens.remove(url);
      notifyListeners();
    }
  }

  Future<void> cancelDownload(String url) async {
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
