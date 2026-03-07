import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/podcast.dart';
import '../services/log_service.dart';
import '../utils/user_agent.dart';

class GPodderApi {
  final String baseUrl;
  final String username;
  final String password;

  final http.Client client;

  GPodderApi({
    required this.baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  }) : client = client ?? http.Client();

  String get _authHeader => 'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Future<SubscriptionDelta> getSubscriptionChanges(String deviceId, int since) async {
    var sanitizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    
    if (!sanitizedBaseUrl.startsWith('http://') && !sanitizedBaseUrl.startsWith('https://')) {
      sanitizedBaseUrl = 'https://$sanitizedBaseUrl';
    }

    final url = '$sanitizedBaseUrl/index.php/apps/gpoddersync/subscriptions?since=$since';
    
    Log.d('GPodderApi', 'Requesting subscriptions from: $url');

    final response = await client.get(
      Uri.parse(url),
      headers: withUserAgent({
        'Authorization': _authHeader,
      }),
    );

    if (response.statusCode == 200) {
      final dynamic data = json.decode(response.body);
      
      if (data is Map<String, dynamic>) {
          // Standard delta response
          return SubscriptionDelta.fromJson(data);
      } else if (data is List) {
          // Full sync list response (usually when since=0)
          // tailored as "add everything"
          final List<String> urls = data.map((item) {
              if (item is Map) return item['url'] as String;
              if (item is String) return item;
              return item.toString();
          }).toList();
          
          return SubscriptionDelta(
              add: urls,
              remove: [], // Full sync implies we might want to reconcile, but here we treat 'add' as "these are the subs".
                          // Ideally, handling full sync means we should diff or reset. 
                          // For simplicity in this wrapper, we mark all as 'add'. 
                          // The provider should handle "Full List" logic if since=0.
              timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, // Fallback if server doesn't provide
          );
      }
      throw Exception('Unknown JSON format: ${data.runtimeType}');
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      throw GPodderAuthException('Unauthorized: Unknown username or password', statusCode: response.statusCode);
    } else if (response.statusCode >= 500) {
      throw GPodderServerException('Server error', statusCode: response.statusCode);
    } else {
      throw GPodderException('Failed to load subscriptions', statusCode: response.statusCode);
    }
  }

  // Deprecated direct list fetch in favor of Delta, but keeping for compatibility if needed
  Future<List<Podcast>> getSubscriptions(String deviceId) async {
      final delta = await getSubscriptionChanges(deviceId, 0);
      return delta.add.map((url) => Podcast(url: url, title: url)).toList();
  }
  Future<void> updateSubscriptions(String deviceId, {List<String> add = const [], List<String> remove = const []}) async {
    var sanitizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    
    if (!sanitizedBaseUrl.startsWith('http://') && !sanitizedBaseUrl.startsWith('https://')) {
      sanitizedBaseUrl = 'https://$sanitizedBaseUrl';
    }

    final url = '$sanitizedBaseUrl/index.php/apps/gpoddersync/subscription_change/create?deviceid=$deviceId';
    
    Log.d('GPodderApi', 'Updating subscriptions at: $url');

    final response = await client.post(
      Uri.parse(url),
      headers: withUserAgent({
        'Authorization': _authHeader,
        'Content-Type': 'application/json',
      }),
      body: json.encode({
        'add': add,
        'remove': remove,
      }),
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GPodderAuthException('Unauthorized: Unknown username or password', statusCode: response.statusCode);
    } else if (response.statusCode >= 500) {
      throw GPodderServerException('Server error', statusCode: response.statusCode);
    } else if (response.statusCode != 200) {
      throw GPodderException('Failed to update subscriptions', statusCode: response.statusCode);
    }
  }

  Future<void> uploadEpisodeActions(List<EpisodeAction> actions) async {
    if (actions.isEmpty) return;
    
    var sanitizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    
    if (!sanitizedBaseUrl.startsWith('http://') && !sanitizedBaseUrl.startsWith('https://')) {
      sanitizedBaseUrl = 'https://$sanitizedBaseUrl';
    }

    final url = '$sanitizedBaseUrl/index.php/apps/gpoddersync/episode_action/create';
    
    Log.d('GPodderApi', 'Uploading ${actions.length} episode actions to: $url');

    final response = await client.post(
      Uri.parse(url),
      headers: withUserAgent({
        'Authorization': _authHeader,
        'Content-Type': 'application/json',
      }),
      body: json.encode(actions.map((a) => a.toJson()).toList()),
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GPodderAuthException('Unauthorized: Unknown username or password', statusCode: response.statusCode);
    } else if (response.statusCode >= 500) {
      throw GPodderServerException('Upload failed: Server error', statusCode: response.statusCode);
    } else if (response.statusCode != 200) {
      Log.e('GPodderApi', 'Upload failed. Body: ${response.body}');
      throw GPodderException('Failed to upload episode actions', statusCode: response.statusCode);
    }
  }

  Future<List<EpisodeAction>> getEpisodeActions(String deviceId, {int since = 0}) async {
    var sanitizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    
    if (!sanitizedBaseUrl.startsWith('http://') && !sanitizedBaseUrl.startsWith('https://')) {
      sanitizedBaseUrl = 'https://$sanitizedBaseUrl';
    }

    // Using the since parameter to get changes. 
    // Standard gPodder API often uses 'device' or 'deviceid'. Nextcloud gPodder uses 'device'.
    final url = '$sanitizedBaseUrl/index.php/apps/gpoddersync/episode_action?since=$since&device=$deviceId';
    
    Log.d('GPodderApi', 'Fetching episode actions from: $url');

    final response = await client.get(
      Uri.parse(url),
      headers: withUserAgent({
        'Authorization': _authHeader,
      }),
    );

    if (response.statusCode == 200) {
      final dynamic data = json.decode(response.body);
      
      // The Nextcloud app usually returns a list of actions directly, 
      // or wrapped in an object. Let's handle both standard cases if possible,
      // but based on API docs it's commonly a list.
      List<dynamic> list = [];
      if (data is List) {
        list = data;
      } else if (data is Map && data.containsKey('actions')) {
         list = data['actions'];
      } else if (data is Map && data.containsKey('data')) { // Nextcloud wrapper generic
         list = data['data'];
      }

      return list.map((json) => EpisodeAction.fromJson(json)).toList();
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      throw GPodderAuthException('Unauthorized: Unknown username or password', statusCode: response.statusCode);
    } else if (response.statusCode >= 500) {
      throw GPodderServerException('Server error', statusCode: response.statusCode);
    } else {
      throw GPodderException('Failed to get episode actions', statusCode: response.statusCode);
    }
  }
}

