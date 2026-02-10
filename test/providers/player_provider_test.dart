import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:YourPods/providers/player_provider.dart';
import 'package:YourPods/services/audio_handler.dart';
import 'package:YourPods/api/gpodder_api.dart';
import 'package:YourPods/models/podcast.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

// Manual Mocks

class MockAudioPlayer extends Fake implements AudioPlayer {
  @override
  Stream<Duration> get positionStream => Stream.value(Duration.zero);
  
  @override
  bool get playing => false;
  
  @override
  Duration? get duration => const Duration(seconds: 100);
}

class MockPodcastAudioHandler extends Fake implements PodcastAudioHandler {
  final _player = MockAudioPlayer();
  final _queueSubject = BehaviorSubject<List<MediaItem>>.seeded([]);
  final _mediaItemSubject = BehaviorSubject<MediaItem?>.seeded(null);
  
  @override
  AudioPlayer get internalPlayer => _player;

  @override
  BehaviorSubject<List<MediaItem>> get queue => _queueSubject;

  @override
  BehaviorSubject<MediaItem?> get mediaItem => _mediaItemSubject;

  @override
  BehaviorSubject<PlaybackState> get playbackState => BehaviorSubject.seeded(PlaybackState());

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    _queueSubject.add(newQueue);
  }
  
  @override
  Future<void> seek(Duration position) async {
     // no-op for test
  }
}

class MockGPodderApi extends Fake implements GPodderApi {
  List<EpisodeAction> _actionsToReturn = [];
  String? lastDeviceId;
  int? lastSince;

  void setActionsToReturn(List<EpisodeAction> actions) {
    _actionsToReturn = actions;
  }

  @override
  Future<List<EpisodeAction>> getEpisodeActions(String deviceId, {int since = 0}) async {
    lastDeviceId = deviceId;
    lastSince = since;
    return _actionsToReturn;
  }
}

void main() {
  late PlayerProvider playerProvider;
  late MockPodcastAudioHandler mockAudioHandler;
  late MockGPodderApi mockApi;

  setUp(() async {
    // Mock SharedPreferences
    SharedPreferences.setMockInitialValues({});
    
    mockAudioHandler = MockPodcastAudioHandler();
    mockApi = MockGPodderApi();
    
    playerProvider = PlayerProvider(mockAudioHandler);
  });
  
  tearDown(() {
      mockAudioHandler.queue.close();
      mockAudioHandler.mediaItem.close();
  });

  group('SyncPlaybackState', () {
    test('pulls new actions and updates queue item position', () async {
       // Setup Queue
       final item = MediaItem(id: 'ep1', title: 'Episode 1', extras: {'position_seconds': 100});
       mockAudioHandler.updateQueue([item]);
       
       playerProvider.setApi(mockApi, 'test_device');
       
       // Mock API response
       final action = EpisodeAction(
           podcast: 'pod1', 
           episode: 'ep1', 
           action: 'play', 
           timestamp: 1000, 
           position: 500, // New position
           device: 'other_device'
       );
       mockApi.setActionsToReturn([action]);

       // Run Sync
       await playerProvider.syncPlaybackState();
       
       // Verify API Call
       expect(mockApi.lastDeviceId, 'test_device');
       expect(mockApi.lastSince, 0);
       
       // Verify Queue Update
       final updatedQueue = mockAudioHandler.queue.value;
       expect(updatedQueue.length, 1);
       expect(updatedQueue.first.extras?['position_seconds'], 500);
    });

    test('updates timestamp after sync', () async {
       playerProvider.setApi(mockApi, 'test_device');
       
       // Mock API response
       final action1 = EpisodeAction(podcast: 'p', episode: 'e1', action: 'play', timestamp: 100, position: 10);
       mockApi.setActionsToReturn([action1]);

      // Execute 1st sync
       await playerProvider.syncPlaybackState();
       
       // Verify API Call was 0
       expect(mockApi.lastSince, 0);

       // Execute 2nd sync
       // Mock API response for next call (empty or new)
       mockApi.setActionsToReturn([]);
       await playerProvider.syncPlaybackState();
       
       // Verify it used the new timestamp (100)
       expect(mockApi.lastSince, 100);
    });
  });
}
