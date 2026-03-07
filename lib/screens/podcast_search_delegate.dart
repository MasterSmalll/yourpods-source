import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/podcast_search_result.dart';
import '../providers/podcast_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/settings_provider.dart';
import '../services/podcast_search_provider.dart';
import '../api/rss_service.dart';
import '../models/podcast.dart';

class PodcastSearchDelegate extends SearchDelegate<PodcastSearchResult?> {
  Timer? _debounce;
  List<PodcastSearchResult> _results = [];
  bool _isSearching = false;
  String? _errorMessage;

  PodcastSearchDelegate({required String hintText})
      : super(searchFieldLabel: hintText);

  PodcastSearchProvider _getProvider(SettingsProvider settings) {
    switch (settings.searchProviderId) {
      case 'podcastindex':
        return PodcastIndexSearchProvider(
          apiKey: settings.podcastIndexApiKey,
          apiSecret: settings.podcastIndexApiSecret,
        );
      case 'itunes':
      default:
        return ITunesSearchProvider();
    }
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    return Theme.of(context).copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1F1E27),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: Colors.white38),
        border: InputBorder.none,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: Colors.white, fontSize: 18),
      ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.add_link, color: Colors.white70),
        tooltip: 'Add by URL',
        onPressed: () {
          showDialog(
            context: context,
            builder: (ctx) => _AddByUrlDialog(),
          );
        },
      ),
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear, color: Colors.white70),
          onPressed: () {
            query = '';
            _results = [];
            showSuggestions(context);
          },
        ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back, color: Colors.white70),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchBody(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.length < 2) {
      return Container(
        color: const Color(0xFF0F0E17),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search, size: 64, color: Colors.white24),
              const SizedBox(height: 16),
              Text(
                'Search for podcasts',
                style: TextStyle(color: Colors.white38, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Consumer<SettingsProvider>(
                builder: (context, settings, _) {
                  final providerName = settings.searchProviderId == 'podcastindex'
                      ? 'PodcastIndex'
                      : 'iTunes';
                  return Text(
                    'Using $providerName',
                    style: const TextStyle(color: Colors.white24, fontSize: 12),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    // Debounced search-as-you-type
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(context);
    });

    return _buildSearchBody(context);
  }

  Future<void> _performSearch(BuildContext context) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final provider = _getProvider(settings);

    _isSearching = true;
    _errorMessage = null;
    // Trigger rebuild
    showSuggestions(context);

    try {
      _results = await provider.search(query);
      _errorMessage = null;
    } catch (e) {
      _errorMessage = e.toString();
      _results = [];
    }

    _isSearching = false;
    showSuggestions(context);
  }

  Widget _buildSearchBody(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0E17),
      child: _isSearching
          ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          'Search failed',
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : _results.isEmpty
                  ? Center(
                      child: Text(
                        query.length >= 2 ? 'No results found' : '',
                        style: const TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        return _buildResultTile(context, result);
                      },
                    ),
    );
  }

  Widget _buildResultTile(BuildContext context, PodcastSearchResult result) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: result.artworkUrl != null
            ? Image.network(
                result.artworkUrl!,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 56,
                  height: 56,
                  color: const Color(0xFF2A2935),
                  child: const Icon(Icons.podcasts, color: Colors.white24),
                ),
              )
            : Container(
                width: 56,
                height: 56,
                color: const Color(0xFF2A2935),
                child: const Icon(Icons.podcasts, color: Colors.white24),
              ),
      ),
      title: Text(
        result.title,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: result.author != null
          ? Text(
              result.author!,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: const Icon(Icons.add_circle_outline, color: Colors.deepPurpleAccent),
      onTap: () => _subscribeToPodcast(context, result),
    );
  }

  Future<void> _subscribeToPodcast(BuildContext context, PodcastSearchResult result) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SubscribeDialog(result: result),
    );

    if (confirmed == true && context.mounted) {
      try {
        final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
        final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
        final deviceId = profileProvider.currentProfile?.deviceId ?? 'flutter-client';

        await podcastProvider.subscribe(result.feedUrl, deviceId);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Subscribed to "${result.title}"'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          close(context, result);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to subscribe: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }
}

class _SubscribeDialog extends StatefulWidget {
  final PodcastSearchResult result;
  const _SubscribeDialog({required this.result});

  @override
  State<_SubscribeDialog> createState() => _SubscribeDialogState();
}

class _SubscribeDialogState extends State<_SubscribeDialog> {
  String? _feedDescription;
  List<Episode> _recentEpisodes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchFeedData();
  }

  Future<void> _fetchFeedData() async {
    try {
      final rssService = RssService();
      // Fetch both metadata and episodes in parallel
      final results = await Future.wait([
        rssService.getFeedMetadata(widget.result.feedUrl),
        rssService.fetchEpisodes(widget.result.feedUrl),
      ]);
      if (mounted) {
        final metadata = results[0] as Podcast;
        final episodes = results[1] as List<Episode>;
        // Sort by date descending and take top 3
        episodes.sort((a, b) => (b.pubDate ?? DateTime(1970)).compareTo(a.pubDate ?? DateTime(1970)));
        setState(() {
          _feedDescription = metadata.description;
          _recentEpisodes = episodes.take(3).toList();
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final description = _feedDescription ?? result.description;

    return AlertDialog(
      backgroundColor: const Color(0xFF1F1E27),
      title: const Text('Subscribe', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.artworkUrl != null)
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      result.artworkUrl!,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                result.title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              if (result.author != null) ...[
                const SizedBox(height: 4),
                Text(result.author!, style: const TextStyle(color: Colors.white54)),
              ],
              if (result.genre != null && result.genre!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: result.genre!.split(', ').take(3).map((g) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(g, style: const TextStyle(color: Colors.white60, fontSize: 11)),
                  )).toList(),
                ),
              ],
              if (_isLoading) ...[
                const SizedBox(height: 12),
                const Center(child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
                )),
              ] else ...[
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    description,
                    style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (_recentEpisodes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Recent Episodes',
                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  ...(_recentEpisodes.map((ep) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2935),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ep.title,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (ep.pubDate != null) ...[
                              Icon(Icons.calendar_today, color: Colors.white38, size: 11),
                              const SizedBox(width: 4),
                              Text(
                                _formatDate(ep.pubDate),
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                            if (ep.pubDate != null && ep.duration != null)
                              const SizedBox(width: 12),
                            if (ep.duration != null) ...[
                              Icon(Icons.timer_outlined, color: Colors.white38, size: 11),
                              const SizedBox(width: 4),
                              Text(
                                _formatDuration(ep.duration),
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ))),
                ],
              ],
              const SizedBox(height: 12),
              Text(
                'Add this podcast to your library?',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Subscribe', style: TextStyle(color: Colors.deepPurpleAccent)),
        ),
      ],
    );
  }
}

class _AddByUrlDialog extends StatefulWidget {
  @override
  State<_AddByUrlDialog> createState() => _AddByUrlDialogState();
}

class _AddByUrlDialogState extends State<_AddByUrlDialog> {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _requiresAuth = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1E27),
      title: const Text('Add Podcast by URL', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Enter RSS Feed URL',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurple)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurpleAccent)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.lock_outline, color: Colors.white54, size: 18),
                const SizedBox(width: 8),
                const Text('Authentication Required', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const Spacer(),
                Switch(
                  value: _requiresAuth,
                  onChanged: (val) => setState(() => _requiresAuth = val),
                  activeThumbColor: Colors.deepPurpleAccent,
                ),
              ],
            ),
            if (_requiresAuth) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: Colors.orangeAccent, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Feed credentials are stored locally and won\'t sync to other devices via gPodder. For cross-device sync, embed credentials in the URL instead:\nhttps://user:pass@host/feed.xml',
                        style: TextStyle(color: Colors.orangeAccent, fontSize: 11, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Username',
                  hintStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.person_outline, color: Colors.white38, size: 20),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurple)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurpleAccent)),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Password',
                  hintStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.lock_outline, color: Colors.white38, size: 20),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurple)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.deepPurpleAccent)),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
        ),
        TextButton(
          onPressed: _isLoading ? null : _onAdd,
          child: _isLoading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent))
              : const Text('Add', style: TextStyle(color: Colors.deepPurpleAccent)),
        ),
      ],
    );
  }

  Future<void> _onAdd() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final feedUsername = _requiresAuth ? _usernameController.text.trim() : null;
      final feedPassword = _requiresAuth ? _passwordController.text : null;

      final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
      final deviceId = profileProvider.currentProfile?.deviceId ?? 'flutter-client';

      await Provider.of<PodcastProvider>(context, listen: false).subscribe(
        url,
        deviceId,
        feedUsername: feedUsername,
        feedPassword: feedPassword,
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Podcast added successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add podcast: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }
}