class EpisodeAction {
  final String podcast;
  final String episode;
  final String? guid;
  final String action;
  final int timestamp;
  final int? position;
  final int? started;
  final int? total;
  final String? device;

  EpisodeAction({
    required this.podcast,
    required this.episode,
    this.guid,
    required this.action,
    required this.timestamp,
    this.position,
    this.started,
    this.total,
    this.device,
  });

  Map<String, dynamic> toJson() {
    return {
      'podcast': podcast,
      'episode': episode,
      'guid': guid,
      'action': action,
      'timestamp': DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true).toIso8601String(),
      if (position != null) 'position': position,
      if (started != null) 'started': started,
      if (total != null) 'total': total,
      if (device != null) 'device': device,
    };
  }

  factory EpisodeAction.fromJson(Map<String, dynamic> json) {
    return EpisodeAction(
      podcast: json['podcast'],
      episode: json['episode'],
      guid: json['guid'],
      action: json['action'],
      timestamp: json['timestamp'] is int 
          ? json['timestamp'] 
          : DateTime.parse(json['timestamp']).millisecondsSinceEpoch ~/ 1000,
      position: json['position'],
      started: json['started'],
      total: json['total'],
      device: json['device'],
    );
  }
}

class SubscriptionDelta {
  final List<String> add;
  final List<String> remove;
  final int timestamp;

  SubscriptionDelta({
    required this.add,
    required this.remove,
    required this.timestamp,
  });

  factory SubscriptionDelta.fromJson(Map<String, dynamic> json) {
    return SubscriptionDelta(
      add: List<String>.from(json['add'] ?? []),
      remove: List<String>.from(json['remove'] ?? []),
      timestamp: json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }
}

class GPodderException implements Exception {
  final String message;
  final int? statusCode;
  
  GPodderException(this.message, {this.statusCode});
  
  @override
  String toString() => 'GPodderException: $message ${statusCode != null ? "($statusCode)" : ""}';
}

class GPodderAuthException extends GPodderException {
  GPodderAuthException(super.message, {super.statusCode});
}

class GPodderServerException extends GPodderException {
  GPodderServerException(super.message, {super.statusCode});
}
