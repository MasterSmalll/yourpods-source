import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:YourPods/api/gpodder_api.dart';

import 'package:YourPods/models/podcast.dart'; // Correct package import assuming pubspec name

void main() {
  group('GPodderApi Sync', () {
    test('updateSubscriptions sends correct JSON to correct URL', () async {
      final mockClient = MockClient((request) async {
        // Verify URL
        if (request.url.toString() == 'https://example.com/index.php/apps/gpoddersync/subscription_change/create?deviceid=test-device') {
          // Verify Headers
          if (request.headers['Authorization'] == 'Basic dXNlcjpwYXNz') { // user:pass base64
             // Verify Body
             final body = json.decode(request.body);
             if (body['add'][0] == 'http://feed.url' && body['remove'].isEmpty) {
               return http.Response('{"timestamp": 12345}', 200);
             }
          }
        }
        return http.Response('Error', 400);
      });

      final api = GPodderApi(
        baseUrl: 'https://example.com',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      await api.updateSubscriptions('test-device', add: ['http://feed.url']);
    });

    test('uploadEpisodeActions sends correct JSON', () async {
      final mockClient = MockClient((request) async {
        if (request.url.toString() == 'https://example.com/index.php/apps/gpoddersync/episode_action/create') {
             final List body = json.decode(request.body);
             final action = body[0];
             if (action['podcast'] == 'http://feed.url' && 
                 action['action'] == 'play' &&
                 action['position'] == 10) {
               return http.Response('{"timestamp": 12345}', 200);
             }
        }
        return http.Response('Error', 400);
      });

      final api = GPodderApi(
        baseUrl: 'https://example.com',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final action = EpisodeAction(
        podcast: 'http://feed.url',
        episode: 'http://episode.url',
        action: 'play',
        timestamp: 1234567890,
        position: 10,
        started: 0,
        total: 100,
      );

      await api.uploadEpisodeActions([action]);
    });
  });
}
