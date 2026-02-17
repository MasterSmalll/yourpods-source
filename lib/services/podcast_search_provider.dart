import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../models/podcast_search_result.dart';
import 'log_service.dart';

/// Abstract base class for podcast search providers.
abstract class PodcastSearchProvider {
  String get name;
  String get id;
  bool get requiresApiKey;

  Future<List<PodcastSearchResult>> search(String query);
}

// ---------------------------------------------------------------------------
// iTunes Search Provider
// ---------------------------------------------------------------------------

class ITunesSearchProvider extends PodcastSearchProvider {
  @override
  String get name => 'iTunes';

  @override
  String get id => 'itunes';

  @override
  bool get requiresApiKey => false;

  @override
  Future<List<PodcastSearchResult>> search(String query) async {
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': query,
      'media': 'podcast',
      'limit': '25',
    });

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        Log.e('ITunesSearch', 'HTTP ${response.statusCode}');
        return [];
      }

      final data = json.decode(response.body);
      final List results = data['results'] ?? [];

      return results.map((item) {
        return PodcastSearchResult(
          title: item['collectionName'] ?? item['trackName'] ?? 'Unknown',
          feedUrl: item['feedUrl'] ?? '',
          artworkUrl: item['artworkUrl600'] ?? item['artworkUrl100'],
          author: item['artistName'],
          description: item['collectionName'],
        );
      }).where((r) => r.feedUrl.isNotEmpty).toList();
    } catch (e) {
      Log.e('ITunesSearch', 'Search failed: $e');
      return [];
    }
  }
}

// ---------------------------------------------------------------------------
// PodcastIndex Search Provider
// ---------------------------------------------------------------------------

class PodcastIndexSearchProvider extends PodcastSearchProvider {
  final String apiKey;
  final String apiSecret;

  PodcastIndexSearchProvider({
    required this.apiKey,
    required this.apiSecret,
  });

  @override
  String get name => 'PodcastIndex';

  @override
  String get id => 'podcastindex';

  @override
  bool get requiresApiKey => true;

  /// Build the auth headers required by PodcastIndex API.
  /// See: https://podcastindex-org.github.io/docs-api/#auth
  Map<String, String> _buildAuthHeaders() {
    final epoch = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    final authString = '$apiKey$apiSecret$epoch';
    final hash = sha1.convert(utf8.encode(authString)).toString();

    return {
      'X-Auth-Date': '$epoch',
      'X-Auth-Key': apiKey,
      'Authorization': hash,
      'User-Agent': 'YourPods/1.0',
    };
  }

  @override
  Future<List<PodcastSearchResult>> search(String query) async {
    if (apiKey.isEmpty || apiSecret.isEmpty) {
      Log.w('PodcastIndexSearch', 'API key or secret not configured');
      return [];
    }

    final uri = Uri.https('api.podcastindex.org', '/api/1.0/search/byterm', {
      'q': query,
      'max': '25',
    });

    try {
      final response = await http.get(uri, headers: _buildAuthHeaders());
      if (response.statusCode != 200) {
        Log.e('PodcastIndexSearch', 'HTTP ${response.statusCode}: ${response.body}');
        return [];
      }

      final data = json.decode(response.body);
      final List feeds = data['feeds'] ?? [];

      return feeds.map((item) {
        return PodcastSearchResult(
          title: item['title'] ?? 'Unknown',
          feedUrl: item['url'] ?? '',
          artworkUrl: item['artwork'] ?? item['image'],
          author: item['author'],
          description: item['description'],
        );
      }).where((r) => r.feedUrl.isNotEmpty).toList();
    } catch (e) {
      Log.e('PodcastIndexSearch', 'Search failed: $e');
      return [];
    }
  }
}
