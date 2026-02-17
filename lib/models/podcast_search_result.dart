/// A search result from a podcast search provider.
class PodcastSearchResult {
  final String title;
  final String feedUrl;
  final String? artworkUrl;
  final String? author;
  final String? description;

  PodcastSearchResult({
    required this.title,
    required this.feedUrl,
    this.artworkUrl,
    this.author,
    this.description,
  });
}
