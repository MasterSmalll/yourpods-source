import 'package:flutter_test/flutter_test.dart';
import 'package:YourPods/providers/podcast_provider.dart';
import 'package:YourPods/api/gpodder_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

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
    SharedPreferences.setMockInitialValues({});
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
      
      final result = await provider.fetchInProgressEpisodes('device1');
      
      // Extract podcast URLs from result
      final podcasts = result.map((item) => (item['action'] as EpisodeAction).podcast).toList();
      
      expect(podcasts, contains('http://p1.com/feed'));
      expect(podcasts, contains('http://p4.com/feed'));
      expect(podcasts, isNot(contains('http://p2.com/feed')));
      expect(podcasts, isNot(contains('http://p3.com/feed')));
    });
  });

  group('findEpisodeInCache', () {
    late PodcastProvider provider;

    setUp(() {
      provider = PodcastProvider();
    });

    test('returns null for uncached podcast URL', () {
      final result = provider.findEpisodeInCache('https://unknown.com/feed.xml', 'ep1');
      expect(result, isNull);
    });

    test('returns null for unknown guid in cached podcast', () {
      // Even if other URLs are cached, an empty/non-matching lookup returns null
      final result = provider.findEpisodeInCache('https://example.com/feed.xml', 'nonexistent-guid');
      expect(result, isNull);
    });
  });
}
