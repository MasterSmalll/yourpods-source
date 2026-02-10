import 'package:http/http.dart' as http;
import 'package:dart_rss/dart_rss.dart';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:xml/xml.dart' as xml;
import '../models/podcast.dart';

class RssService {
  Future<List<Episode>> fetchEpisodes(String rssUrl) async {
    try {
      final response = await http.get(Uri.parse(rssUrl)).timeout(const Duration(seconds: 30));
    
      if (response.statusCode == 200) {
      final feed = RssFeed.parse(response.body);
      
      // Parse raw XML to extract podcast:chapters URLs per item
      final chaptersMap = _parseChaptersUrls(response.body);
      
      return feed.items.map((item) {
        final guid = item.guid ?? item.link ?? '';
        final resolvedChaptersUrl = chaptersMap[guid] ?? chaptersMap[item.title];

        return Episode(
          guid: guid,
          title: item.title ?? 'No Title',
          description: item.content?.value ?? item.itunes?.summary ?? item.description,
          audioUrl: item.enclosure?.url,
          pubDate: _parseDate(item.pubDate),
          imageUrl: item.itunes?.image?.href,
          duration: _parseDuration(item.itunes?.duration?.toString()),
          link: item.link,
          chaptersUrl: resolvedChaptersUrl,
        );
      }).toList();
    } else {
      throw Exception('Failed to fetch RSS feed: ${response.statusCode}');
    }
    } catch (e) {
      throw Exception('Error fetching RSS feed: $e');
    }
  }

  /// Parse <podcast:chapters url="..." /> from raw RSS XML.
  /// Returns a map from guid (or title if no guid) to chapters URL.
  Map<String, String?> _parseChaptersUrls(String rawXml) {
    final map = <String, String?>{};
    try {
      final document = xml.XmlDocument.parse(rawXml);
      final items = document.findAllElements('item');
      for (final item in items) {
        String? chaptersUrl;
        // Look for <podcast:chapters> element
        for (final child in item.children) {
          if (child is xml.XmlElement) {
            final localName = child.name.local;
            if (localName == 'chapters' && child.getAttribute('url') != null) {
              chaptersUrl = child.getAttribute('url');
              break;
            }
          }
        }
        if (chaptersUrl != null) {
          // Key by guid first, fallback to title
          final guidEl = item.findElements('guid').firstOrNull;
          final titleEl = item.findElements('title').firstOrNull;
          final key = guidEl?.innerText ?? titleEl?.innerText;
          if (key != null) {
            map[key] = chaptersUrl;
          }
        }
      }
    } catch (_) {
      // Silently ignore chapter parsing errors
    }
    return map;
  }

  Future<Podcast> getFeedMetadata(String rssUrl) async {
    final response = await http.get(Uri.parse(rssUrl));
    
    if (response.statusCode == 200) {
      final feed = RssFeed.parse(response.body);
      return Podcast(
        url: rssUrl,
        title: feed.title ?? 'Unknown Podcast',
        description: feed.description,
        logoUrl: feed.itunes?.image?.href ?? feed.image?.url,
        website: feed.link,
      );
    } else {
      // Return a basic object if fetch fails
      return Podcast(url: rssUrl, title: rssUrl);
    }
  }

  DateTime? _parseDate(String? dateString) {
    if (dateString == null) return null;
    
    // List of formats to try
    // RSS Spec (RFC 822) says: Mon, 02 Oct 2002 15:00:00 +0200
    // But feeds are messy.
    final formats = [
      'EEE, dd MMM yyyy HH:mm:ss Z',
      'EEE, dd MMM yyyy HH:mm:ss zzz',
      'dd MMM yyyy HH:mm:ss Z',
      'dd MMM yyyy HH:mm:ss zzz',
      'EEE, dd MMM yyyy HH:mm:ss', // No timezone
      'yyyy-MM-ddTHH:mm:ss', // ISO-ish
    ];

    // 1. Try HttpDate first (handles RFC-1123 robustly)
    try {
      return HttpDate.parse(dateString);
    } catch (_) {}

    // 2. Try patterns
    for (var format in formats) {
      try {
        return DateFormat(format, 'en_US').parse(dateString);
      } catch (_) {}
    }

    // 3. Last resort fallback
    return DateTime.tryParse(dateString);
  }

  Duration? _parseDuration(String? durationString) {
    if (durationString == null) return null;
    final parts = durationString.split(':');
    if (parts.length == 3) {
      return Duration(
        hours: int.tryParse(parts[0]) ?? 0,
        minutes: int.tryParse(parts[1]) ?? 0,
        seconds: int.tryParse(parts[2]) ?? 0,
      );
    } else if (parts.length == 2) {
      return Duration(
        minutes: int.tryParse(parts[0]) ?? 0,
        seconds: int.tryParse(parts[1]) ?? 0,
      );
    } else if (parts.length == 1) {
       // Treat as seconds
       return Duration(seconds: int.tryParse(parts[0]) ?? 0);
    }
    return null;
  }
}
