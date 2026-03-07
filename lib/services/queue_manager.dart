import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';

/// Owns the playback queue: CRUD operations, persistence, and deterministic
/// "what plays next" queries.  No audio concerns — fully testable in isolation.
class QueueManager {
  final BehaviorSubject<List<MediaItem>> queue = BehaviorSubject.seeded([]);
  String? _profileId;

  // Storage key helpers scoped by profile
  String get _queueKey =>
      _profileId != null ? 'audio_queue_$_profileId' : 'audio_queue';
  String get _mediaItemKey =>
      _profileId != null ? 'last_media_item_$_profileId' : 'last_media_item';
  String get _positionKey =>
      _profileId != null ? 'last_position_$_profileId' : 'last_position';

  /// Set active profile ID and reload queue from profile-scoped storage.
  Future<void> setProfileId(String profileId) async {
    if (_profileId == profileId) return;
    _profileId = profileId;
    await _migrateGlobalData(profileId);
    await loadQueue();
  }

  String? get profileId => _profileId;

  // --- Queue Query ---

  /// Returns the next item after [currentId].
  /// If [currentId] is not in the queue (direct-play scenario),
  /// returns the first queue item (the "up next" item).
  /// Returns null if the queue is empty or [currentId] is the last item.
  MediaItem? nextItem(String? currentId) {
    final q = queue.value;
    if (q.isEmpty) return null;
    if (currentId == null) return q.first;

    final idx = q.indexWhere((item) => item.id == currentId);
    if (idx < 0) return q.first; // not in queue → first is "up next"
    if (idx + 1 < q.length) return q[idx + 1];
    return null; // last item
  }

  /// Atomically remove the completed item and return the next item.
  /// Returns (nextItem, updatedQueue).  If the completed item is not in
  /// the queue, returns the first queue item and removes it instead.
  AdvanceResult advanceFrom(String? completedId) {
    final q = List<MediaItem>.from(queue.value);
    if (q.isEmpty) return AdvanceResult(next: null, updatedQueue: q);

    if (completedId == null) {
      return AdvanceResult(next: null, updatedQueue: q);
    }

    final idx = q.indexWhere((item) => item.id == completedId);

    if (idx >= 0) {
      // Item IS in queue — remove it and return next at same index
      q.removeAt(idx);
      queue.add(q);
      final next = idx < q.length ? q[idx] : null;
      return AdvanceResult(next: next, updatedQueue: q);
    } else {
      // Item NOT in queue (played directly) — first queue item is "up next"
      if (q.isNotEmpty) {
        final next = q.first;
        q.removeAt(0);
        queue.add(q);
        return AdvanceResult(next: next, updatedQueue: q);
      }
      return AdvanceResult(next: null, updatedQueue: q);
    }
  }

  // --- Queue Mutation ---

  Future<void> addItem(MediaItem item) async {
    final q = List<MediaItem>.from(queue.value);
    final existingIdx = q.indexWhere((i) => i.id == item.id);
    if (existingIdx >= 0) {
      // Merge extras (prefer new values) and replace
      final existing = q[existingIdx];
      final mergedExtras = <String, dynamic>{
        ...?existing.extras,
        ...?item.extras
      };
      q[existingIdx] = item.copyWith(extras: mergedExtras);
      Log.d('QueueManager',
          'addItem: updated existing item ${item.id} instead of duplicating');
    } else {
      q.add(item);
    }
    queue.add(q);
  }

  Future<void> addItems(List<MediaItem> items) async {
    final q = List<MediaItem>.from(queue.value);
    for (final item in items) {
      final existingIdx = q.indexWhere((i) => i.id == item.id);
      if (existingIdx >= 0) {
        final existing = q[existingIdx];
        final mergedExtras = <String, dynamic>{
          ...?existing.extras,
          ...?item.extras
        };
        q[existingIdx] = item.copyWith(extras: mergedExtras);
      } else {
        q.add(item);
      }
    }
    queue.add(q);
  }

  Future<void> removeItem(String itemId) async {
    final q = List<MediaItem>.from(queue.value)
      ..removeWhere((i) => i.id == itemId);
    queue.add(q);
  }

  Future<void> updateQueue(List<MediaItem> newQueue) async {
    queue.add(newQueue);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex -= 1;
    final q = List<MediaItem>.from(queue.value);
    final item = q.removeAt(oldIndex);
    q.insert(newIndex, item);
    queue.add(q);
  }

  /// Insert items immediately after [currentId], or at the top if
  /// [currentId] is not in the queue.
  Future<void> insertAfterCurrent(
      List<MediaItem> items, String? currentId) async {
    if (items.isEmpty) return;

    final q = List<MediaItem>.from(queue.value);
    int insertIndex = 0;

    if (currentId != null) {
      final idx = q.indexWhere((i) => i.id == currentId);
      if (idx >= 0) insertIndex = idx + 1;
    }

    // Remove existing instances so they move to new position
    final incomingIds = items.map((i) => i.id).toSet();
    q.removeWhere((i) => incomingIds.contains(i.id));

    // Recalculate insert index after removals
    if (currentId != null) {
      final idx = q.indexWhere((i) => i.id == currentId);
      if (idx >= 0) {
        insertIndex = idx + 1;
      } else {
        insertIndex = 0;
      }
    } else {
      insertIndex = 0;
    }

    if (insertIndex > q.length) insertIndex = q.length;
    q.insertAll(insertIndex, items);
    queue.add(q);
  }

