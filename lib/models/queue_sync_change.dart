/// Represents a proposed change to the local queue based on server episode actions.
enum QueueSyncChangeType { add, remove, update }

/// Strategy for handling queue sync changes.
enum QueueSyncStrategy {
  serverWins,
  deviceWins,
  ask,
}

class QueueSyncChange {
  final QueueSyncChangeType type;
  final String episodeGuid;
  final String podcastUrl;
  String? episodeTitle;
  String? podcastTitle;
  final String? imageUrl;
  final String? audioUrl;
  final int? serverPosition;
  final int? localPosition;
  final int? totalDuration;
  final int serverTimestamp;

  /// User decision — defaults to true (accept).
  bool accepted;

  QueueSyncChange({
    required this.type,
    required this.episodeGuid,
    required this.podcastUrl,
    this.episodeTitle,
    this.podcastTitle,
    this.imageUrl,
    this.audioUrl,
    this.serverPosition,
    this.localPosition,
    this.totalDuration,
    required this.serverTimestamp,
    this.accepted = true,
  });

  /// Human-readable summary for the dialog.
  String get summary {
    switch (type) {
      case QueueSyncChangeType.add:
        if (totalDuration != null && totalDuration! > 0 && serverPosition != null) {
          final pct = (serverPosition! / totalDuration! * 100).clamp(0, 100).toInt();
          return 'Add to queue ($pct% listened)';
        }
        return 'Add to queue';
      case QueueSyncChangeType.remove:
        return 'Completed on another device';
      case QueueSyncChangeType.update:
        if (totalDuration != null && totalDuration! > 0 && serverPosition != null) {
          final pct = (serverPosition! / totalDuration! * 100).clamp(0, 100).toInt();
          return 'Update position to $pct% listened';
        }
        return 'Update position';
    }
  }
}
