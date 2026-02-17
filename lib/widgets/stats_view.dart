import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/listening_stats_service.dart';
import '../models/podcast.dart';

class StatsView extends StatelessWidget {
  final ListeningStats stats;
  final VoidCallback? onRefresh;

  const StatsView({
    super.key,
    required this.stats,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh?.call(),
      color: Colors.tealAccent,
      backgroundColor: const Color(0xFF1F1E27),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeroStats(),
            const SizedBox(height: 24),
            _buildSectionTitle('Listening Activity'),
            const SizedBox(height: 12),
            _buildActivityChart(),
            const SizedBox(height: 24),
            _buildSectionTitle('Top Podcasts'),
            const SizedBox(height: 12),
            _buildTopPodcasts(),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Stats based on all synced gPodder history.\nLast updated: ${DateFormat.yMMMd().add_jm().format(stats.lastUpdated)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white30, fontSize: 11),
              ),
            ),
            const SizedBox(height: 120), // NowPlayingBar padding
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  Widget _buildHeroStats() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            label: 'Hours',
            value: (stats.totalListeningDuration.inSeconds / 3600).toStringAsFixed(1),
            icon: Icons.access_time_filled,
            color: Colors.blueAccent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            label: 'Done',
            value: stats.episodesCompleted.toString(),
            icon: Icons.check_circle,
            color: Colors.tealAccent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            label: 'Streak',
            value: '${stats.currentStreak}d',
            icon: Icons.local_fire_department,
            color: Colors.orangeAccent,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E27),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityChart() {
    return Container(
      height: 160,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E27),
        borderRadius: BorderRadius.circular(16),
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarChartPainter(dailyListening: stats.dailyListening),
      ),
    );
  }

  Widget _buildTopPodcasts() {
    if (stats.topPodcasts.isEmpty) {
      return const Center(
        child: Text('No podcast data available yet.', style: TextStyle(color: Colors.white30)),
      );
    }

    final maxTime = stats.topPodcasts.first.totalTime.inSeconds;

    return Column(
      children: stats.topPodcasts.map((pod) {
        final progress = maxTime > 0 ? pod.totalTime.inSeconds / maxTime : 0.0;
        final hours = (pod.totalTime.inSeconds / 3600).toStringAsFixed(1);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: pod.logoUrl != null
                    ? Image.network(pod.logoUrl!, width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 96, cacheHeight: 96)
                    : Container(
                        width: 48,
                        height: 48,
                        color: Colors.white12,
                        child: const Icon(Icons.podcasts, color: Colors.white30),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pod.podcastTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Stack(
                      children: [
                        Container(
                          height: 6,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: progress,
                          child: Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.deepPurpleAccent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                '${hours}h',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  final Map<DateTime, Duration> dailyListening;

  _BarChartPainter({required this.dailyListening});

  @override
  void paint(Canvas canvas, Size size) {
    if (dailyListening.isEmpty) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last30Days = <DateTime>[];
    for (int i = 29; i >= 0; i--) {
      last30Days.add(today.subtract(Duration(days: i)));
    }

    int maxSeconds = 0;
    for (var d in last30Days) {
      final seconds = dailyListening[d]?.inSeconds ?? 0;
      if (seconds > maxSeconds) maxSeconds = seconds;
    }
    // Min max to avoid 0 division and for visual scale (e.g. 1 hour min scale)
    if (maxSeconds < 3600) maxSeconds = 3600;

    final barWidth = (size.width / 30) * 0.7;
    final spacing = (size.width / 30) * 0.3;

    final paint = Paint()
      ..color = Colors.tealAccent.withOpacity(0.3)
      ..style = PaintingStyle.fill;

    final activePaint = Paint()
      ..color = Colors.tealAccent
      ..style = PaintingStyle.fill;

    for (int i = 0; i < 30; i++) {
      final day = last30Days[i];
      final seconds = dailyListening[day]?.inSeconds ?? 0;
      final barHeight = (seconds / maxSeconds) * size.height;
      
      final rect = Rect.fromLTWH(
        i * (barWidth + spacing),
        size.height - barHeight,
        barWidth,
        barHeight,
      );

      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );

      canvas.drawRRect(rrect, seconds > 0 ? activePaint : paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
