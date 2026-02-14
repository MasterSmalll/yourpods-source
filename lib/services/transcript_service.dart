import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../models/transcript.dart';
import 'log_service.dart';

class TranscriptService {
  static final TranscriptService _instance = TranscriptService._internal();

  factory TranscriptService() {
    return _instance;
  }

  TranscriptService._internal();

  /// Fetches and parses a transcript from a URL.
  /// Supports SRT, VTT, and JSON (Podcasting 2.0) formats.
  /// [cacheDurationHours] defaults to 24 if not provided.
  Future<Transcript?> fetchTranscript(String url, {String? type, int cacheDurationHours = 24}) async {
    try {
      final cacheFile = await _getCacheFile(url);
      
      // 1. Check Cache
      if (await cacheFile.exists()) {
          final lastModified = await cacheFile.lastModified();
          final age = DateTime.now().difference(lastModified);
          if (age.inHours < cacheDurationHours) {
              final content = await cacheFile.readAsString();
              if (content.isNotEmpty) {
                  // We need to store the type or guess it again. 
                  // For simplicity, we'll re-guess or store a metadata file later. 
                  // For now, re-guessing is fast enough.
                  return _parseContent(content, url, type);
              }
          }
      }

      // 2. Fetch from Network
      final response = await http.get(Uri.parse(url));

      if (response.statusCode != 200) {
        Log.e('TranscriptService','Failed to fetch transcript: ${response.statusCode}');
        return null;
      }

      final content = utf8.decode(response.bodyBytes);
      
      // 3. Save to Cache
      await cacheFile.writeAsString(content);

      return _parseContent(content, url, type);
      
    } catch (e) {
      Log.e('TranscriptService', 'Error fetching/parsing transcript: $e');
      return null;
    }
  }

  Future<File> _getCacheFile(String url) async {
      final directory = await getTemporaryDirectory();
      // Use MD5 hash of URL for filename
      final hash = md5.convert(utf8.encode(url)).toString();
      return File('${directory.path}/transcript_$hash.cache');
  }

  Transcript _parseContent(String content, String url, String? type) {
      // Attempt to detect type if not provided or if application/octest-stream
      String detectedType = type ?? '';
      if (detectedType.isEmpty || detectedType == 'application/octet-stream') {
        if (url.endsWith('.json') || content.trim().startsWith('{') || content.trim().startsWith('[')) {
          detectedType = 'application/json';
        } else if (url.endsWith('.srt') || content.contains('-->') && !content.contains('WEBVTT')) {
          detectedType = 'application/x-subrip';
        } else if (url.endsWith('.vtt') || content.contains('WEBVTT')) {
          detectedType = 'text/vtt';
        }
      }

      switch (detectedType) {
        case 'application/json':
          return _parseJSON(content);
        case 'application/x-subrip':
        case 'application/srt':
          return _parseSRT(content);
        case 'text/vtt':
          return _parseVTT(content);
        default:
          // Try to guess based on content if type is still unknown or unsupported header
          if (content.contains('WEBVTT')) return _parseVTT(content);
          if (content.trim().startsWith('{') || content.trim().startsWith('[')) return _parseJSON(content);
          return _parseSRT(content); // Fallback to SRT parser as it's often the simplest
      }
  }

  Transcript _parseJSON(String content) {
    // Podcasting 2.0 JSON format usually has a 'c' version or 'segments'
    // Reference: https://github.com/Podcastindex-org/podcast-namespace/blob/main/transcripts/transcripts.md
    try {
      final json = jsonDecode(content);
      List<TranscriptItem> items = [];

      if (json is Map && json.containsKey('segments')) {
        // Podcasting 2.0 format
        for (var segment in json['segments']) {
           items.add(TranscriptItem(
             text: segment['body'] ?? '',
             start: Duration(milliseconds: ((segment['startTime'] as num) * 1000).toInt()),
             duration: Duration(milliseconds: ((segment['endTime'] as num) * 1000).toInt()) - Duration(milliseconds: ((segment['startTime'] as num) * 1000).toInt()),
           ));
        }
      } 
      
      return Transcript(items: items, type: 'application/json');
    } catch (e) {
      Log.e('TranscriptService', 'Error parsing JSON transcript: $e');
      return Transcript(items: []);
    }
  }

  Transcript _parseSRT(String content) {
    List<TranscriptItem> items = [];
    final lines = LineSplitter.split(content).toList();
    
    for (int i = 0; i < lines.length; i++) {
        // Skip index lines (1, 2, 3...)
        if (int.tryParse(lines[i]) != null) {
            continue;
        }

        if (lines[i].contains('-->')) {
            var timeParts = lines[i].split('-->');
            var start = _parseSubtitleTimestamp(timeParts[0].trim());
            var end = _parseSubtitleTimestamp(timeParts[1].trim());
            
            String text = '';
            i++;
            while (i < lines.length && lines[i].trim().isNotEmpty) {
                text += (text.isEmpty ? '' : '\n') + lines[i];
                i++;
            }
            
            items.add(TranscriptItem(
                text: text,
                start: start,
                duration: end - start,
            ));
        }
    }

    return Transcript(items: items, type: 'application/srt');
  }

  Transcript _parseVTT(String content) {
     List<TranscriptItem> items = [];
    final lines = LineSplitter.split(content).toList();
    
    for (int i = 0; i < lines.length; i++) {
        if (lines[i] == 'WEBVTT' || lines[i].trim().isEmpty) continue;

        if (lines[i].contains('-->')) {
            var timeParts = lines[i].split('-->');
            var start = _parseSubtitleTimestamp(timeParts[0].trim());
            var end = _parseSubtitleTimestamp(timeParts[1].trim()); // VTT might have settings after end time
             
            // Handle VTT settings like "align:start"
            String endTimeString = timeParts[1].trim().split(' ')[0];
            end = _parseSubtitleTimestamp(endTimeString);

            String text = '';
            i++;
            while (i < lines.length && lines[i].trim().isNotEmpty) {
                 text += (text.isEmpty ? '' : '\n') + lines[i];
                 i++;
            }
            
            items.add(TranscriptItem(
                text: text,
                start: start,
                duration: end - start,
            ));
        }
    }
    return Transcript(items: items, type: 'text/vtt');
  }

  Duration _parseSubtitleTimestamp(String timestamp) {
    // SRT: 00:00:20,000
    // VTT: 00:00:20.000 or 00:20.000
    timestamp = timestamp.replaceAll(',', '.'); 
    final parts = timestamp.split(':');
    
    int hours = 0;
    int minutes = 0;
    double seconds = 0;

    if (parts.length == 3) {
      hours = int.parse(parts[0]);
      minutes = int.parse(parts[1]);
      seconds = double.parse(parts[2]);
    } else if (parts.length == 2) {
      minutes = int.parse(parts[0]);
      seconds = double.parse(parts[1]);
    }

    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).toInt(),
    );
  }
}
