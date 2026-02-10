import 'dart:convert';
import 'package:http/http.dart' as http;
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

  final Map<String, List<Chapter>> _cache = {};

  /// Fetch and parse chapters from a Podcasting 2.0 chapters JSON URL.
  /// Returns an empty list on any failure (network, parse, etc.).
  Future<List<Chapter>> fetchChapters(String chaptersUrl) async {
    // Return cached result if available
    if (_cache.containsKey(chaptersUrl)) {
      return _cache[chaptersUrl]!;
    }

    try {
      final response = await http
          .get(Uri.parse(chaptersUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final chaptersJson = data['chapters'] as List<dynamic>?;

        if (chaptersJson != null) {
          final chapters = chaptersJson
              .map((c) => Chapter.fromJson(c as Map<String, dynamic>))
              .toList();

          // Sort by startTime ascending
          chapters.sort((a, b) => a.startTime.compareTo(b.startTime));

          _cache[chaptersUrl] = chapters;
          return chapters;
        }
      }
    } catch (e) {
      Log.e('ChapterService', 'Error fetching chapters from $chaptersUrl: $e');
    }

    return [];
  }

  /// Clear the in-memory cache. Useful on profile switch.
  void clearCache() {
    _cache.clear();
  }
}
