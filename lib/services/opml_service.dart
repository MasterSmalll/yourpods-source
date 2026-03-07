import 'package:xml/xml.dart' as xml;
import '../models/podcast.dart';

/// Represents a single feed entry parsed from an OPML file.
class OpmlFeed {
  final String xmlUrl;
  final String title;
  final String? htmlUrl;
  final String? group;

  OpmlFeed({
    required this.xmlUrl,
    required this.title,
    this.htmlUrl,
    this.group,
  });
}

/// Result summary from an OPML import operation.
class ImportResult {
  final int successCount;
  final int failureCount;
  final int skippedCount;
  final List<String> failedFeeds;

  ImportResult({
    required this.successCount,
    required this.failureCount,
    required this.skippedCount,
    required this.failedFeeds,
  });
}

/// Service for parsing and generating OPML (Outline Processor Markup Language)
/// files used for podcast subscription portability.
class OpmlService {
  /// Parse an OPML XML string into a list of [OpmlFeed] entries.
  ///
  /// Handles:
  /// - Standard `<outline type="rss" xmlUrl="..." />` elements
  /// - Nested folder/group containers (`<outline text="Group">`)
  /// - Entries without explicit `type` attribute (falls back to checking for xmlUrl)
  /// - Tolerates minor malformations common in exports from various apps
  List<OpmlFeed> parseOpml(String xmlContent) {
    final feeds = <OpmlFeed>[];

    try {
      final document = xml.XmlDocument.parse(xmlContent);
      final body = document.findAllElements('body').firstOrNull;
      if (body == null) return feeds;

      _parseOutlines(body, feeds, null);
    } catch (e) {
      // If XML parsing fails entirely, return empty list
      // Caller should handle the empty result
    }

    return feeds;
  }

  /// Recursively parse `<outline>` elements, tracking group context.
  void _parseOutlines(
    xml.XmlElement parent,
    List<OpmlFeed> feeds,
    String? currentGroup,
  ) {
    for (final element in parent.childElements) {
      if (element.name.local != 'outline') continue;

      final xmlUrl = element.getAttribute('xmlUrl');

      if (xmlUrl != null && xmlUrl.isNotEmpty) {
        // This is a feed entry
        final title = element.getAttribute('title') ??
            element.getAttribute('text') ??
            xmlUrl;

        feeds.add(OpmlFeed(
          xmlUrl: xmlUrl,
          title: title,
          htmlUrl: element.getAttribute('htmlUrl'),
          group: currentGroup,
        ));
      } else if (element.childElements.isNotEmpty) {
        // This is a folder/group container — recurse
        final groupName = element.getAttribute('text') ??
            element.getAttribute('title');
        _parseOutlines(element, feeds, groupName ?? currentGroup);
      }
    }
  }

  /// Generate a valid OPML 2.0 XML string from a list of [Podcast] subscriptions.
  ///
  /// Produces standard OPML that can be imported by any podcast app.
  String generateOpml(List<Podcast> subscriptions) {
    final builder = xml.XmlBuilder();

    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('opml', attributes: {'version': '2.0'}, nest: () {
      builder.element('head', nest: () {
        builder.element('title', nest: 'YourPods Subscriptions');
        builder.element('dateCreated', nest: DateTime.now().toUtc().toIso8601String());
      });

      builder.element('body', nest: () {
        for (final podcast in subscriptions) {
          builder.element('outline', attributes: {
            'type': 'rss',
            'text': podcast.title,
            'title': podcast.title,
            'xmlUrl': podcast.url,
            if (podcast.website != null) 'htmlUrl': podcast.website!,
            if (podcast.description != null) 'description': podcast.description!,
          });
        }
      });
    });

    return builder.buildDocument().toXmlString(pretty: true);
  }
}
