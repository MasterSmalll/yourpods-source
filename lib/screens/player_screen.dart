import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../providers/podcast_provider.dart';
import '../providers/profile_provider.dart';
import '../widgets/action_button.dart';
import '../models/podcast.dart';

import 'package:shared_preferences/shared_preferences.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _isUsDateFormat = false; // Default to DD-MM-YYYY as requested
  double? _dragValue;
  bool _chaptersExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadDateFormat();
  }

  Future<void> _loadDateFormat() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        // User requested default DD-MM-YYYY, so default false.
        // Identify if key exists to respect previous "true" default from list screen if set?
        // If EpisodeList used ?? true, and we use ?? false, it might be inconsistent for new users.
        // But user explicitly asked for default DD-MM-YYYY.
        _isUsDateFormat = prefs.getBool('use_us_date_format') ?? false;
      });
    }
  }

  Future<void> _toggleDateFormat() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !_isUsDateFormat;
    await prefs.setBool('use_us_date_format', newValue);
    if (mounted) {
      setState(() {
        _isUsDateFormat = newValue;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Date format switched to ${newValue ? "MM-DD-YYYY" : "DD-MM-YYYY"}'),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        )
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final episode = playerProvider.currentEpisode;
    final podcast = playerProvider.currentPodcast;

    if (episode == null) {
      return const Scaffold(body: Center(child: Text('No episode selected')));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 32),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Consumer<DownloadProvider>(
        builder: (context, downloadProvider, child) {
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            children: [
              // Artwork
              // Artwork
              SizedBox(
                height: 250, // Fixed height to reduce size
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.deepPurple.withOpacity(0.3),
                            blurRadius: 30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: episode.imageUrl != null || podcast?.logoUrl != null
                            ? Image.network(
                                episode.imageUrl ?? podcast!.logoUrl!,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                color: const Color(0xFF1F1E27),
                                child: const Icon(Icons.podcasts, size: 80, color: Colors.white24),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              
              // Title
              Text(
                episode.title,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Metadata (Date • Duration) - With Long Press
              Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                      GestureDetector(
                          onLongPress: _toggleDateFormat,
                          child: Text(
                              _formatDate(episode.pubDate),
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                      ),
                      if (episode.duration != null) ...[
                          const SizedBox(width: 8),
                          const Text('•', style: TextStyle(color: Colors.white24, fontSize: 12)),
                          const SizedBox(width: 8),
                          Text(
                              _formatDurationFull(episode.duration!),
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                      ],
                  ],
              ),
              const SizedBox(height: 8),

              // Podcast Name
              Text(
                podcast?.title ?? 'Unknown Podcast',
                style: const TextStyle(fontSize: 16, color: Colors.deepPurpleAccent),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              
              // Progress Bar with Chapter Markers
              StreamBuilder<Duration>(
                stream: playerProvider.player.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  final duration = playerProvider.player.duration ?? Duration.zero;
                  final effectivePosition = _dragValue != null 
                      ? Duration(milliseconds: _dragValue!.toInt()) 
                      : position;
                  final chapters = playerProvider.currentChapters;
                  final currentChapter = playerProvider.getCurrentChapter(effectivePosition);

                  return Column(
                    children: [
                      // Seek bar with chapter tick marks
                      Stack(
                        children: [
                          Slider(
                            value: (_dragValue ?? position.inMilliseconds.toDouble()).clamp(0.0, duration.inMilliseconds.toDouble()),
                            max: duration.inMilliseconds == 0 ? 100 : duration.inMilliseconds.toDouble(),
                            onChangeStart: (value) {
                                setState(() {
                                    _dragValue = value;
                                });
                            },
                            onChanged: (value) {
                                setState(() {
                                    _dragValue = value;
                                });
                            },
                            onChangeEnd: (value) {
                              playerProvider.player.seek(Duration(milliseconds: value.toInt()));
                              setState(() {
                                  _dragValue = null;
                              });
                            },
                            activeColor: Colors.deepPurpleAccent,
                            inactiveColor: Colors.white24,
                          ),
                          // Chapter tick marks overlay
                          if (chapters != null && chapters.isNotEmpty && duration.inMilliseconds > 0)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _ChapterMarkerPainter(
                                    chapters: chapters,
                                    totalDurationMs: duration.inMilliseconds.toDouble(),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_formatDuration(effectivePosition), style: const TextStyle(color: Colors.white60)),
                            Text(_formatDuration(duration), style: const TextStyle(color: Colors.white60)),
                          ],
                        ),
                      ),
                      // Current chapter label
                      if (currentChapter != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            currentChapter.title,
                            style: const TextStyle(
                              color: Colors.deepPurpleAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              
              // Transport Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                   // Speed Control
                   TextButton(
                       onPressed: playerProvider.cycleSpeed,
                       child: Text(
                           '${playerProvider.speed}x',
                           style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                       ),
                   ),
                
                  IconButton(
                    icon: const Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(Icons.replay_10, size: 36, color: Colors.transparent), // Placeholder for sizing if needed or use custom
                        Icon(Icons.replay, size: 36, color: Colors.white),
                        Positioned(
                             top: 14,
                             child: Text("15", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))
                        )
                      ]
                    ),
                    onPressed: playerProvider.rewind,
                  ),
                   GestureDetector(
                    onTap: playerProvider.togglePlay,
                    child: Container(
                      height: 64, // Slightly smaller controls
                      width: 64,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.deepPurpleAccent,
                      ),
                      child: Icon(
                        playerProvider.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 36,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_30, size: 36, color: Colors.white),
                    onPressed: playerProvider.fastForward,
                  ),
                  
                  // Options / Sleep Timer
                  IconButton(
                      icon: Icon(
                          playerProvider.isSleepTimerActive ? Icons.timer : Icons.tune, 
                          color: playerProvider.isSleepTimerActive ? Colors.deepPurpleAccent : Colors.white,
                      ),
                      onPressed: () => _showPlaybackSettings(context, playerProvider),
                  ),
                ],
              ),
              if (playerProvider.isSleepTimerActive && playerProvider.sleepTimerEndTime != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                          'Sleep timer ends at ${_formatTime(playerProvider.sleepTimerEndTime!)}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                      ),
                  ),
              const SizedBox(height: 24),

              // Compact Action Row
              Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                      // Download
                      ActionButton(
                          icon: _getDownloadIcon(downloadProvider.getStatus(episode.audioUrl ?? '')),
                          color: _getDownloadColor(downloadProvider.getStatus(episode.audioUrl ?? '')),
                          label: 'Download',
                          onPressed: () {
                              final status = downloadProvider.getStatus(episode.audioUrl ?? '');
                              if (status == DownloadState.downloaded) {
                                  downloadProvider.deletedownload(episode.audioUrl ?? '');
                              } else if (status != DownloadState.downloading) {
                                  downloadProvider.downloadEpisode(episode.audioUrl ?? '');
                              }
                          },
                      ),
                      const SizedBox(width: 24),

                      // Mark Played
                      ActionButton(
                          icon: Icons.check_circle_outline,
                          label: 'Played',
                          onPressed: () async {
                              if (podcast != null) {
                                  final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
                                  final deviceId = profileProvider.currentProfile?.deviceId ?? 'yourpods-ios';
                                  
                                  await Provider.of<PodcastProvider>(context, listen: false)
                                      .markEpisodesAsPlayed(
                                          [
                                            {'podcast': podcast, 'episode': episode}
                                          ],
                                          deviceId
                                      );
                                  if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Marked as played')),
                                      );
                                      Navigator.pop(context); 
                                  }
                              }
                          },
                      ),
                      const SizedBox(width: 24),
                      
                      // Mark New
                      ActionButton(
                          icon: Icons.mark_chat_unread_outlined,
                          label: 'New',
                          onPressed: () async {
                              if (podcast != null) {
                                  await Provider.of<PodcastProvider>(context, listen: false)
                                      .markEpisodeAsUnplayed(podcast.url, episode.guid);
                                  if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Marked as unplayed')),
                                      );
                                  }
                              }
                          },
                      ),
                      const SizedBox(width: 24),
                      
                      // Add to Queue
                      ActionButton(
                          icon: Icons.playlist_add,
                          label: 'Queue',
                          onPressed: () {
                              if (podcast != null) {
                                  final player = Provider.of<PlayerProvider>(context, listen: false);
                                  player.addToQueue(podcast, episode);
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to queue')));
                              }
                          },
                      ),
                  ],
              ),
              const SizedBox(height: 24),
              
              // Chapters Section (only if chapters exist)
              if (playerProvider.currentChapters != null && playerProvider.currentChapters!.isNotEmpty) ...[
                const Divider(color: Colors.white12),
                _buildChaptersSection(playerProvider),
              ],
              
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),

              // Description
              Text(
                  _stripHtml(episode.description ?? 'No description available.'),
                  style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
              ),
              const SizedBox(height: 48),
              const SizedBox(height: 48),
            ],
          );
        },
      ),
    );
  }

  IconData _getDownloadIcon(DownloadState status) {
      if (status == DownloadState.downloaded) return Icons.check_circle;
      if (status == DownloadState.downloading) return Icons.downloading;
      return Icons.download_for_offline_outlined;
  }

  Color _getDownloadColor(DownloadState status) {
      if (status == DownloadState.downloaded) return Colors.greenAccent;
      if (status == DownloadState.downloading) return Colors.deepPurpleAccent;
      return Colors.white70;
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    if (_isUsDateFormat) {
        return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}-${date.year}';
    } else {
        return '${date.day.toString().padLeft(2, '0')}-${date.month.toString().padLeft(2, '0')}-${date.year}';
    }
  }

  String _formatDurationFull(Duration d) {
      if (d.inHours > 0) {
          return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
      }
      return '${d.inMinutes}m';
  }

  String _stripHtml(String htmlString) {
      // Replace <br> and <p> with newlines to preserve formatting
      var formatted = htmlString.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
      formatted = formatted.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n');
      
      final RegExp exp = RegExp(r"<[^>]*>", multiLine: true, caseSensitive: true);
      return formatted.replaceAll(exp, '').trim();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return d.inHours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _formatTime(DateTime time) {
      final hour = time.hour.toString().padLeft(2, '0');
      final minute = time.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
  }

  void _showPlaybackSettings(BuildContext context, PlayerProvider player) {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1F1E27),
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (context) {
              return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          const Text(
                              'Playback Settings',
                              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 24),
                          
                          // Silence Skipping
                          Consumer<PlayerProvider>(
                              builder: (context, p, _) {
                                  return SwitchListTile(
                                      title: const Text('Skip Silence', style: TextStyle(color: Colors.white)),
                                      activeColor: Colors.deepPurpleAccent,
                                      value: p.skipSilenceEnabled,
                                      onChanged: (val) => p.toggleSkipSilence(),
                                  );
                              },
                          ),
                          
                          const Divider(color: Colors.white12),
                          const SizedBox(height: 8),
                          const Text('Sleep Timer', style: TextStyle(color: Colors.white70, fontSize: 14)),
                          const SizedBox(height: 8),
                          
                          // Sleep Timer Options
                          Wrap(
                              spacing: 8,
                              children: [
                                  _buildTimerChip(context, player, null, 'Off'),
                                  _buildTimerChip(context, player, const Duration(minutes: 5), '5m'),
                                  _buildTimerChip(context, player, const Duration(minutes: 15), '15m'),
                                  _buildTimerChip(context, player, const Duration(minutes: 30), '30m'),
                                  _buildTimerChip(context, player, const Duration(minutes: 60), '60m'),
                              ],
                          ),
                          const SizedBox(height: 24),
                      ],
                  ),
              );
          },
      );
  }

  Widget _buildTimerChip(BuildContext context, PlayerProvider player, Duration? duration, String label) {
       // Check if this specific duration matches is hard without state in provider.
       // So just show simple chips.
      return ActionChip(
          label: Text(label),
          backgroundColor: const Color(0xFF2A2935),
          labelStyle: const TextStyle(color: Colors.white),
          onPressed: () {
              if (duration == null) {
                  player.cancelSleepTimer();
              } else {
                  player.setSleepTimer(duration);
              }
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(duration == null ? 'Sleep timer cancelled' : 'Sleep timer set for $label'),
                      duration: const Duration(seconds: 1),
                  )
              );
          },
      );
  }

  Widget _buildChaptersSection(PlayerProvider playerProvider) {
    final chapters = playerProvider.currentChapters!;
    return Column(
      children: [
        // Header row (tap to expand/collapse)
        InkWell(
          onTap: () => setState(() => _chaptersExpanded = !_chaptersExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Row(
              children: [
                const Icon(Icons.list, color: Colors.deepPurpleAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Chapters (${chapters.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Icon(
                  _chaptersExpanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white60,
                ),
              ],
            ),
          ),
        ),
        // Chapter list (expanded)
        if (_chaptersExpanded)
          ...chapters.asMap().entries.map((entry) {
            final index = entry.key;
            final chapter = entry.value;
            final nextChapter = index + 1 < chapters.length ? chapters[index + 1] : null;
            final chapterDuration = nextChapter != null
                ? Duration(seconds: (nextChapter.startTime - chapter.startTime).toInt())
                : null;

            return InkWell(
              onTap: () {
                playerProvider.player.seek(
                  Duration(seconds: chapter.startTime.toInt()),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
                child: Row(
                  children: [
                    // Chapter number
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ),
                    // Chapter title
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chapter.title,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (chapterDuration != null)
                            Text(
                              _formatDuration(chapterDuration),
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    // Timestamp
                    Text(
                      _formatDuration(Duration(seconds: chapter.startTime.toInt())),
                      style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

/// Custom painter that draws vertical tick marks on the seek bar for each chapter.
class _ChapterMarkerPainter extends CustomPainter {
  final List<Chapter> chapters;
  final double totalDurationMs;

  _ChapterMarkerPainter({required this.chapters, required this.totalDurationMs});

  @override
  void paint(Canvas canvas, Size size) {
    if (totalDurationMs <= 0) return;

    final paint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..strokeWidth = 1.5;

    // The Slider has internal padding (~24px each side on Material).
    // We approximate the track area.
    const sliderPadding = 24.0;
    final trackWidth = size.width - (sliderPadding * 2);
    final centerY = size.height / 2;
    final tickHeight = 8.0;

    for (final chapter in chapters) {
      if (chapter.startTime <= 0) continue; // Skip the 0-second marker
      final fraction = (chapter.startTime * 1000) / totalDurationMs;
      if (fraction < 0 || fraction > 1) continue;
      final x = sliderPadding + (fraction * trackWidth);
      canvas.drawLine(
        Offset(x, centerY - tickHeight),
        Offset(x, centerY + tickHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ChapterMarkerPainter oldDelegate) {
    return chapters != oldDelegate.chapters ||
        totalDurationMs != oldDelegate.totalDurationMs;
  }
}
