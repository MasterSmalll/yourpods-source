import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/podcast_search_result.dart';
import '../providers/podcast_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/settings_provider.dart';
import '../services/podcast_search_provider.dart';

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
                errorBuilder: (_, __, ___) => Container(
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
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1E27),
        title: const Text('Subscribe', style: TextStyle(color: Colors.white)),
        content: Column(
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
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
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
            const SizedBox(height: 12),
            Text(
              'Add this podcast to your library?',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Subscribe', style: TextStyle(color: Colors.deepPurpleAccent)),
          ),
        ],
      ),
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
