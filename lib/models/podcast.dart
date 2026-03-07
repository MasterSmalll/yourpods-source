class Chapter {
  final double startTime; // seconds
  final String title;
  final String? img; // optional chapter image URL
  final String? url; // optional link

  Chapter({
    required this.startTime,
    required this.title,
    this.img,
    this.url,
  });

  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      startTime: (json['startTime'] as num).toDouble(),
      title: json['title'] ?? '',
      img: json['img'] as String?,
      url: json['url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startTime': startTime,
      'title': title,
      if (img != null) 'img': img,
      if (url != null) 'url': url,
    };
  }
}

class Podcast {
  final String url;
  final String title;
  final String? description;
  final String? logoUrl;
  final String? website;
  final String? author;
  final bool requiresAuth;

  Podcast({
    required this.url,
    required this.title,
    this.description,
    this.logoUrl,
    this.website,
    this.author,
    this.requiresAuth = false,
  });

  factory Podcast.fromJson(Map<String, dynamic> json) {
    return Podcast(
      url: json['url'] ?? '',
      title: json['title'] ?? 'Unknown Podcast',
      description: json['description'],
      logoUrl: json['logo_url'],
      website: json['website'],
      author: json['author'],
      requiresAuth: json['requires_auth'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'title': title,
      'description': description,
      'logo_url': logoUrl,
      'website': website,
      'author': author,
      'requires_auth': requiresAuth,
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
  final String? chaptersUrl;
  final String? transcriptUrl;
  List<Chapter>? chapters;

  Episode({
    required this.guid,
    required this.title,
    this.description,
    this.audioUrl,
    this.pubDate,
    this.imageUrl,
    this.duration,
    this.link,
    this.chaptersUrl,
    this.transcriptUrl,
    this.chapters,
  });
}
