import 'package:flutter_test/flutter_test.dart';
import '../../lib/services/listening_stats_service.dart';
import '../../lib/api/gpodder_api.dart';
import '../../lib/models/podcast.dart';

void main() {
  group('ListeningStatsService', () {
    test('computeStats correctly calculates total duration and streaks', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      
      final actions = [
        // Yesterday: 30 mins
        EpisodeAction(
          podcast: 'pod1',
          episode: 'ep1',
          action: 'play',
          timestamp: yesterday.millisecondsSinceEpoch ~/ 1000,
          position: 1800,
          started: 0,
          total: 3600,
        ),
        // Today: 10 mins
        EpisodeAction(
          podcast: 'pod1',
          episode: 'ep1',
          action: 'play',
          timestamp: today.millisecondsSinceEpoch ~/ 1000,
          position: 2400,
          started: 1800,
          total: 3600,
        ),
        // Today: Another pod, 20 mins
        EpisodeAction(
          podcast: 'pod2',
          episode: 'epA',
          action: 'play',
          timestamp: (today.millisecondsSinceEpoch ~/ 1000) + 3600,
          position: 1200,
          started: 0,
          total: 2400,
        ),
      ];

      final subscriptions = [
        Podcast(url: 'pod1', title: 'Podcast 1'),
        Podcast(url: 'pod2', title: 'Podcast 2'),
      ];

      final stats = ListeningStatsService.computeStats(
        actions: actions,
        subscriptions: subscriptions,
      );

      // Total duration: 1800 (segment 1) + 600 (segment 2) + 1200 (segment 3) = 3600 seconds = 1 hour
      expect(stats.totalListeningDuration.inHours, 1);
      
      // Streak: yesterday + today = 2
      expect(stats.currentStreak, 2);
      expect(stats.longestStreak, 2);
      
      // Breakdowns
      expect(stats.podcastBreakdowns['pod1']?.totalTime.inMinutes, 40); // 1800 + 600 = 2400s = 40m
      expect(stats.podcastBreakdowns['pod2']?.totalTime.inMinutes, 20); // 1200s = 20m
      
      // Top Podcasts
      expect(stats.topPodcasts.first.podcastUrl, 'pod1');
    });

    test('computeStats handles fallback for missing "started" field', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final actions = [
        EpisodeAction(
          podcast: 'pod1',
          episode: 'ep1',
          action: 'play',
          timestamp: today.millisecondsSinceEpoch ~/ 1000,
          position: 1000,
          // started is null
          total: 2000,
        ),
      ];

      final stats = ListeningStatsService.computeStats(
        actions: actions,
        subscriptions: [],
      );

      // Should fallback to max position if started is null
      expect(stats.totalListeningDuration.inSeconds, 1000);
    });

    test('computeStats detects completed episodes', () {
      final actions = [
        EpisodeAction(
          podcast: 'pod1',
          episode: 'ep1',
          action: 'play',
          timestamp: 1000,
          position: 950,
          started: 0,
          total: 1000, // 95% complete
        ),
      ];

      final stats = ListeningStatsService.computeStats(
        actions: actions,
        subscriptions: [],
      );

      expect(stats.episodesCompleted, 1);
    });

    test('computeStats handles empty actions', () {
      final stats = ListeningStatsService.computeStats(
        actions: [],
        subscriptions: [],
      );

      expect(stats.totalListeningDuration, Duration.zero);
      expect(stats.currentStreak, 0);
    });
  });
}
