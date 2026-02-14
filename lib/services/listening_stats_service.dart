import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/podcast.dart';
import '../api/gpodder_api.dart';
import 'log_service.dart';

class PodcastStats {
  final String podcastUrl;
  final String podcastTitle;
  final String? logoUrl;
  Duration totalTime;
  int episodeCount;

  PodcastStats({
    required this.podcastUrl,
    required this.podcastTitle,
    this.logoUrl,
    this.totalTime = Duration.zero,
    this.episodeCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'podcastUrl': podcastUrl,
    'podcastTitle': podcastTitle,
    'logoUrl': logoUrl,
    'totalTime': totalTime.inSeconds,
    'episodeCount': episodeCount,
  };

  factory PodcastStats.fromJson(Map<String, dynamic> json) => PodcastStats(
    podcastUrl: json['podcastUrl'],
    podcastTitle: json['podcastTitle'],
    logoUrl: json['logoUrl'],
    totalTime: Duration(seconds: json['totalTime']),
    episodeCount: json['episodeCount'],
  );
}

class ListeningStats {
  final Duration totalListeningDuration;
  final int episodesCompleted;
  final int currentStreak;
  final int longestStreak;
  final Map<String, PodcastStats> podcastBreakdowns;
  final Map<DateTime, Duration> dailyListening;
  final List<PodcastStats> topPodcasts;
  final DateTime lastUpdated;

  ListeningStats({
    required this.totalListeningDuration,
    required this.episodesCompleted,
    required this.currentStreak,
    required this.longestStreak,
    required this.podcastBreakdowns,
    required this.dailyListening,
    required this.topPodcasts,
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() {
    return {
      'totalListeningDuration': totalListeningDuration.inSeconds,
      'episodesCompleted': episodesCompleted,
      'currentStreak': currentStreak,
      'longestStreak': longestStreak,
      'podcastBreakdowns': podcastBreakdowns.map((k, v) => MapEntry(k, v.toJson())),
      'dailyListening': dailyListening.map((k, v) => MapEntry(k.toIso8601String(), v.inSeconds)),
      'topPodcasts': topPodcasts.map((v) => v.toJson()).toList(),
      'lastUpdated': lastUpdated.toIso8601String(),
    };
  }

  factory ListeningStats.fromJson(Map<String, dynamic> json) {
    return ListeningStats(
      totalListeningDuration: Duration(seconds: json['totalListeningDuration']),
      episodesCompleted: json['episodesCompleted'],
      currentStreak: json['currentStreak'],
      longestStreak: json['longestStreak'],
      podcastBreakdowns: (json['podcastBreakdowns'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, PodcastStats.fromJson(v))),
      dailyListening: (json['dailyListening'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(DateTime.parse(k), Duration(seconds: v))),
      topPodcasts: (json['topPodcasts'] as List).map((v) => PodcastStats.fromJson(v)).toList(),
      lastUpdated: DateTime.parse(json['lastUpdated']),
    );
  }
}

class ListeningStatsService {
  static const String _cacheKey = 'listening_stats_cache';

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    Log.i('ListeningStatsService', 'Cache cleared.');
  }

  static Future<ListeningStats?> loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_cacheKey);
      if (jsonStr == null) return null;
      return ListeningStats.fromJson(json.decode(jsonStr));
    } catch (e) {
      Log.e('ListeningStatsService', 'Error loading cache: $e');
      return null;
    }
  }

