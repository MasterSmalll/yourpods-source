import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:id3tag/id3tag.dart' as id3;
import '../models/podcast.dart';
import '../services/log_service.dart';

class ID3ChapterService {
  /// Extracts chapters from an MP3 file URL by streaming the first portion of the file (ID3 tag).
  /// Returns an empty list if no chapters found or error occurs.
  Future<List<Chapter>> extractID3Chapters(String audioUrl) async {
    try {
      Log.d('ID3ChapterService', 'Attempting to fetch ID3 tags from $audioUrl');
      
      // 1. Fetch the first 256KB of the file (usually enough for ID3 tags including chapters)
      // Increasing this might be needed for very large chapter art, but 256KB is a safe start for text frames.
      // ID3v2 tags are at the start of the file.
      final response = await http.get(
        Uri.parse(audioUrl),
        headers: {'Range': 'bytes=0-262144'}, // 256KB (usually enough for text frames)
      );

      if (response.statusCode != 200 && response.statusCode != 206) {
        Log.w('ID3ChapterService', 'Failed to fetch partial content (status ${response.statusCode})');
        return [];
      }
      
      final bytes = response.bodyBytes;
      Log.d('ID3ChapterService', 'Fetched ${bytes.length} bytes');

      // 2. Parse ID3 tags using id3tag package
      // The library currently only supports File input, so we write to a temp file.
      final tempDir = Directory.systemTemp.createTempSync('yourpods_id3_');
      final tempFile = File('${tempDir.path}/temp_header.mp3');
      await tempFile.writeAsBytes(bytes);
      
      try {
          final parser = id3.ID3TagReader(tempFile);
          final tag = await parser.readTag();

          if (tag == null) {
              Log.w('ID3ChapterService', 'No ID3 tag found in header');
              return [];
          }
           
          // 3. Extract chapters using id3tag's high-level API
          final id3Chapters = tag.chapters;
          
          final chapters = id3Chapters.map((id3Chap) {
              // Map id3tag.Chapter to our internal Chapter model
              return Chapter(
                  startTime: id3Chap.startTimeMilliseconds / 1000.0,
                  title: id3Chap.title, // Use title from id3tag Chapter
              );
          }).toList();

          Log.d('ID3ChapterService', 'Found ${chapters.length} chapters');
          return chapters;
          
      } finally {
          // Cleanup
          if (tempFile.existsSync()) {
              tempFile.deleteSync();
          }
          if (tempDir.existsSync()) {
             tempDir.deleteSync();
          }
      }
    } catch (e) {
      Log.e('ID3ChapterService', 'Error extracting chapters: $e');
      return [];
    }
  }
}
