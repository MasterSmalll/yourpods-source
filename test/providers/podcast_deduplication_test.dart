import 'package:flutter_test/flutter_test.dart';
import 'package:YourPods/providers/podcast_provider.dart';
import 'package:YourPods/api/gpodder_api.dart';
import 'package:flutter/services.dart';

// Mock GPodderApi
class MockGPodderApi extends GPodderApi {
  MockGPodderApi() : super(baseUrl: 'https://mock.com', username: 'u', password: 'p');

  @override
  Future<SubscriptionDelta> getSubscriptionChanges(String deviceId, int since) async {
    // Simulate server returning duplicates or variations
    return SubscriptionDelta(
      add: ['http://example.com/feed', 'http://example.com/feed/'], 
      remove: [], 
      timestamp: 100
    );
  }
  
  @override
  Future<void> updateSubscriptions(String deviceId, {List<String>? add, List<String>? remove}) async {
      return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (MethodCall methodCall) async {
        return ".";
      });

    const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (MethodCall methodCall) async {
        return null;
      });
  });

  test('PodcastProvider deduplicates subscriptions', () async {
    final provider = PodcastProvider();
    final mockApi = MockGPodderApi();
    provider.setApi(mockApi, 'test_profile');

    // Trigger refresh which returns duplicates from mock API
    await provider.refreshSubscriptions('device1');

    // Check subscriptions count. Should be 1, not 2.
    expect(provider.subscriptions.length, 1);
    expect(provider.subscriptions.first.url, anyOf('http://example.com/feed', 'http://example.com/feed/'));
  });
}
