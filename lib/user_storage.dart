import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

class UserProfile {
  const UserProfile({
    required this.name,
    required this.age,
  });

  final String name;
  final int age;
}

class UserStorage {
  static const _keyOnboardingDone = 'sonix_onboarding_done';
  static const _keyUserName = 'sonix_user_name';
  static const _keyUserAge = 'sonix_user_age';

  static Future<bool> isOnboardingComplete() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyOnboardingDone) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveProfile({
    required String name,
    required int age,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserName, name.trim());
    await prefs.setInt(_keyUserAge, age);
    await prefs.setBool(_keyOnboardingDone, true);
  }

  static Future<UserProfile?> getProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_keyUserName);
      final age = prefs.getInt(_keyUserAge);
      if (name != null && name.isNotEmpty && age != null) {
        return UserProfile(name: name, age: age);
      }
    } catch (_) {}
    return null;
  }

  static const _keyLikedSongs = 'sonix_liked_songs';

  static Future<List<Map<String, dynamic>>> getLikedSongsRaw() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_keyLikedSongs);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<void> saveLikedSongsRaw(List<Map<String, dynamic>> songs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLikedSongs, jsonEncode(songs));
  }

  static const _keySongQuality = 'sonix_song_quality';
  static const _keyCrossfadeSeconds = 'sonix_crossfade_seconds';

  static Future<String> getSongQuality() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keySongQuality) ?? AppConstants.defaultSongQuality;
    } catch (_) {
      return AppConstants.defaultSongQuality;
    }
  }

  static Future<void> saveSongQuality(String quality) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySongQuality, quality);
    } catch (_) {}
  }

  static Future<int> getCrossfadeSeconds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyCrossfadeSeconds) ??
          AppConstants.crossfadeDurationSeconds;
    } catch (_) {
      return AppConstants.crossfadeDurationSeconds;
    }
  }

  static Future<void> saveCrossfadeSeconds(int seconds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyCrossfadeSeconds, seconds);
    } catch (_) {}
  }

  static Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyOnboardingDone);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserAge);
    await prefs.remove(_keyLikedSongs);
    await prefs.remove(_keySongQuality);
    await prefs.remove(_keyCrossfadeSeconds);
  }
}
