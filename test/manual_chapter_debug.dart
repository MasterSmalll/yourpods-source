import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:YourPods/services/id3_chapter_service.dart';

void main() async {
  const feedUrl = 'https://3reate.com/feed/podcast/3reate/';
  print('Step 1: Fetching feed to get latest MP3 URL: $feedUrl');
  
  try {
    final response = await http.get(Uri.parse(feedUrl));
    if (response.statusCode != 200) {
        print('Failed to fetch feed: ${response.statusCode}');
        return;
    }
    
    final xml = XmlDocument.parse(response.body);
    // Find first enclosure
    final enclosure = xml.findAllElements('enclosure').firstOrNull;
    final mp3Url = enclosure?.getAttribute('url');
    
    if (mp3Url == null) {
        print('No MP3 URL found in feed');
        return;
    }
    
    print('Found MP3 URL: $mp3Url');
    print('Step 2: Testing ID3 chapter extraction...');
    
    final service = ID3ChapterService();
    final chapters = await service.extractID3Chapters(mp3Url);
    
    if (chapters.isEmpty) {
        print('❌ No chapters found via ID3.');
    } else {
        print('✅ Found ${chapters.length} chapters via ID3:');
        for (final c in chapters) {
            print('- ${c.title} (${c.startTime}s)');
        }
    }
  } catch (e) {
      print('An error occurred: $e');
  }
}
