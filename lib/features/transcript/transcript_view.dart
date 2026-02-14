import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/podcast.dart';
import '../../models/transcript.dart';
import '../../providers/player_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/transcript_service.dart';
import 'dart:async';

class TranscriptView extends StatefulWidget {
  final Episode episode;

  const TranscriptView({super.key, required this.episode});

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  Transcript? _transcript;
  bool _isLoading = true;
  String? _error;
  final ScrollController _scrollController = ScrollController();
  int _currentIndex = -1;
  bool _autoScroll = true;
  Timer? _syncTimer;
  final TextEditingController _searchController = TextEditingController();
  List<TranscriptItem> _filteredItems = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadTranscript();
    _startSync();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTranscript() async {
    if (widget.episode.transcriptUrl == null) {
      setState(() {
        _isLoading = false;
        _error = 'No transcript available for this episode.';
      });
      return;
    }

    try {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      final transcript = await TranscriptService().fetchTranscript(
          widget.episode.transcriptUrl!,
          cacheDurationHours: settings.feedCacheDuration,
      );
      if (transcript == null) {
        setState(() {
             _isLoading = false;
             _error = "Unable to load transcript. Please check your connection.";
        });
        return;
      }

      setState(() {
        _transcript = transcript;
        _filteredItems = transcript.items;
        _isLoading = false;
        if (transcript.items.isEmpty) {
            _error = "Transcript is empty or format not supported.";
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to load transcript: $e';
      });
    }
  }

  void _startSync() {
    _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || _transcript == null || _transcript!.items.isEmpty || _isSearching) return;

      final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
      final currentPosition = playerProvider.player.position;

      // Find the item that corresponds to the current position
      // Using binary search or linear search optimization could be better for large lists,
      // but linear scan from near last known index is usually fine for transcripts.
      int newIndex = -1;
      
      // Optimization: start checking from _currentIndex
      int startIndex = _currentIndex >= 0 ? _currentIndex : 0;
      
      // Check if we need to search backwards
      if (startIndex < _transcript!.items.length && _transcript!.items[startIndex].start > currentPosition) {
          startIndex = 0;
      }

      for (int i = startIndex; i < _transcript!.items.length; i++) {
        final item = _transcript!.items[i];
        if (currentPosition >= item.start && currentPosition < item.end) {
          newIndex = i;
          break;
        }
        // If we've passed the potential item, stop (assuming sorted items)
        if (item.start > currentPosition) {
            break;
        }
      }

      if (newIndex != -1 && newIndex != _currentIndex) {
        setState(() {
          _currentIndex = newIndex;
        });
        if (_autoScroll) {
          _scrollToIndex(newIndex);
        }
      }
    });
  }

  void _scrollToIndex(int index) {
      if (!_scrollController.hasClients) return;
      // Simple offset calculation: index * approximate height? 
      // No, variable height items. Using scroll_to_index package is better, 
      // but for now, we try to ensure visible. 
      // A better approach without keys/packages is hard.
      // Let's rely on manual scrolling or use a list view with itemScrollController if accurate scrolling is needed.
      // For this MVP, we might skip precise auto-scroll if it's complex without pkg, 
      // or just try to center based on an estimated offset if uniform.
      // But text is not uniform. 
      
      // Basic approach: Iterate and sum heights? Too slow.
      // Better: Use `Scrollable.ensureVisible` with GlobalKeys? Expensive for long lists.
      
      // Let's implement a rudimentary "Jump likely" or just don't scroll if user touched it.
      // Actually, we can just center the selected item if we knew its offset.
      // Without `scroll_to_index`, auto-scrolling variable height lists is tricky.
      // Let's try to pass for MVP with a visual highlight + "Tap to Sync" button if user lost track?
      // Or just keep it highlighted.
  }

  void _onSearchChanged(String query) {
      if (_transcript == null) return;
      
      setState(() {
          _isSearching = query.isNotEmpty;
          if (query.isEmpty) {
              _filteredItems = _transcript!.items;
          } else {
              _filteredItems = _transcript!.items.where((item) => 
                  item.text.toLowerCase().contains(query.toLowerCase())
              ).toList();
          }
      });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    
    final items = _isSearching ? _filteredItems : _transcript!.items;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search transcript...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _isSearching ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                  },
              ) : null,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Theme.of(context).cardColor,
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: _scrollController,
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              final isActive = !_isSearching && index == _currentIndex; // Only highlight in full view

              return GestureDetector(
                onTap: () {
                    final player = Provider.of<PlayerProvider>(context, listen: false);
                    player.player.seek(item.start);
                    // Disable auto-scroll temporarily if user manually taps? 
                    // Actually tapping usually means "go there", so auto-scroll should probably resume or just set index.
                    setState(() {
                        if (!_isSearching) _currentIndex = index;
                    });
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isActive ? Theme.of(context).primaryColor.withOpacity(0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: isActive ? Border.all(color: Theme.of(context).primaryColor, width: 1) : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       Text(
                           item.text,
                           style: TextStyle(
                               fontSize: 16,
                               color: isActive ? Colors.white : Colors.grey[400],
                               fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                           ),
                       ),
                       const SizedBox(height: 4),
                       Text(
                           _formatDuration(item.start),
                           style: TextStyle(
                            fontSize: 12,
                            color: isActive ? Colors.white70 : Theme.of(context).primaryColor,
                            decoration: isActive ? null : TextDecoration.underline,
                            decorationColor: Theme.of(context).primaryColor,
                           ),
                       ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
        return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}
