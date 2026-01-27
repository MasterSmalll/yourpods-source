import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:YourPods/services/audio_handler.dart';
import 'package:audio_service/audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String validPodcastUrl = 'https://example.com/podcast';
  const String validProfileId = 'user_profile_1';
  late String tempPath;
  late Directory tempDir;

  setUpAll(() async {
    // 1. Mock Path Provider
    final directory = await Directory.systemTemp.createTemp();
    tempPath = directory.path;
    tempDir = directory;

    const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (MethodCall methodCall) async {
        return tempPath;
    });

    // 2. Mock Shared Preferences
    SharedPreferences.setMockInitialValues({
        'current_profile_id': validProfileId,
    });
    
    // 3. Mock Just Audio (to prevent crash in constructor)
    const justAudioChannel = MethodChannel('com.ryanheise.just_audio.methods');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(justAudioChannel, (MethodCall methodCall) async {
        return {}; // Return empty map for init
    });
  });

  tearDownAll(() {
      tempDir.deleteSync(recursive: true);
  });

  test('AudioHandler getChildren returns Library and Queue', () async {
    // Setup Data
    // 1. Podcast Subscription File
    final subsFile = File('$tempPath/subs_$validProfileId.json');
    await subsFile.writeAsString(json.encode([
        {
            'url': validPodcastUrl,
            'title': 'Test Podcast',
            'logoUrl': 'https://example.com/logo.png',
        }
    ]));

    // 2. Episodes File (Using UUID v5 as implemented)
    final uuid = const Uuid().v5(Uuid.NAMESPACE_URL, validPodcastUrl);
    final episodesFile = File('$tempPath/episodes_$uuid.json');
    await episodesFile.writeAsString(json.encode([
        {
            'guid': 'ep1',
            'title': 'Episode 1',
            'audioUrl': 'https://example.com/ep1.mp3',
            'duration': 600,
        }
    ]));

    // Instantiate Handler
    final handler = PodcastAudioHandler();
    
    // Wait a bit for _init (though it's async, we can't await constructor)
    await Future.delayed(const Duration(milliseconds: 100));

    // TEST 1: Root
    final rootItems = await handler.getChildren(AudioService.browsableRootId);
    expect(rootItems.length, 2);
    expect(rootItems[0].title, 'Podcasts');
    expect(rootItems[1].title, 'Queue');

    // TEST 2: Podcasts List
    final podcastItems = await handler.getChildren('podcasts_root');
    expect(podcastItems.length, 1);
    expect(podcastItems[0].title, 'Test Podcast');
    expect(podcastItems[0].id, validPodcastUrl);

    // TEST 3: Episodes List
    final episodeItems = await handler.getChildren(validPodcastUrl);
    expect(episodeItems.length, 1);
    expect(episodeItems[0].title, 'Episode 1');
    expect(episodeItems[0].id, 'ep1');
  });
}
