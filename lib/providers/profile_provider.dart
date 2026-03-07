import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_profile.dart';
import '../api/gpodder_api.dart';
import '../services/log_service.dart';

class ProfileProvider with ChangeNotifier {
  List<ServerProfile> _profiles = [];
  ServerProfile? _currentProfile;
  bool _isLoading = true;
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );
  
  static const String _storageKey = 'server_profiles';
  static const String _currentProfileKey = 'current_profile_id';

  List<ServerProfile> get profiles => _profiles;
  ServerProfile? get currentProfile => _currentProfile;
  bool get isLoading => _isLoading;

  ProfileProvider() {
    _loadProfiles();
  }

  /// Max retries for Keychain reads that return null (iOS cold-launch issue).
  static const int _maxKeychainRetries = 3;
  static const Duration _keychainRetryDelay = Duration(milliseconds: 300);

  Future<void> _loadProfiles() async {
    _isLoading = true;
    notifyListeners();

    try {
      // iOS Keychain can intermittently return null on cold launches before
      // the Keychain is fully available. Retry with a short delay.
      String? jsonString;
      for (int attempt = 0; attempt <= _maxKeychainRetries; attempt++) {
        jsonString = await _storage.read(key: _storageKey);
        if (jsonString != null) break;
        if (attempt < _maxKeychainRetries) {
          Log.w('ProfileProvider',
              'Keychain returned null for profiles (attempt ${attempt + 1}), retrying...');
          await Future.delayed(_keychainRetryDelay);
        }
      }

      if (jsonString != null) {
        try {
          final List<dynamic> jsonList = json.decode(jsonString);
          _profiles = [];
          
          // Safer loading: skip malformed entries instead of failing entire list
          for (var item in jsonList) {
             try {
                _profiles.add(ServerProfile.fromJson(item));
             } catch (e) {
                Log.e('ProfileProvider', 'Error parsing profile: $e');
             }
          }
        } catch (e) {
             Log.e('ProfileProvider', 'Error decoding profiles JSON: $e');
        }
      } else {
        // Keychain exhausted — try SharedPreferences fallback.
        // SharedPreferences (plist) is always available on cold launch.
        final prefs = await SharedPreferences.getInstance();
        final fallback = prefs.getString(_storageKey);
        if (fallback != null) {
          Log.w('ProfileProvider',
              'Using SharedPreferences fallback for profiles (Keychain unavailable)');
          try {
            final List<dynamic> jsonList = json.decode(fallback);
            _profiles = [];
            for (var item in jsonList) {
              try {
                _profiles.add(ServerProfile.fromJson(item));
              } catch (e) {
                Log.e('ProfileProvider', 'Error parsing fallback profile: $e');
              }
            }
          } catch (e) {
            Log.e('ProfileProvider', 'Error decoding fallback profiles JSON: $e');
          }
        }
      }

      // Restore last-selected profile from storage.
      // Try secure storage first, then fall back to SharedPreferences
      // (selectProfile() writes to both, but Keychain may be unavailable).
      String? savedId = await _storage.read(key: _currentProfileKey);
      if (savedId == null) {
        final prefs = await SharedPreferences.getInstance();
        savedId = prefs.getString(_currentProfileKey);
        if (savedId != null) {
          Log.i('ProfileProvider',
              'Restored current profile from SharedPreferences fallback');
        }
      }

      if (savedId != null && _profiles.any((p) => p.id == savedId)) {
          _currentProfile = _profiles.firstWhere((p) => p.id == savedId);
      }

      // EXCEPTION: IF there is only exactly ONE profile, we auto-select it.
      // This allows single-user setups to bypass the selection screen.
      if (_profiles.length == 1 && _currentProfile == null) {
          try {
              await selectProfile(_profiles.first.id);
          } catch (e) {
              Log.e('ProfileProvider', 'Error auto-selecting single profile: $e');
          }
      }
    } catch (e) {
      Log.e('ProfileProvider', 'Error loading profiles: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> reorderProfiles(int oldIndex, int newIndex) async {
      if (oldIndex < newIndex) {
          newIndex -= 1;
      }
      final item = _profiles.removeAt(oldIndex);
      _profiles.insert(newIndex, item);
      
      await _persistProfiles();
      notifyListeners();
  }

  Future<void> saveProfile(ServerProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    
    await _persistProfiles();
    await selectProfile(profile.id);
  }
  
  Future<void> deleteProfile(String id, {bool deleteFromServer = false}) async {
    if (deleteFromServer) {
        try {
            final profile = _profiles.firstWhere((p) => p.id == id);
            
            // Skip server deletion for local accounts
            if (!profile.isLocal) {
                // We need the password to authorize the delete
                // If it's not saved, we can't do server delete easily without prompting.
                // For now, assume it's saved or fail.
                if (profile.password == null) {
                    throw Exception('Password is required for server deletion but not saved.');
                }

                final api = GPodderApi(
                    baseUrl: profile.baseUrl,
                    username: profile.username,
                    password: profile.password!,
                );

                // Fetch current subs
                final subs = await api.getSubscriptions(profile.deviceId);
                final urls = subs.map((s) => s.url).toList();
                
                if (urls.isNotEmpty) {
                    // Remove all
                    await api.updateSubscriptions(profile.deviceId, remove: urls);
                }
            }
        } catch (e) {
            Log.e('ProfileProvider', 'Server deletion failed: $e');
            // Re-throw to let UI know, or swallow if we want to proceed with local delete anyway?
            // Requirement said "should delete from server". If fail, maybe stop?
            // Let's rethrow so user knows.
            rethrow;
        }
    }

    _profiles.removeWhere((p) => p.id == id);
    if (_currentProfile?.id == id) {
      _currentProfile = null;
      await _storage.delete(key: _currentProfileKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_currentProfileKey);
    }
    await _persistProfiles();
    notifyListeners();
  }

  Future<void> selectProfile(String id) async {
    try {
      var profile = _profiles.firstWhere((p) => p.id == id);
      
      // Update lastAccessed
      profile = profile.copyWith(lastAccessed: DateTime.now().millisecondsSinceEpoch);
      
      // Update in list
      final index = _profiles.indexWhere((p) => p.id == id);
      if (index >= 0) {
          _profiles[index] = profile;
      }
      
      _currentProfile = profile;
      
      await _storage.write(key: _currentProfileKey, value: id);
      
      // Also save to SharedPreferences for AudioHandler access (less restricted in background)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_currentProfileKey, id);

      await _persistProfiles(); // Persist the timestamp update
      
      notifyListeners();
    } catch (e) {
      Log.w('ProfileProvider', 'Profile not found: $id');
    }
  }
  
  Future<void> logout() async {
      _currentProfile = null;
      await _storage.delete(key: _currentProfileKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_currentProfileKey);
      notifyListeners();
  }

  Future<void> _persistProfiles() async {
    final jsonString = json.encode(_profiles.map((p) => p.toJson()).toList());
    await _storage.write(key: _storageKey, value: jsonString);

    // Also persist a password-stripped copy to SharedPreferences as fallback.
    // SharedPreferences (plist) is always available on cold launch, unlike Keychain.
    final sanitized = _profiles
        .map((p) => p.copyWith(password: null, savePassword: false).toJson())
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, json.encode(sanitized));
  }
}
