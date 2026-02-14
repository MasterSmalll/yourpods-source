import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/podcast_provider.dart';
import '../models/podcast.dart';
import '../providers/profile_provider.dart';
import '../api/gpodder_api.dart'; // For EpisodeAction
import 'package:intl/intl.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/stats_view.dart';
import '../services/listening_stats_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = Provider.of<PodcastProvider>(context, listen: false);
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    
    final deviceId = profileProvider.currentProfile?.deviceId;
    if (deviceId == null) {
        setState(() => _isLoading = false);
        return;
    }

    final history = await provider.fetchListeningHistory(deviceId);
    
    if (mounted) {
      setState(() {
        _history = history;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Listening History'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: const Icon(Icons.home),
              onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false),
              tooltip: 'Home',
            ),
          ],
          bottom: const TabBar(
            indicatorColor: Colors.deepPurpleAccent,
            tabs: [
              Tab(text: 'Activity', icon: Icon(Icons.list)),
              Tab(text: 'Statistics', icon: Icon(Icons.bar_chart)),
            ],
          ),
        ),
        body: Stack(
          children: [
            TabBarView(
              children: [
                // Activity Tab
                _buildActivityTab(),
                // Stats Tab
                _buildStatsTab(settings),
              ],
            ),
            const Align(
              alignment: Alignment.bottomCenter,
              child: NowPlayingBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityTab() {
    return Column(
      children: [
        Expanded(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.deepPurple))
              : _history.isEmpty
                  ? const Center(
                      child: Text('No history found.',
                          style: TextStyle(color: Colors.white70)))
                  : ListView.builder(
                      padding: const EdgeInsets.only(
                          left: 16, right: 16, top: 16, bottom: 120),
                      itemCount: _history.length,
                      itemBuilder: (context, index) {
                        final item = _history[index];
                        final podcast = item['podcast'] as Podcast;
                        final action = item['action'] as EpisodeAction;
                        final episode = item['episode'] as Episode;

                        final date = DateTime.fromMillisecondsSinceEpoch(
                            action.timestamp * 1000);
                        final formattedDate =
                            DateFormat.yMMMd().add_jm().format(date);

                        final isDelete =
                            action.position == 0 && action.action == 'play';

                        return Card(
                          color: const Color(0xFF1F1E27),
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          child: ListTile(
                            leading: podcast.logoUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(podcast.logoUrl!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover),
                                  )
                                : const Icon(Icons.history,
                                    color: Colors.white54),
                            title: Text(
                              podcast.title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  episode.title,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 13),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                        isDelete
                                            ? Icons.delete_outline
                                            : Icons.play_arrow,
                                        size: 14,
                                        color: isDelete
                                            ? Colors.redAccent
                                            : Colors.deepPurpleAccent),
                                    const SizedBox(width: 4),
                                    Text(
                                      isDelete
                                          ? 'Reset/Removed'
                                          : 'Action: ${action.action}',
                                      style: TextStyle(
                                          color: isDelete
                                              ? Colors.redAccent
                                              : Colors.deepPurpleAccent,
                                          fontSize: 12),
                                    ),
                                    const Spacer(),
                                    Text(
                                      formattedDate,
                                      style: const TextStyle(
                                          color: Colors.white38, fontSize: 10),
                                    ),
                                  ],
                                ),
                                if (!isDelete && action.position != null)
                                  Text(
                                    'Position: ${_formatDuration(Duration(seconds: action.position!))}',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 10),
                                  ),
                              ],
                            ),
                            onTap: () {
                              // Play the episode
                              Provider.of<PlayerProvider>(context,
                                      listen: false)
                                  .play(podcast, episode);
                              Navigator.pushNamedAndRemoveUntil(
                                  context, '/home', (route) => false);
                            },
                          ),
                        );
                      },
                    ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 120.0),
          child: Text(
            "Podcast history cannot be deleted from YourPods",
            style: TextStyle(
                color: Colors.white30,
                fontSize: 12,
                fontStyle: FontStyle.italic),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsTab(SettingsProvider settings) {
    if (!settings.enableListenerStats) {
      return _buildStatsOptIn(settings);
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.deepPurple));
    }

    if (_history.isEmpty) {
      return const Center(child: Text('No activity data to compute stats.'));
    }

    // Compute stats from current history
    final actions = _history.map((h) => h['action'] as EpisodeAction).toList();
    final subscriptions = Provider.of<PodcastProvider>(context, listen: false).subscriptions;
    final stats = ListeningStatsService.computeStats(actions: actions, subscriptions: subscriptions);

    return StatsView(
      stats: stats,
      onRefresh: () async => _loadData(),
    );
  }

  Widget _buildStatsOptIn(SettingsProvider settings) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bar_chart, size: 80, color: Colors.white12),
            const SizedBox(height: 24),
            const Text(
              'Listening Statistics',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text(
              'See your listening hours, habits, and top shows. Stats are computed from your synced history.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                settings.setEnableListenerStats(true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Enable Stats'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }
}
