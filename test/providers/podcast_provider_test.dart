import 'package:flutter_test/flutter_test.dart';
import 'package:YourPods/providers/podcast_provider.dart';
import 'package:YourPods/api/gpodder_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/services.dart';

// Mock GPodderApi
class MockGPodderApi extends GPodderApi {
  MockGPodderApi() : super(baseUrl: 'https://mock.com', username: 'u', password: 'p');

  List<EpisodeAction> mockActions = [];

  @override
  Future<List<EpisodeAction>> getEpisodeActions(String deviceId, {int since = 0}) async {
    return mockActions;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock channels
  setUpAll(() {
    const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (MethodCall methodCall) async {
        return ".";
      });

    const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (MethodCall methodCall) async {
        return null; // Return null for 'read' calls implies no value stored
      });
  });

  group('PodcastProvider', () {
    late PodcastProvider provider;
    late MockGPodderApi mockApi;

    setUp(() {
      provider = PodcastProvider();
      mockApi = MockGPodderApi();
      provider.setApi(mockApi, 'test_profile');
    });

    test('fetchInProgressEpisodes filters out finished episodes', () async {
      // Setup mock actions
      mockApi.mockActions = [
        // 1. In Progress (started, middle)
        EpisodeAction(
          podcast: 'http://p1.com/feed',
          episode: 'e1',
          action: 'play',
          timestamp: 1000,
          position: 50,
          total: 100, // 50% done
        ),
        // 2. Finished (within 15s of end)
        EpisodeAction(
          podcast: 'http://p2.com/feed',
          episode: 'e2',
          action: 'play',
          timestamp: 1000,
          position: 90,
          total: 100, // 10s left
        ),
        // 3. Finished (99.5% completion)
        EpisodeAction(
          podcast: 'http://p3.com/feed',
          episode: 'e3',
          action: 'play',
          timestamp: 1000,
          position: 995,
          total: 1000, // 99.5%
        ),
        // 4. In Progress (Barely started)
        EpisodeAction(
          podcast: 'http://p4.com/feed',
          episode: 'e4',
          action: 'play',
          timestamp: 1000,
          position: 10,
          total: 1000, // 1%
        ),
      ];
      
      // We expect _fetchFeedsWithCache to be called. 
      // Since we can't easily mock the internal _rssService without dependency injection refactor,
      // we might face network calls if we don't mock fetchEpisodes.
      // However, fetchInProgressEpisodes calls _fetchFeedsWithCache which calls fetchEpisodes.
      // fetchEpisodes checks cache first. 
      
      // Ideally PodcastProvider should allow injecting RssService, but it's hardcoded.
      // For this test, we might get "Network fetch failed" prints, but the logic 
      // we are testing is primarily the filtering of the actions list BEFORE/AFTER checking feeds.
      // Wait, the logic filters "latestActions" then "relevantActions" BEFORE fetching feeds.
      // The filter logic is:
      /*
          for (var action in latestActions.values) {
              // ... Filtering logic ...
              if (action.position != null && action.position! > 0 && !isFinished) {
                   uniquePodcasts.add(action.podcast);
                   relevantActions.add(action);
              }
          }
           final feedCache = await _fetchFeedsWithCache(uniquePodcasts);
      */
      
      // So if our filtering works, "uniquePodcasts" will only contain p1 and p4.
      // calls to _fetchFeedsWithCache will happen for p1 and p4.
      // p2 and p3 should be filtered out.
      
      // The method returns a list of maps.
      // We can inspect the returned list.
      // Note: without mocking RssService, `_fetchFeedsWithCache` will fail or return empty lists for episodes.
      // But the filtering logic dictates whether we even try to add them to the result list.
      // Actually, if `_fetchFeedsWithCache` returns empty, we still construct the result item with a dummy Episode logic?
      // No:
      /*
         final episodes = feedCache[action.podcast] ?? []; // returns empty list
         final episode = episodes.firstWhere(..., orElse: ...); // creates dummy
         inProgress.add(...)
      */
      // So we will get items even if RSS fails.
      
      final result = await provider.fetchInProgressEpisodes('device1');
      
      // Extract podcast URLs from result
      final podcasts = result.map((item) => (item['action'] as EpisodeAction).podcast).toList();
      
      expect(podcasts, contains('http://p1.com/feed'));
      expect(podcasts, contains('http://p4.com/feed'));
      expect(podcasts, isNot(contains('http://p2.com/feed')));
      expect(podcasts, isNot(contains('http://p3.com/feed')));
    });
  });
}
