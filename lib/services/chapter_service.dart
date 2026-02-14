import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../models/podcast.dart';
import 'log_service.dart';

/// Service that fetches and caches Podcasting 2.0 chapter data.
///
/// Chapters are hosted as external JSON files referenced by
/// `<podcast:chapters url="..." />` in the RSS feed. This service
/// fetches the JSON, parses it into [Chapter] objects, and caches
/// results in memory to avoid redundant network requests.
class ChapterService {
  static final ChapterService _instance = ChapterService._internal();
  factory ChapterService() => _instance;
  ChapterService._internal();

  /// Fetch and parse chapters from a Podcasting 2.0 chapters JSON URL.
  /// Returns an empty list on any failure (network, parse, etc.).
  /// [cacheDurationHours] defaults to 24 if not provided.
  Future<List<Chapter>> fetchChapters(String chaptersUrl, {int cacheDurationHours = 24}) async {
    try {
      final cacheFile = await _getCacheFile(chaptersUrl);

      // 1. Check Cache
      if (await cacheFile.exists()) {
          final lastModified = await cacheFile.lastModified();
          final age = DateTime.now().difference(lastModified);
          if (age.inHours < cacheDurationHours) {
              final content = await cacheFile.readAsString();
              if (content.isNotEmpty) {
                  return _parseChaptersJson(content);
              }
          }
      }
    
      final response = await http
          .get(Uri.parse(chaptersUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final content = response.body;
        
        // 2. Save to Cache
        await cacheFile.writeAsString(content);

        return _parseChaptersJson(content);
      }
    } catch (e) {
      Log.e('ChapterService', 'Error fetching chapters from $chaptersUrl: $e');
    }

    return [];
  }

  Future<File> _getCacheFile(String url) async {
      final directory = await getTemporaryDirectory();
      // Use MD5 hash of URL for filename
      final hash = md5.convert(utf8.encode(url)).toString();
      return File('${directory.path}/chapters_$hash.cache');
  }

  List<Chapter> _parseChaptersJson(String jsonString) {
      try {
        final data = json.decode(jsonString) as Map<String, dynamic>;
        final chaptersJson = data['chapters'] as List<dynamic>?;

        if (chaptersJson != null) {
          final chapters = chaptersJson
              .map((c) => Chapter.fromJson(c as Map<String, dynamic>))
              .toList();

          // Sort by startTime ascending
          chapters.sort((a, b) => a.startTime.compareTo(b.startTime));
          return chapters;
        }
      } catch (e) {
         Log.e('ChapterService', 'Error parsing chapters JSON: $e');
      }
      return [];
  }

  /// Clear the cache file for a specific URL (if needed) or all (not easily done without directory scan).
  /// For now, keeping method signature but making it no-op or TODO since file cache is handled by duration.
  /// If we really need to clear all, we'd need to list the temp dir.
  Future<void> clearCache() async {
      final directory = await getTemporaryDirectory();
      if (await directory.exists()) {
          final files = directory.listSync();
          for (var file in files) {
             if (file is File && file.path.contains('chapters_') && file.path.endsWith('.cache')) {
                 try {
                     await file.delete();
                 } catch (e) {
                     // ignore
                 }
             }
          }
      }
  }
}

