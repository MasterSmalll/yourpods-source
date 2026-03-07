import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/podcast_provider.dart';
import '../providers/profile_provider.dart';
import '../services/opml_service.dart';

/// Screen for importing podcasts from an OPML file.
/// Supports file picker and manual URL/path input.
class PodcastImportScreen extends StatefulWidget {
  const PodcastImportScreen({super.key});

  @override
  State<PodcastImportScreen> createState() => _PodcastImportScreenState();
}

enum _ImportState { input, preview, importing, complete }

class _PodcastImportScreenState extends State<PodcastImportScreen> {
  _ImportState _state = _ImportState.input;
  final _urlController = TextEditingController();
  
  // Parsed data
  List<Map<String, dynamic>> _parsedFeeds = [];
  final Set<int> _selectedIndices = {};
  
  // Progress
  int _progressCurrent = 0;
  int _progressTotal = 0;
  
  // Result
  ImportResult? _importResult;
  
  // Error
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        _processOpmlContent(content);
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to read file: $e';
      });
    }
  }

  Future<void> _loadFromUrl() async {
    final path = _urlController.text.trim();
    if (path.isEmpty) return;

    setState(() { _error = null; });

    try {
      // Support local file paths
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        _processOpmlContent(content);
        return;
      }
      
      setState(() {
        _error = 'File not found at the specified path.';
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load: $e';
      });
    }
  }

  void _processOpmlContent(String content) {
    final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
    final feeds = podcastProvider.parseOpmlForImport(content);

    if (feeds.isEmpty) {
      setState(() {
        _error = 'No podcast feeds found in the file. Make sure it is a valid OPML file.';
      });
      return;
    }

    // Pre-select all non-subscribed feeds
    final indices = <int>{};
    for (int i = 0; i < feeds.length; i++) {
      if (!(feeds[i]['isSubscribed'] as bool)) {
        indices.add(i);
      }
    }

    setState(() {
      _parsedFeeds = feeds;
      _selectedIndices.clear();
      _selectedIndices.addAll(indices);
      _state = _ImportState.preview;
      _error = null;
    });
  }

  Future<void> _startImport() async {
    final selectedFeeds = _selectedIndices
        .map((i) => _parsedFeeds[i]['feed'] as OpmlFeed)
        .toList();

    if (selectedFeeds.isEmpty) return;

    final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    final deviceId = profileProvider.currentProfile?.deviceId ?? 'flutter-client';

    setState(() {
      _state = _ImportState.importing;
      _progressCurrent = 0;
      _progressTotal = selectedFeeds.length;
    });

    final result = await podcastProvider.subscribeToFeeds(
      selectedFeeds,
      deviceId,
      onProgress: (completed, total) {
        if (mounted) {
          setState(() {
            _progressCurrent = completed;
            _progressTotal = total;
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _importResult = result;
        _state = _ImportState.complete;
      });
    }
  }

  void _toggleSelectAll() {
    setState(() {
      final selectableIndices = <int>{};
      for (int i = 0; i < _parsedFeeds.length; i++) {
        if (!(_parsedFeeds[i]['isSubscribed'] as bool)) {
          selectableIndices.add(i);
        }
      }

      if (_selectedIndices.length == selectableIndices.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices.clear();
        _selectedIndices.addAll(selectableIndices);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    final isLocal = profileProvider.currentProfile?.isLocal ?? true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Podcasts', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: switch (_state) {
          _ImportState.input => _buildInputState(isLocal),
          _ImportState.preview => _buildPreviewState(isLocal),
          _ImportState.importing => _buildImportingState(),
          _ImportState.complete => _buildCompleteState(),
        },
      ),
    );
  }

  Widget _buildInputState(bool isLocal) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Context-aware header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1E27),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.deepPurple.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.file_download, color: Colors.deepPurpleAccent, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isLocal
                            ? 'Import your podcasts from another player'
                            : 'Import podcasts from another player',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  isLocal
                      ? 'Select an OPML file exported from Apple Podcasts, Pocket Casts, Overcast, AntennaPod, or any other podcast app.'
                      : 'Import podcasts from another player that aren\'t already on your gPodder server. Feeds already in your library will be skipped.',
                  style: const TextStyle(color: Colors.white60, fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // File picker button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose OPML File'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _pickFile,
            ),
          ),
          const SizedBox(height: 24),

          // Divider with "or"
          Row(
            children: [
              Expanded(child: Divider(color: Colors.white24)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('or enter file path', style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
              Expanded(child: Divider(color: Colors.white24)),
            ],
          ),
          const SizedBox(height: 24),

          // URL/path input
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '/path/to/subscriptions.opml',
              hintStyle: const TextStyle(color: Colors.white30),
              filled: true,
              fillColor: const Color(0xFF1F1E27),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.deepPurple.withOpacity(0.3)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.deepPurple.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.deepPurpleAccent),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.deepPurpleAccent),
                onPressed: _loadFromUrl,
              ),
            ),
            onSubmitted: (_) => _loadFromUrl(),
          ),
          const SizedBox(height: 16),

          // Error
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Help text
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('How to export from other apps:', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 13)),
                SizedBox(height: 8),
                Text('• Apple Podcasts: Not natively supported, use a third-party tool', style: TextStyle(color: Colors.white38, fontSize: 12)),
                Text('• Pocket Casts: Settings → Export OPML', style: TextStyle(color: Colors.white38, fontSize: 12)),
                Text('• Overcast: Account → Export OPML', style: TextStyle(color: Colors.white38, fontSize: 12)),
                Text('• AntennaPod: Settings → Storage → Export', style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewState(bool isLocal) {
    final newCount = _parsedFeeds.where((f) => !(f['isSubscribed'] as bool)).length;
    final existingCount = _parsedFeeds.length - newCount;
    final allSelectable = _parsedFeeds.where((f) => !(f['isSubscribed'] as bool)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1E27),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Found ${_parsedFeeds.length} podcasts ($newCount new, $existingCount already in library)',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _toggleSelectAll,
                child: Text(
                  _selectedIndices.length == allSelectable ? 'Deselect All' : 'Select All',
                  style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 13),
                ),
              ),
            ],
          ),
        ),

        // Sync account info banner
        if (!isLocal) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: Row(
              children: const [
                Icon(Icons.sync, color: Colors.blueAccent, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Imported podcasts will also be synced to your gPodder server.',
                    style: TextStyle(color: Colors.blueAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 8),

        // Feed list
        Expanded(
          child: ListView.builder(
            itemCount: _parsedFeeds.length,
            itemBuilder: (context, index) {
              final feed = _parsedFeeds[index]['feed'] as OpmlFeed;
              final isSubscribed = _parsedFeeds[index]['isSubscribed'] as bool;
              final isSelected = _selectedIndices.contains(index);

              return ListTile(
                leading: Checkbox(
                  value: isSubscribed ? false : isSelected,
                  onChanged: isSubscribed
                      ? null
                      : (value) {
                          setState(() {
                            if (value == true) {
                              _selectedIndices.add(index);
                            } else {
                              _selectedIndices.remove(index);
                            }
                          });
                        },
                  activeColor: Colors.deepPurpleAccent,
                  checkColor: Colors.white,
                ),
                title: Text(
                  feed.title,
                  style: TextStyle(
                    color: isSubscribed ? Colors.white30 : Colors.white,
                    fontSize: 14,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feed.xmlUrl,
                      style: TextStyle(
                        color: isSubscribed ? Colors.white12 : Colors.white38,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isSubscribed)
                      const Text(
                        'Already in library',
                        style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 11),
                      ),
                    if (feed.group != null)
                      Text(
                        'Group: ${feed.group}',
                        style: TextStyle(
                          color: isSubscribed ? Colors.white12 : Colors.white24,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
                dense: true,
                onTap: isSubscribed
                    ? null
                    : () {
                        setState(() {
                          if (_selectedIndices.contains(index)) {
                            _selectedIndices.remove(index);
                          } else {
                            _selectedIndices.add(index);
                          }
                        });
                      },
              );
            },
          ),
        ),

        // Action buttons
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _state = _ImportState.input;
                      _parsedFeeds.clear();
                      _selectedIndices.clear();
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white60,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _selectedIndices.isNotEmpty ? _startImport : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurpleAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.deepPurple.withOpacity(0.3),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('Import ${_selectedIndices.length} Podcast${_selectedIndices.length == 1 ? '' : 's'}'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImportingState() {
    final progress = _progressTotal > 0 ? _progressCurrent / _progressTotal : 0.0;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Colors.deepPurpleAccent),
          const SizedBox(height: 24),
          Text(
            'Subscribing to podcast $_progressCurrent of $_progressTotal...',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.deepPurpleAccent),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleteState() {
    final result = _importResult!;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            result.failureCount == 0 ? Icons.check_circle : Icons.info_outline,
            color: result.failureCount == 0 ? Colors.greenAccent : Colors.orangeAccent,
            size: 64,
          ),
          const SizedBox(height: 24),
          const Text(
            'Import Complete',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (result.successCount > 0)
            Text(
              '✓ Added ${result.successCount} podcast${result.successCount == 1 ? '' : 's'}',
              style: const TextStyle(color: Colors.greenAccent, fontSize: 15),
            ),
          if (result.skippedCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '○ ${result.skippedCount} already in library (skipped)',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
          if (result.failureCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '✗ ${result.failureCount} failed',
              style: const TextStyle(color: Colors.redAccent, fontSize: 14),
            ),
            const SizedBox(height: 8),
            ...result.failedFeeds.take(5).map((name) => Text(
              '  • $name',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            )),
            if (result.failedFeeds.length > 5)
              Text(
                '  ...and ${result.failedFeeds.length - 5} more',
                style: const TextStyle(color: Colors.white24, fontSize: 12),
              ),
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurpleAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Go to Library'),
          ),
        ],
      ),
    );
  }
}
