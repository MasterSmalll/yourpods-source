import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:YourPods/services/audio_handler.dart';
import 'package:YourPods/providers/podcast_provider.dart';
import 'package:YourPods/models/podcast.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

// =========================================================
// Mocks — isolate getChildren logic from real constructor
// =========================================================

class _MockAudioPlayer extends Fake implements AudioPlayer {
  @override
  Stream<Duration> get positionStream => Stream.value(Duration.zero);
  @override
  bool get playing => false;
  @override
  Duration? get duration => null;
  @override
  Duration get position => Duration.zero;
}

class _MockPodcastProvider extends Fake implements PodcastProvider {
  final List<Podcast> _subscriptions;
  final Map<String, List<Episode>> _episodes;

  _MockPodcastProvider({
    List<Podcast>? subscriptions,
    Map<String, List<Episode>>? episodes,
  })  : _subscriptions = subscriptions ?? [],
        _episodes = episodes ?? {};

  @override
  List<Podcast> get subscriptions => _subscriptions;

  @override
  Future<List<Episode>> getEpisodes(String podcastUrl, {bool forceRefresh = false}) async {
    return _episodes[podcastUrl] ?? [];
  }
}

/// A testable subclass that exposes the provider setter without
/// running the real async constructor (_init) which depends on
/// platform plugins.
class _TestablePodcastAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  PodcastProvider? _podcastProvider;

  void setPodcastProvider(PodcastProvider provider) {
    _podcastProvider = provider;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    final List<MediaItem> children = [];

    if (parentMediaId == AudioService.browsableRootId) {
      children.add(const MediaItem(id: 'podcasts_root', album: '', title: 'Podcasts', playable: false));
      children.add(const MediaItem(id: 'queue_root', album: '', title: 'Queue', playable: false));
    } else if (parentMediaId == 'queue_root') {
      return queue.value;
    } else if (parentMediaId == 'podcasts_root') {
      if (_podcastProvider != null) {
        for (var p in _podcastProvider!.subscriptions) {
          children.add(MediaItem(
            id: p.url,
            album: '',
            title: p.title,
            artUri: p.logoUrl != null ? Uri.parse(p.logoUrl!) : null,
            playable: false,
          ));
        }
      }
    } else {
      if (_podcastProvider != null) {
        final episodes = await _podcastProvider!.getEpisodes(parentMediaId);
        for (var e in episodes) {
          if (e.audioUrl == null) continue;
          children.add(MediaItem(
            id: e.guid,
            album: '',
            title: e.title,
            extras: {'url': e.audioUrl, 'podcastUrl': parentMediaId},
            artUri: e.imageUrl != null ? Uri.parse(e.imageUrl!) : null,
            playable: true,
            duration: e.duration,
          ));
        }
      }
    }
    return children;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String validPodcastUrl = 'https://example.com/podcast';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('AudioHandler getChildren returns Library and Queue', () async {
    final handler = _TestablePodcastAudioHandler();
    handler.setPodcastProvider(_MockPodcastProvider(
      subscriptions: [
        Podcast(url: validPodcastUrl, title: 'Test Podcast', logoUrl: 'https://example.com/logo.png'),
      ],
      episodes: {
        validPodcastUrl: [
          Episode(guid: 'ep1', title: 'Episode 1', audioUrl: 'https://example.com/ep1.mp3', duration: const Duration(seconds: 600)),
        ],
      },
    ));

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

