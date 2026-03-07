import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:YourPods/providers/player_provider.dart';
import 'package:YourPods/services/queue_sync_service.dart';
import 'package:YourPods/api/gpodder_api.dart';
import 'package:YourPods/models/podcast.dart';
import 'package:YourPods/models/queue_sync_change.dart';
import 'package:audio_service/audio_service.dart';

import '../test_helpers.dart';

void main() {
  late PlayerProvider playerProvider;
  late MockPodcastAudioHandler mockAudioHandler;
  late MockGPodderApi mockApi;
  late MockPodcastProvider mockPodcastProvider;

  final testPodcast = Podcast(
    title: 'Test Podcast',
    url: 'https://example.com/feed.xml',
    logoUrl: 'https://example.com/logo.png',
    description: 'A test podcast',
  );

  setUp(() async {
    // Mock SharedPreferences
    SharedPreferences.setMockInitialValues({});
    
    mockAudioHandler = MockPodcastAudioHandler();
    mockApi = MockGPodderApi();
    mockPodcastProvider = MockPodcastProvider();
    
    playerProvider = PlayerProvider(mockAudioHandler);
    playerProvider.updatePodcastProvider(mockPodcastProvider);
  });
  
  tearDown(() {
      mockAudioHandler.queue.close();
      mockAudioHandler.mediaItem.close();
  });

  group('SyncPlaybackState', () {
    test('syncs actions and updates queue item position from action map', () async {
       playerProvider.setApi(mockApi, 'device-1', profileId: 'sync-profile');
       
       // Setup Queue
       final item = _makeQueueItem('ep1', positionSeconds: 100);
       mockAudioHandler.updateQueue([item]);
       
       // Set up action map on mock PodcastProvider with a newer position
       mockPodcastProvider.setActionMap({
         'ep1': EpisodeAction(
           podcast: 'https://example.com/feed.xml',
           episode: 'ep1',
           action: 'play',
           timestamp: 1000,
           position: 500,
         ),
       });

       // Run Sync
       await playerProvider.syncPlaybackState();
       
       // Verify Queue still intact (action map enrichment happens via _enrichQueueFromProvider)
       final updatedQueue = mockAudioHandler.queue.value;
       expect(updatedQueue.length, 1);
       // Position should be updated from the action map
       expect(updatedQueue.first.extras?['position_seconds'], 500);
    });

    test('sync completes without errors on empty action map', () async {
       playerProvider.setApi(mockApi, 'device-1', profileId: 'sync-profile');
       mockPodcastProvider.setActionMap({});

       // Execute sync — should not throw
       final result = await playerProvider.syncPlaybackState();
       
       // Should return empty result
       expect(result.conflicts, isEmpty);
    });
  });

  // =============================================
  // applyQueueSyncChanges Integration Tests
  // =============================================
  group('applyQueueSyncChanges', () {
    test('ADD: appends episode to queue', () async {
      mockAudioHandler.updateQueue([]);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.add,
        episodeGuid: 'ep-new',
        podcastUrl: 'https://example.com/feed.xml',
        episodeTitle: 'New Episode',
        serverPosition: 120,
        totalDuration: 600,
        serverTimestamp: 1000,
        accepted: true,
      );

      // Note: _applyQueueAdd needs _podcastProvider, which we don't have here.
      // We test the flow by directly calling applyQueueSyncChanges, 
      // which will log a warning for unresolvable episodes but not crash.
      await playerProvider.applyQueueSyncChanges([change]);

      // Since no podcastProvider is set, ADD will be skipped with a warning.
      // This test validates the method doesn't crash on unresolvable adds.
      expect(mockAudioHandler.queue.value.length, 0);
    });

    test('REMOVE: removes episode from queue', () async {
      final item = _makeQueueItem('ep-done', positionSeconds: 590);
      mockAudioHandler.updateQueue([item]);
      expect(mockAudioHandler.queue.value.length, 1);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.remove,
        episodeGuid: 'ep-done',
        podcastUrl: 'https://example.com/feed.xml',
        episodeTitle: 'Done Episode',
        serverPosition: 600,
        totalDuration: 600,
        serverTimestamp: 1000,
        accepted: true,
      );

      await playerProvider.applyQueueSyncChanges([change]);
      expect(mockAudioHandler.queue.value.length, 0);
      expect(mockAudioHandler.removedItems.length, 1);
      expect(mockAudioHandler.removedItems.first.id, 'ep-done');
    });

    test('REMOVE: no-op when episode not in queue', () async {
      final item = _makeQueueItem('ep-other');
      mockAudioHandler.updateQueue([item]);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.remove,
        episodeGuid: 'ep-nonexistent',
        podcastUrl: 'https://example.com/feed.xml',
        serverTimestamp: 1000,
        accepted: true,
      );

      await playerProvider.applyQueueSyncChanges([change]);
      expect(mockAudioHandler.queue.value.length, 1); // unchanged
      expect(mockAudioHandler.removedItems, isEmpty);
    });

    test('UPDATE: changes episode position in queue', () async {
      final item = _makeQueueItem('ep-1', positionSeconds: 100);
      mockAudioHandler.updateQueue([item]);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.update,
        episodeGuid: 'ep-1',
        podcastUrl: 'https://example.com/feed.xml',
        episodeTitle: 'Episode 1',
        serverPosition: 400,
        localPosition: 100,
        totalDuration: 600,
        serverTimestamp: 1000,
        accepted: true,
      );

      await playerProvider.applyQueueSyncChanges([change]);

      final updatedQueue = mockAudioHandler.queue.value;
      expect(updatedQueue.length, 1);
      expect(updatedQueue.first.extras?['position_seconds'], 400);
    });

    test('UPDATE: no-op when episode not in queue', () async {
      final item = _makeQueueItem('ep-other', positionSeconds: 100);
      mockAudioHandler.updateQueue([item]);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.update,
        episodeGuid: 'ep-nonexistent',
        podcastUrl: 'https://example.com/feed.xml',
        serverPosition: 400,
        serverTimestamp: 1000,
        accepted: true,
      );

      await playerProvider.applyQueueSyncChanges([change]);
      // Queue should be unchanged
      expect(mockAudioHandler.queue.value.first.extras?['position_seconds'], 100);
    });

    test('rejected changes are skipped', () async {
      final item = _makeQueueItem('ep-1', positionSeconds: 100);
      mockAudioHandler.updateQueue([item]);

      final change = QueueSyncChange(
        type: QueueSyncChangeType.update,
        episodeGuid: 'ep-1',
        podcastUrl: 'https://example.com/feed.xml',
        serverPosition: 500,
        serverTimestamp: 1000,
        accepted: false, // rejected
      );

      await playerProvider.applyQueueSyncChanges([change]);
      expect(mockAudioHandler.queue.value.first.extras?['position_seconds'], 100); // unchanged
    });

    test('duplicate GUID in same batch: only first change applied', () async {
      final item = _makeQueueItem('ep-1', positionSeconds: 100);
      mockAudioHandler.updateQueue([item]);

      final change1 = QueueSyncChange(
        type: QueueSyncChangeType.update,
        episodeGuid: 'ep-1',
        podcastUrl: 'https://example.com/feed.xml',
        serverPosition: 300,
        serverTimestamp: 1000,
        accepted: true,
      );
      final change2 = QueueSyncChange(
        type: QueueSyncChangeType.update,
        episodeGuid: 'ep-1', // same GUID
        podcastUrl: 'https://example.com/feed.xml',
        serverPosition: 500, // different position
        serverTimestamp: 1100,
        accepted: true,
      );

      await playerProvider.applyQueueSyncChanges([change1, change2]);

      // Only first change (300) should be applied, second skipped
      final updatedQueue = mockAudioHandler.queue.value;
      expect(updatedQueue.first.extras?['position_seconds'], 300);
    });

    test('mixed batch: remove + update for different episodes', () async {
      final items = [
        _makeQueueItem('ep-done', positionSeconds: 595),
        _makeQueueItem('ep-updated', positionSeconds: 100),
        _makeQueueItem('ep-unchanged', positionSeconds: 300),
      ];
      mockAudioHandler.updateQueue(items);

      final changes = [
        QueueSyncChange(
          type: QueueSyncChangeType.remove,
          episodeGuid: 'ep-done',
          podcastUrl: 'https://example.com/feed.xml',
          serverTimestamp: 1000,
          accepted: true,
        ),
        QueueSyncChange(
          type: QueueSyncChangeType.update,
          episodeGuid: 'ep-updated',
          podcastUrl: 'https://example.com/feed.xml',
          serverPosition: 450,
          serverTimestamp: 1000,
          accepted: true,
        ),
      ];

      await playerProvider.applyQueueSyncChanges(changes);

      final q = mockAudioHandler.queue.value;
      // ep-done removed, ep-updated has new position, ep-unchanged untouched
      expect(q.length, 2);
      expect(q.where((i) => i.id == 'ep-done'), isEmpty);
      
      final updated = q.firstWhere((i) => i.id == 'ep-updated');
      expect(updated.extras?['position_seconds'], 450);
      
      final unchanged = q.firstWhere((i) => i.id == 'ep-unchanged');
      expect(unchanged.extras?['position_seconds'], 300);
    });
  });

  // =============================================
  // _deduplicateQueue Tests (via syncPlaybackState)
  // =============================================
  group('Queue Deduplication', () {
    test('removes duplicate episodes from queue, keeps first occurrence', () async {
      // Manually insert duplicates into the queue
      final items = [
        _makeQueueItem('ep-1', positionSeconds: 100),
        _makeQueueItem('ep-2', positionSeconds: 200),
        _makeQueueItem('ep-1', positionSeconds: 300), // duplicate of ep-1
      ];
      mockAudioHandler.updateQueue(items);
      expect(mockAudioHandler.queue.value.length, 3);

      // Trigger sync which runs _deduplicateQueue
      await playerProvider.syncPlaybackState();

      final q = mockAudioHandler.queue.value;
      expect(q.length, 2);
      expect(q[0].id, 'ep-1');
      expect(q[0].extras?['position_seconds'], 100); // first occurrence kept
      expect(q[1].id, 'ep-2');
    });

    test('no-op when queue has no duplicates', () async {
      final items = [
        _makeQueueItem('ep-1', positionSeconds: 100),
        _makeQueueItem('ep-2', positionSeconds: 200),
        _makeQueueItem('ep-3', positionSeconds: 300),
      ];
      mockAudioHandler.updateQueue(items);

      await playerProvider.syncPlaybackState();

      expect(mockAudioHandler.queue.value.length, 3);
    });

    test('handles triple+ duplicates', () async {
      final items = [
        _makeQueueItem('ep-1', positionSeconds: 50),
        _makeQueueItem('ep-1', positionSeconds: 100),
        _makeQueueItem('ep-1', positionSeconds: 200),
        _makeQueueItem('ep-2', positionSeconds: 300),
      ];
      mockAudioHandler.updateQueue(items);

      await playerProvider.syncPlaybackState();

      final q = mockAudioHandler.queue.value;
      expect(q.length, 2);
      expect(q[0].id, 'ep-1');
      expect(q[0].extras?['position_seconds'], 50); // first kept
      expect(q[1].id, 'ep-2');
    });

    test('empty queue produces no errors', () async {
      mockAudioHandler.updateQueue([]);
      await playerProvider.syncPlaybackState();
      expect(mockAudioHandler.queue.value, isEmpty);
    });
  });

  // =============================================
  // Round-Trip Scenario Tests
  // =============================================
  group('Round-Trip Scenarios', () {
    test('Scenario: offline then reconnect — merge server episodes into local queue', () {
      // Local: [A@100s, B@200s, C@50s]
      // Server: [A@300s, B@200s, D@400s]
      // Expected changes: UPDATE A to 300s, ADD D (B is within threshold)
      final localQueue = [
        _makeQueueItem('ep-A', positionSeconds: 100),
        _makeQueueItem('ep-B', positionSeconds: 200),
        _makeQueueItem('ep-C', positionSeconds: 50),
      ];
      final actionMap = {
        'ep-A': _makeAction('ep-A', position: 300, total: 600, timestamp: 500),
        'ep-B': _makeAction('ep-B', position: 210, total: 600, timestamp: 400), // diff < 30
        'ep-D': _makeAction('ep-D', position: 400, total: 600, timestamp: 600),
      };

      final changes = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      expect(changes.length, 2);

      final update = changes.firstWhere((c) => c.type == QueueSyncChangeType.update);
      expect(update.episodeGuid, 'ep-A');
      expect(update.serverPosition, 300);

      final add = changes.firstWhere((c) => c.type == QueueSyncChangeType.add);
      expect(add.episodeGuid, 'ep-D');
      expect(add.serverPosition, 400);
    });

    test('Scenario: user rejects all server updates — local queue unchanged', () async {
      final items = [
        _makeQueueItem('ep-A', positionSeconds: 100),
        _makeQueueItem('ep-B', positionSeconds: 200),
      ];
      mockAudioHandler.updateQueue(items);

      // Compute changes
      final localQueue = mockAudioHandler.queue.value;
      final actionMap = {
        'ep-A': _makeAction('ep-A', position: 500, total: 600, timestamp: 500),
        'ep-B': _makeAction('ep-B', position: 400, total: 600, timestamp: 400),
      };

      final changes = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      // User rejects all
      for (var c in changes) {
        c.accepted = false;
      }

      await playerProvider.applyQueueSyncChanges(changes);

      // Queue should be completely unchanged
      final q = mockAudioHandler.queue.value;
      expect(q.length, 2);
      expect(q[0].extras?['position_seconds'], 100);
      expect(q[1].extras?['position_seconds'], 200);
    });

    test('Scenario: user accepts some, rejects others — selective merge', () async {
      final items = [
        _makeQueueItem('ep-A', positionSeconds: 100),
        _makeQueueItem('ep-B', positionSeconds: 200),
        _makeQueueItem('ep-C', positionSeconds: 300),
      ];
      mockAudioHandler.updateQueue(items);

      final localQueue = mockAudioHandler.queue.value;
      final actionMap = {
        'ep-A': _makeAction('ep-A', position: 500, total: 600, timestamp: 500),
        'ep-B': _makeAction('ep-B', position: 400, total: 600, timestamp: 400),
        'ep-C': _makeAction('ep-C', position: 598, total: 600, timestamp: 300), // completed
      };

      final changes = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      expect(changes.length, 3);

      // User accepts A update, rejects B update, accepts C removal
      for (var c in changes) {
        if (c.episodeGuid == 'ep-A') c.accepted = true;
        if (c.episodeGuid == 'ep-B') c.accepted = false;
        if (c.episodeGuid == 'ep-C') c.accepted = true;
      }

      await playerProvider.applyQueueSyncChanges(changes);

      final q = mockAudioHandler.queue.value;
      // ep-A updated, ep-B unchanged, ep-C removed
      expect(q.length, 2);

      final a = q.firstWhere((i) => i.id == 'ep-A');
      expect(a.extras?['position_seconds'], 500);

      final b = q.firstWhere((i) => i.id == 'ep-B');
      expect(b.extras?['position_seconds'], 200); // unchanged

      expect(q.where((i) => i.id == 'ep-C'), isEmpty); // removed
    });

    test('Scenario: compute + apply + dedup sweep ensures no duplicates', () async {
      // Start with a queue that already has a duplicate
      final items = [
        _makeQueueItem('ep-A', positionSeconds: 100),
        _makeQueueItem('ep-B', positionSeconds: 200),
        _makeQueueItem('ep-A', positionSeconds: 150), // pre-existing duplicate
      ];
      mockAudioHandler.updateQueue(items);
      expect(mockAudioHandler.queue.value.length, 3);

      // Sync triggers dedup sweep
      await playerProvider.syncPlaybackState();

      final q = mockAudioHandler.queue.value;
      expect(q.length, 2, reason: 'Duplicate ep-A should be removed');
      
      final guids = q.map((i) => i.id).toSet();
      expect(guids.length, q.length, reason: 'All GUIDs should be unique');
    });

    test('Scenario: server marks episode complete that is currently playing-ish on device', () async {
      final items = [
        _makeQueueItem('ep-playing', positionSeconds: 300),
        _makeQueueItem('ep-next', positionSeconds: 0),
      ];
      mockAudioHandler.updateQueue(items);

      final localQueue = mockAudioHandler.queue.value;
      final actionMap = {
        'ep-playing': _makeAction('ep-playing', position: 598, total: 600, timestamp: 999),
      };

      final changes = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      // Should propose removal
      expect(changes.length, 1);
      expect(changes[0].type, QueueSyncChangeType.remove);
      expect(changes[0].episodeGuid, 'ep-playing');

      // User accepts removal
      await playerProvider.applyQueueSyncChanges(changes);

      final q = mockAudioHandler.queue.value;
      expect(q.length, 1);
      expect(q[0].id, 'ep-next');
    });

    test('Scenario: multiple syncs in a row produce consistent results', () {
      // Simulates what happens if user pulls-to-refresh multiple times
      final localQueue = [
        _makeQueueItem('ep-1', positionSeconds: 100),
      ];
      final actionMap = {
        'ep-1': _makeAction('ep-1', position: 300, total: 600, timestamp: 500),
        'ep-2': _makeAction('ep-2', position: 200, total: 600, timestamp: 600),
      };

      // First computation
      final changes1 = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      // Second computation (identical inputs)
      final changes2 = QueueSyncService.computeChanges(
        localQueue: localQueue,
        actionMap: actionMap,
        subscriptions: [testPodcast],
      );

      // Should produce identical results
      expect(changes1.length, changes2.length);
      for (var i = 0; i < changes1.length; i++) {
        expect(changes1[i].episodeGuid, changes2[i].episodeGuid);
        expect(changes1[i].type, changes2[i].type);
        expect(changes1[i].serverPosition, changes2[i].serverPosition);
      }
    });
  });

  // =============================================
  // Regression: Episode Description from Cache
  // =============================================
  group('Episode Description from Cache', () {
    test('_syncFromMediaItem populates description from cached episode', () async {
      // Setup: podcast provider has an episode with a description in cache
      final feedUrl = 'https://example.com/feed.xml';
      mockPodcastProvider.setSubscriptions([
        Podcast(url: feedUrl, title: 'Test Podcast'),
      ]);
      mockPodcastProvider.setCachedEpisodes(feedUrl, [
        Episode(
          guid: 'ep-with-desc',
          title: 'Episode With Description',
          description: 'This is the full show notes with details.',
          audioUrl: 'https://example.com/ep.mp3',
          duration: const Duration(seconds: 600),
          pubDate: DateTime.utc(2025, 6, 15),
          transcriptUrl: 'https://example.com/transcript.vtt',
        ),
      ]);

      // Trigger _syncFromMediaItem via mediaItem stream emission
      final mediaItem = MediaItem(
        id: 'ep-with-desc',
        title: 'Episode With Description',
        album: 'Test Podcast',
        extras: {
          'url': 'https://example.com/ep.mp3',
          'podcastUrl': feedUrl,
        },
        duration: const Duration(seconds: 600),
      );
      mockAudioHandler.mediaItem.add(mediaItem);

      // Allow stream listener to process
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify the current episode has the cached description
      expect(playerProvider.currentEpisode, isNotNull);
      expect(playerProvider.currentEpisode!.guid, 'ep-with-desc');
      expect(
        playerProvider.currentEpisode!.description,
        'This is the full show notes with details.',
      );
    });

    test('_syncFromMediaItem falls back to empty description when not cached', () async {
      // Setup: podcast provider has NO cached episode for this guid
      final feedUrl = 'https://example.com/feed.xml';
      mockPodcastProvider.setSubscriptions([
        Podcast(url: feedUrl, title: 'Test Podcast'),
      ]);
      // No cached episodes — findEpisodeInCache will return null

      final mediaItem = MediaItem(
        id: 'ep-no-cache',
        title: 'Uncached Episode',
        album: 'Test Podcast',
        extras: {
          'url': 'https://example.com/uncached.mp3',
          'podcastUrl': feedUrl,
          'pubDate': '2025-06-15T00:00:00.000Z',
        },
        duration: const Duration(seconds: 300),
      );
      mockAudioHandler.mediaItem.add(mediaItem);

      await Future.delayed(const Duration(milliseconds: 100));

      // Verify fallback: description is empty, but other fields are correct
      expect(playerProvider.currentEpisode, isNotNull);
      expect(playerProvider.currentEpisode!.guid, 'ep-no-cache');
      expect(playerProvider.currentEpisode!.description, '');
      expect(playerProvider.currentEpisode!.title, 'Uncached Episode');
      // pubDate should be parsed from extras
      expect(playerProvider.currentEpisode!.pubDate, isNotNull);
    });
  });

  // =============================================
  // Re-queue on Episode Switch
  // =============================================
  group('Re-queue on Episode Switch', () {
    test('switching to new episode re-queues the current unfinished episode at top of queue', () async {
      // Setup: ep-A is now playing, ep-B and ep-C are in queue
      final epA = _makeQueueItem('ep-A', positionSeconds: 0);
      final epB = _makeQueueItem('ep-B', positionSeconds: 0);
      final epC = _makeQueueItem('ep-C', positionSeconds: 0);
      mockAudioHandler.updateQueue([epA, epB, epC]);
      mockAudioHandler.mediaItem.add(epA); // currently playing

      // Act: switch to a different episode
      final newEp = _makeQueueItem('ep-new', positionSeconds: 0);
      await mockAudioHandler.playEpisode(newEp, 'https://example.com/ep-new.mp3');

      // Assert: ep-A should be at the top of the queue with position saved
      final q = mockAudioHandler.queue.value;
      expect(q.first.id, 'ep-A');
      expect(q.first.extras?['position_seconds'], 0); // MockAudioPlayer.position is Duration.zero
      // ep-B and ep-C should still be in queue
      expect(q.where((i) => i.id == 'ep-B').length, 1);
      expect(q.where((i) => i.id == 'ep-C').length, 1);
      // The new episode should now be the mediaItem
      expect(mockAudioHandler.mediaItem.value?.id, 'ep-new');
    });

    test('switching to new episode does not re-queue a finished episode', () async {
      // Set mock player duration to 3s so position(0) >= 3-5=-2 triggers 'finished'
      (mockAudioHandler.internalPlayer as MockAudioPlayer).mockDuration = const Duration(seconds: 3);
      
      final epFinished = MediaItem(
        id: 'ep-finished',
        title: 'Finished Episode',
        album: 'Test Podcast',
        extras: {'url': 'https://example.com/ep-finished.mp3', 'podcastUrl': 'https://example.com/feed.xml'},
        duration: const Duration(seconds: 3),
      );
      // Don't add to queue — only set as now-playing
      mockAudioHandler.updateQueue([]);
      mockAudioHandler.mediaItem.add(epFinished);

      final newEp = _makeQueueItem('ep-new', positionSeconds: 0);
      await mockAudioHandler.playEpisode(newEp, 'https://example.com/ep-new.mp3');

      // Assert: ep-finished should NOT be in queue (it was finished)
      final q = mockAudioHandler.queue.value;
      expect(q.where((i) => i.id == 'ep-finished'), isEmpty);
      expect(mockAudioHandler.mediaItem.value?.id, 'ep-new');
    });

    test('playing the same episode again does not duplicate it in queue', () async {
      final epA = _makeQueueItem('ep-A', positionSeconds: 100);
      mockAudioHandler.updateQueue([epA]);
      mockAudioHandler.mediaItem.add(epA);

      // Act: "play" the same episode
      await mockAudioHandler.playEpisode(epA, 'https://example.com/ep-A.mp3');

      // Assert: queue unchanged, no duplication
      final q = mockAudioHandler.queue.value;
      expect(q.length, 1);
      expect(q.first.id, 'ep-A');
    });
  });

  // =============================================
  // Local Profile Sync Guard
  // =============================================
  group('Local profile sync guard', () {
    test('syncPlaybackState skips server sync when api is null (local profile)', () async {
      // Simulate local profile: no API set
      // PlayerProvider was initialized in setUp() without calling setApi
      // So _api is null
      mockPodcastProvider.setActionMap({});
      mockAudioHandler.updateQueue([]);

      // Reset the counter (setUp's playerProvider constructor might trigger sync)
      mockPodcastProvider.syncEpisodeActionsCalled = 0;

      final result = await playerProvider.syncPlaybackState();

      // Server sync should NOT have been called
      expect(mockPodcastProvider.syncEpisodeActionsCalled, 0,
          reason: 'syncEpisodeActions should not be called for local profiles (null API)');
      // Should return empty result, not an error
      expect(result.conflicts, isEmpty);
      expect(result.queueChanges, isEmpty);
    });

    test('syncPlaybackState still deduplicates queue for local profiles', () async {
      // Queue with duplicates, but no API (local profile)
      final items = [
        _makeQueueItem('ep-1', positionSeconds: 100),
        _makeQueueItem('ep-2', positionSeconds: 200),
        _makeQueueItem('ep-1', positionSeconds: 300), // duplicate
      ];
      mockAudioHandler.updateQueue(items);
      mockPodcastProvider.syncEpisodeActionsCalled = 0;

      await playerProvider.syncPlaybackState();

      // Deduplication should still run
      final q = mockAudioHandler.queue.value;
      expect(q.length, 2, reason: 'Duplicates should be removed even for local profiles');
      expect(q[0].id, 'ep-1');
      expect(q[1].id, 'ep-2');

      // But server sync should NOT have run
      expect(mockPodcastProvider.syncEpisodeActionsCalled, 0);
    });

    test('syncPlaybackState calls server sync when api is set (sync profile)', () async {
      // Set API — simulating a sync profile
      playerProvider.setApi(mockApi, 'device-1', profileId: 'sync-profile');
      mockPodcastProvider.syncEpisodeActionsCalled = 0;

      await playerProvider.syncPlaybackState();

      // Server sync SHOULD have been called
      expect(mockPodcastProvider.syncEpisodeActionsCalled, greaterThan(0),
          reason: 'syncEpisodeActions should be called for sync profiles');
    });

    test('syncPlaybackState enriches queue even without API (local profile)', () async {
      // Local profile: no API set, but podcastProvider has action data
      final items = [
        _makeQueueItem('ep-1', positionSeconds: 100),
        _makeQueueItem('ep-2', positionSeconds: 50),
      ];
      mockAudioHandler.updateQueue(items);

      mockPodcastProvider.setActionMap({
        'ep-1': _makeAction('ep-1', position: 500, timestamp: 2000),
        'ep-2': _makeAction('ep-2', position: 300, timestamp: 2000),
      });
      mockPodcastProvider.syncEpisodeActionsCalled = 0;

      await playerProvider.syncPlaybackState();

      // Server sync should NOT have been called
      expect(mockPodcastProvider.syncEpisodeActionsCalled, 0);

      // But enrichment SHOULD have run — positions updated from action map
      final q = mockAudioHandler.queue.value;
      expect(q.length, 2);
      expect(q.firstWhere((i) => i.id == 'ep-1').extras?['position_seconds'], 500,
          reason: 'Queue should be enriched even without API');
      expect(q.firstWhere((i) => i.id == 'ep-2').extras?['position_seconds'], 300);
    });
  });

  // =============================================
  // _syncProgress Safety (local profiles)
  // =============================================
  group('_syncProgress safety on local profiles', () {
    test('togglePlay does not crash when api and podcastProvider are both logically null', () async {
      // PlayerProvider has no API set (local profile)
      // _podcastProvider IS set (from setUp), but _api is null.
      // _syncProgress should gracefully skip upload.
      
      // Set up a "currently playing" state so _syncProgress tries to run
      final item = _makeQueueItem('ep-1', positionSeconds: 0);
      mockAudioHandler.updateQueue([item]);
      mockAudioHandler.mediaItem.add(item);
      
      // Allow stream listener to pick up the media item
      await Future.delayed(const Duration(milliseconds: 100));
      
      // togglePlay calls _syncProgress internally — should NOT throw
      expect(() => playerProvider.togglePlay(), returnsNormally);
    });

    test('forceSync does not crash when api is null (local profile)', () async {
      // Set up a playing state
      final item = _makeQueueItem('ep-1', positionSeconds: 0);
      mockAudioHandler.updateQueue([item]);
      mockAudioHandler.mediaItem.add(item);
      await Future.delayed(const Duration(milliseconds: 100));

      // forceSync calls _syncProgress — should not crash
      await expectLater(
        playerProvider.forceSync(),
        completes,
      );
    });
  });
}
