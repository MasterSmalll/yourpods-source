class TranscriptItem {
  final String text;
  final Duration start;
  final Duration duration;

  TranscriptItem({
    required this.text,
    required this.start,
    required this.duration,
  });

  Duration get end => start + duration;

  @override
  String toString() {
    return 'TranscriptItem(start: $start, duration: $duration, text: "$text")';
  }
}

class Transcript {
  final List<TranscriptItem> items;
  final String? language;
  final String? type; // 'application/json', 'text/vtt', 'application/srt'

  Transcript({
    required this.items,
    this.language,
    this.type,
  });
}
