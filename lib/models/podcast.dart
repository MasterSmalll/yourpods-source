class Podcast {
  final String url;
  final String title;
  final String? description;
  final String? logoUrl;
  final String? website;

  Podcast({
    required this.url,
    required this.title,
    this.description,
    this.logoUrl,
    this.website,
  });

  factory Podcast.fromJson(Map<String, dynamic> json) {
    return Podcast(
      url: json['url'] ?? '',
      title: json['title'] ?? 'Unknown Podcast',
      description: json['description'],
      logoUrl: json['logo_url'],
      website: json['website'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'title': title,
      'description': description,
      'logo_url': logoUrl,
      'website': website,
    };
  }
}

class Episode {
  final String guid;
  final String title;
  final String? description;
  final String? audioUrl;
  final DateTime? pubDate;
  final String? imageUrl;
  final Duration? duration;
  final String? link;

  Episode({
    required this.guid,
    required this.title,
    this.description,
    this.audioUrl,
    this.pubDate,
    this.imageUrl,
    this.duration,
    this.link,
  });
}
