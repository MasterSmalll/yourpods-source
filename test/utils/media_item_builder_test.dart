import 'package:flutter_test/flutter_test.dart';
import 'package:YourPods/utils/media_item_builder.dart';
import 'package:YourPods/models/podcast.dart';

void main() {
  group('MediaItemBuilder', () {
    test('creates MediaItem with correct fields', () {
      final podcast = Podcast(
        url: 'https://test.com/feed.xml',
        title: 'Test Podcast',
        logoUrl: 'https://test.com/logo.png',
        author: 'Test Author',
      );
      
      final episode = Episode(
        guid: 'ep1',
        title: 'Episode 1',
        audioUrl: 'https://test.com/ep1.mp3',
        description: 'Desc',
        imageUrl: 'https://test.com/ep1.png',
        duration: const Duration(seconds: 300),
      );

      final item = MediaItemBuilder.fromEpisode(podcast, episode);

      expect(item.id, 'ep1');
      expect(item.title, 'Episode 1');
      expect(item.album, 'Test Podcast');
      expect(item.artist, 'Test Author');
      expect(item.duration, const Duration(seconds: 300));
      expect(item.artUri.toString(), 'https://test.com/ep1.png');
      expect(item.extras?['url'], 'https://test.com/ep1.mp3');
      expect(item.extras?['podcastUrl'], 'https://test.com/feed.xml');
    });

    test('falls back to podcast logo if episode image is missing', () {
      final podcast = Podcast(
        url: 'https://test.com/feed.xml',
        title: 'Test Podcast',
        logoUrl: 'https://test.com/logo.png',
      );
      
      final episode = Episode(
        guid: 'ep2',
        title: 'Episode 2',
        audioUrl: 'https://test.com/ep2.mp3',
        // imageUrl is null
      );

      final item = MediaItemBuilder.fromEpisode(podcast, episode);

      expect(item.artUri.toString(), 'https://test.com/logo.png');
    });

    test('merges custom extras', () {
       final podcast = Podcast(url: 'p', title: 'P');
       final episode = Episode(guid: 'e', title: 'E', audioUrl: 'a');
       
       final item = MediaItemBuilder.fromEpisode(podcast, episode, extras: {'custom_key': 123});
       
       expect(item.extras?['custom_key'], 123);
       expect(item.extras?['url'], 'a'); // Standard key still added
    });

    test('artist falls back to empty string when podcast author is null', () {
      final podcast = Podcast(url: 'p', title: 'P');
      final episode = Episode(guid: 'e', title: 'E');

      final item = MediaItemBuilder.fromEpisode(podcast, episode);

      expect(item.artist, '');
    });

    test('artist falls back to empty string when podcast is null', () {
      final episode = Episode(guid: 'e', title: 'E');

      final item = MediaItemBuilder.fromEpisode(null, episode);

      expect(item.artist, '');
    });

    test('pubDate is included in extras as ISO 8601 string', () {
      final pubDate = DateTime.utc(2025, 6, 15, 10, 30);
      final podcast = Podcast(url: 'p', title: 'P');
      final episode = Episode(
        guid: 'e',
        title: 'E',
        audioUrl: 'a',
        pubDate: pubDate,
      );

      final item = MediaItemBuilder.fromEpisode(podcast, episode);

      expect(item.extras?['pubDate'], pubDate.toIso8601String());
    });

    test('pubDate is absent from extras when episode has no pubDate', () {
      final podcast = Podcast(url: 'p', title: 'P');
      final episode = Episode(guid: 'e', title: 'E', audioUrl: 'a');

      final item = MediaItemBuilder.fromEpisode(podcast, episode);

      expect(item.extras?.containsKey('pubDate'), isFalse);
    });
  });
}