  static Future<void> saveToCache(ListeningStats stats) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, json.encode(stats.toJson()));
    } catch (e) {
      Log.e('ListeningStatsService', 'Error saving cache: $e');
    }
  }

  static ListeningStats computeStats({
    required List<EpisodeAction> actions,
    required List<Podcast> subscriptions,
  }) {
    if (actions.isEmpty) {
      return ListeningStats(
        totalListeningDuration: Duration.zero,
        episodesCompleted: 0,
        currentStreak: 0,
        longestStreak: 0,
        podcastBreakdowns: {},
        dailyListening: {},
        topPodcasts: [],
        lastUpdated: DateTime.now(),
      );
    }

    // Sort actions by timestamp
    final sortedActions = List<EpisodeAction>.from(actions)..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    int totalSeconds = 0;
    int completedCount = 0;
    final Map<String, PodcastStats> breakdowns = {};
    final Map<DateTime, int> dailySeconds = {};
    final Set<String> completedEpisodes = {};

    // Group actions by episode to calculate duration more accurately
    final Map<String, List<EpisodeAction>> episodeActions = {};
    for (var action in sortedActions) {
      episodeActions.putIfAbsent(action.episode, () => []).add(action);
    }

    for (var entry in episodeActions.entries) {
      final epActions = entry.value;
      final epId = entry.key;
      final firstAction = epActions.first;
      final podcastUrl = firstAction.podcast;
      
      final podcast = subscriptions.firstWhere(
        (p) => p.url == podcastUrl,
        orElse: () => Podcast(url: podcastUrl, title: 'Unknown Podcast'),
      );

      breakdowns.putIfAbsent(
        podcastUrl,
        () => PodcastStats(
          podcastUrl: podcastUrl,
          podcastTitle: podcast.title,
          logoUrl: podcast.logoUrl,
        ),
      );

      // Simple Duration Calculation:
      // For each segment in history, try to find the delta.
      // If started is available and > 0, we can use position - started.
      // If started is 0 or same as last position, we might have to use increments.
      
      int epSeconds = 0;
      for (var action in epActions) {
        int segment = 0;
        if (action.started != null && action.position != null && action.position! > action.started!) {
           segment = action.position! - action.started!;
        } else if (action.position != null && action.position! > 0) {
           // Fallback: if we just have a position, it might be the total since last sync
           // But without knowing 'started', we risk overcounting if we just sum positions.
           // Heuristic: if it's the only action or significantly larger than previous, 
           // let's use it as the "new" listening time.
           // Actually, standard gPodder behavior usually means the position is the LATEST position.
           // So for a single episode, the MAX position is a good proxy for total time spent if it was linear.
           // If we have multiple actions, we'll take the max position of that episode in that "session".
        }
        
        if (segment > 0) {
          epSeconds += segment;
          
          // Add to daily stats
          final date = DateTime.fromMillisecondsSinceEpoch(action.timestamp * 1000);
          final day = DateTime(date.year, date.month, date.day);
          dailySeconds[day] = (dailySeconds[day] ?? 0) + segment;
        }
      }

      // If epSeconds is still 0 but we have positions, fallback to max position 
      // This handles clients that don't set 'started' correctly but sync linear progress.
      if (epSeconds == 0) {
        int maxPos = 0;
        DateTime? latestDay;
        for (var action in epActions) {
           if (action.position != null && action.position! > maxPos) {
             maxPos = action.position!;
             final date = DateTime.fromMillisecondsSinceEpoch(action.timestamp * 1000);
             latestDay = DateTime(date.year, date.month, date.day);
           }
        }
        epSeconds = maxPos;
        if (latestDay != null) {
          dailySeconds[latestDay] = (dailySeconds[latestDay] ?? 0) + maxPos;
        }
      }

      totalSeconds += epSeconds;
      breakdowns[podcastUrl]!.totalTime += Duration(seconds: epSeconds);
      breakdowns[podcastUrl]!.episodeCount += 1;

      // Check for completion
      final lastAction = epActions.last;
      if (lastAction.total != null && lastAction.position != null && lastAction.total! > 0) {
        if (lastAction.position! >= (lastAction.total! * 0.95)) {
          completedCount++;
        }
      }
    }

    // Calculate Streaks
    final days = dailySeconds.keys.toList()..sort();
    int currentStreak = 0;
    int longestStreak = 0;
    
    if (days.isNotEmpty) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      
      // Longest
      int tempStreak = 1;
      for (int i = 0; i < days.length - 1; i++) {
        if (days[i+1].difference(days[i]).inDays == 1) {
          tempStreak++;
        } else {
          if (tempStreak > longestStreak) longestStreak = tempStreak;
          tempStreak = 1;
        }
      }
      if (tempStreak > longestStreak) longestStreak = tempStreak;

      // Current
      if (days.last == today || days.last == yesterday) {
        currentStreak = 1;
        for (int i = days.length - 1; i > 0; i--) {
          if (days[i].difference(days[i-1]).inDays == 1) {
            currentStreak++;
          } else {
            break;
          }
        }
      }
    }

    // Top Podcasts
    final topPods = breakdowns.values.toList()
      ..sort((a, b) => b.totalTime.compareTo(a.totalTime));

    return ListeningStats(
      totalListeningDuration: Duration(seconds: totalSeconds),
      episodesCompleted: completedCount,
      currentStreak: currentStreak,
      longestStreak: longestStreak,
      podcastBreakdowns: breakdowns,
      dailyListening: dailySeconds.map((k, v) => MapEntry(k, Duration(seconds: v))),
      topPodcasts: topPods.take(5).toList(),
      lastUpdated: DateTime.now(),
    );
  }
}
