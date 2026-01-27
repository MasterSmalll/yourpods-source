import 'dart:convert';
import 'package:uuid/uuid.dart';

class ServerProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String deviceId;
  final bool savePassword; // Restored
  String? password; // Restored
  final int? lastAccessed;

  ServerProfile({
    String? id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.deviceId,
    this.savePassword = false,
    this.password,
    this.lastAccessed,
  }) : id = id ?? const Uuid().v4();

  // Create a copy with updated fields
  ServerProfile copyWith({
    String? name,
    String? baseUrl,
    String? username,
    String? deviceId,
    bool? savePassword,
    String? password,
    int? lastAccessed,
  }) {
    return ServerProfile(
      id: this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      deviceId: deviceId ?? this.deviceId,
      savePassword: savePassword ?? this.savePassword,
      password: password ?? this.password,
      lastAccessed: lastAccessed ?? this.lastAccessed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'deviceId': deviceId,
      'savePassword': savePassword,
      if (lastAccessed != null) 'lastAccessed': lastAccessed,
      // We only save password if requested
      if (savePassword) 'password': password,
    };
  }

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'],
      name: json['name'],
      baseUrl: json['baseUrl'],
      username: json['username'],
      deviceId: json['deviceId'],
      savePassword: json['savePassword'] ?? false,
      password: json['password'],
      lastAccessed: json['lastAccessed'],
    );
  }
}