  /// Insert a single item immediately after current, moving it if already present.
  Future<void> playNext(MediaItem item, String? currentId) async {
    final q = List<MediaItem>.from(queue.value);

    int insertIndex = 0;
    if (currentId != null) {
      final idx = q.indexWhere((i) => i.id == currentId);
      if (idx >= 0) insertIndex = idx + 1;
    }

    // If item already in queue, move it
    final existingIndex = q.indexWhere((i) => i.id == item.id);
    if (existingIndex != -1) {
      q.removeAt(existingIndex);
      if (existingIndex < insertIndex) insertIndex--;
    }

    if (insertIndex > q.length) insertIndex = q.length;
    q.insert(insertIndex, item);
    queue.add(q);
  }

  /// Remove duplicate episodes, keeping the first occurrence.
  Future<void> deduplicate() async {
    final seen = <String>{};
    final q = queue.value;
    final deduped = <MediaItem>[];
    for (final item in q) {
      if (seen.add(item.id)) deduped.add(item);
    }
    if (deduped.length < q.length) {
      Log.i('QueueManager',
          'Dedup: removed ${q.length - deduped.length} duplicate(s)');
      queue.add(deduped);
    }
  }

  // --- Persistence ---

  Future<void> saveState(MediaItem? currentItem, Duration position) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Save queue
      final queueJson = queue.value.map(_mediaItemToJson).toList();
      await prefs.setString(_queueKey, json.encode(queueJson));
      Log.d('QueueManager', 'saveState: saved queue with ${queue.value.length} items: ${queue.value.map((i) => i.id).toList()}');

      // Save current item and position
      if (currentItem != null) {
        await prefs.setString(
            _mediaItemKey, json.encode(_mediaItemToJson(currentItem)));
        await prefs.setInt(_positionKey, position.inMilliseconds);
        Log.d('QueueManager', 'saveState: saved mediaItem="${currentItem.title}" id=${currentItem.id} at ${position.inSeconds}s');
      }
    } catch (e) {
      Log.e('QueueManager', 'Error saving state: $e');
    }
  }

  Future<void> saveQueue(List<MediaItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = items.map(_mediaItemToJson).toList();
      await prefs.setString(_queueKey, json.encode(queueJson));
      Log.d(
          'QueueManager', 'Queue saved to storage (${items.length} items)');
    } catch (e) {
      Log.e('QueueManager', 'Error saving queue: $e');
    }
  }

  Future<void> loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueString = prefs.getString(_queueKey);
      if (queueString != null) {
        final List<dynamic> queueJson = json.decode(queueString);
        final loaded = queueJson.map(_mediaItemFromJson).toList();
        queue.add(loaded);
      } else {
        queue.add([]);
      }
    } catch (e) {
      Log.e('QueueManager', 'Error loading queue: $e');
      queue.add([]);
    }
  }

  /// Load last saved media item and position.
  /// Returns null if nothing was saved.
  Future<SavedState?> loadLastState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_mediaItemKey);
      final positionMs = prefs.getInt(_positionKey) ?? 0;

      if (jsonString != null) {
        final jsonMap = json.decode(jsonString) as Map<String, dynamic>;
        final item = _mediaItemFromJson(jsonMap);
        Log.d('QueueManager', 'loadLastState: restored mediaItem="${item.title}" id=${item.id} at ${positionMs ~/ 1000}s, queue=${queue.value.map((i) => i.id).toList()}');
        return SavedState(
            item: item, position: Duration(milliseconds: positionMs));
      }
    } catch (e) {
      Log.e('QueueManager', 'Error loading last state: $e');
    }
    return null;
  }

  /// One-time migration: copy global keys to profile-scoped keys.
  Future<void> _migrateGlobalData(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final scopedQueueKey = 'audio_queue_$profileId';
    if (!prefs.containsKey(scopedQueueKey) &&
        prefs.containsKey('audio_queue')) {
      final globalQueue = prefs.getString('audio_queue');
      if (globalQueue != null) {
        await prefs.setString(scopedQueueKey, globalQueue);
      }
      final globalItem = prefs.getString('last_media_item');
      if (globalItem != null) {
        await prefs.setString('last_media_item_$profileId', globalItem);
      }
      final globalPos = prefs.getInt('last_position');
      if (globalPos != null) {
        await prefs.setInt('last_position_$profileId', globalPos);
      }
      Log.i('QueueManager',
          'Migrated global queue data to profile $profileId');
    }
  }

  // --- JSON helpers ---

  Map<String, dynamic> _mediaItemToJson(MediaItem item) {
    return {
      'id': item.id,
      'title': item.title,
      'album': item.album,
      'artist': item.artist,
      'artUri': item.artUri?.toString(),
      'duration': item.duration?.inMilliseconds,
      'extras': item.extras,
      'playable': item.playable,
    };
  }

  MediaItem _mediaItemFromJson(dynamic json) {
    return MediaItem(
      id: json['id'],
      title: json['title'],
      album: json['album'],
      artist: json['artist'],
      artUri: json['artUri'] != null ? Uri.parse(json['artUri']) : null,
      duration: json['duration'] != null
          ? Duration(milliseconds: json['duration'])
          : null,
      extras: json['extras'] != null
          ? Map<String, dynamic>.from(json['extras'])
          : null,
      playable: json['playable'] ?? true,
    );
  }

  void dispose() {
    queue.close();
  }
}

/// Result of [QueueManager.advanceFrom].
class AdvanceResult {
  final MediaItem? next;
  final List<MediaItem> updatedQueue;
  AdvanceResult({required this.next, required this.updatedQueue});
}

/// Saved playback state from persistence.
class SavedState {
  final MediaItem item;
  final Duration position;
  SavedState({required this.item, required this.position});
}
