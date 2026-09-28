import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

class UserProfile {
  const UserProfile({
    required this.name,
    required this.age,
    this.language = 'English',
  });

  final String name;
  final int age;
  final String language;

  UserProfile copyWith({
    String? name,
    int? age,
    String? language,
  }) =>
      UserProfile(
        name: name ?? this.name,
        age: age ?? this.age,
        language: language ?? this.language,
      );
}

class UserStorage {
  static const _keyOnboardingDone = 'sonix_onboarding_done';
  static const _keyUserName = 'sonix_user_name';
  static const _keyUserAge = 'sonix_user_age';
  static const _keyUserLanguage = 'sonix_user_language';

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
    String language = 'English',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String cleanName = name.trim();
    if (cleanName.length > AppConstants.maxFullNameLength) {
      cleanName = cleanName.substring(0, AppConstants.maxFullNameLength);
    }
    await prefs.setString(_keyUserName, cleanName);
    await prefs.setInt(_keyUserAge, age);
    await prefs.setString(_keyUserLanguage, language);
    await prefs.setBool(_keyOnboardingDone, true);
  }

  static Future<String> getLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyUserLanguage) ?? 'English';
    } catch (_) {
      return 'English';
    }
  }

  static Future<void> saveLanguage(String language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUserLanguage, language);
    } catch (_) {}
  }

  static Future<UserProfile?> getProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_keyUserName);
      final age = prefs.getInt(_keyUserAge);
      final lang = prefs.getString(_keyUserLanguage) ?? 'English';
      if (name != null && name.isNotEmpty && age != null) {
        return UserProfile(name: name, age: age, language: lang);
      }
    } catch (_) {}
    return null;
  }

  static const _keyLikedSongs = 'sonix_liked_songs';
  static const _keyHistorySongs = 'sonix_history_songs';

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

  static Future<void> saveLikedSongsRaw(
    List<Map<String, dynamic>> songs,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLikedSongs, jsonEncode(songs));
  }

  static Future<List<Map<String, dynamic>>> getHistorySongsRaw() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_keyHistorySongs);
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

  static Future<void> saveHistorySongsRaw(
    List<Map<String, dynamic>> songs,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyHistorySongs, jsonEncode(songs));
    } catch (_) {}
  }

  static const _keyOfflineSongs = 'sonix_offline_songs';

  static Future<List<Map<String, dynamic>>> getOfflineSongsRaw() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_keyOfflineSongs);
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

  static Future<void> saveOfflineSongsRaw(
    List<Map<String, dynamic>> songs,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyOfflineSongs, jsonEncode(songs));
    } catch (_) {}
  }

  static const _keySongQuality = 'sonix_song_quality';
  static const _keyCrossfadeSeconds = 'sonix_crossfade_seconds';
  static const _keyThemeMode = 'sonix_theme_mode';

  static Future<String> getThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyThemeMode) ?? AppConstants.defaultTheme;
    } catch (_) {
      return AppConstants.defaultTheme;
    }
  }

  static Future<void> saveThemeMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyThemeMode, mode);
    } catch (_) {}
  }

  static Future<String> getSongQuality() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keySongQuality) ??
          AppConstants.defaultSongQuality;
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

  static const _keyEqEnabled = 'sonix_eq_enabled';
  static const _keyEqPreset = 'sonix_eq_preset';
  static const _keyEqBands = 'sonix_eq_bands';
  static const _keyEqBassBoost = 'sonix_eq_bass_boost';

  static Future<bool> getEqualizerEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyEqEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveEqualizerEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEqEnabled, enabled);
    } catch (_) {}
  }

  static Future<String> getEqualizerPreset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyEqPreset) ?? 'Flat';
    } catch (_) {
      return 'Flat';
    }
  }

  static Future<void> saveEqualizerPreset(String preset) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyEqPreset, preset);
    } catch (_) {}
  }

  static Future<List<double>> getEqualizerBands() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_keyEqBands);
      if (str != null && str.isNotEmpty) {
        final decoded = jsonDecode(str);
        if (decoded is List) {
          return decoded.map((e) => (e as num).toDouble()).toList();
        }
      }
    } catch (_) {}
    return [0.0, 0.0, 0.0, 0.0, 0.0];
  }

  static Future<void> saveEqualizerBands(List<double> bands) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyEqBands, jsonEncode(bands));
    } catch (_) {}
  }

  static Future<double> getEqualizerBassBoost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyEqBassBoost) ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  static Future<void> saveEqualizerBassBoost(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyEqBassBoost, value);
    } catch (_) {}
  }

  static const _keyRecentSearches = 'sonix_recent_searches';

  static Future<List<String>> getRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_keyRecentSearches) ?? [];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveRecentSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_keyRecentSearches) ?? [];
      list.removeWhere((item) => item.toLowerCase() == clean.toLowerCase());
      list.insert(0, clean);
      if (list.length > 15) {
        list.removeRange(15, list.length);
      }
      await prefs.setStringList(_keyRecentSearches, list);
    } catch (_) {}
  }

  static Future<void> removeRecentSearch(String query) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_keyRecentSearches) ?? [];
      list.removeWhere((item) => item.toLowerCase() == query.trim().toLowerCase());
      await prefs.setStringList(_keyRecentSearches, list);
    } catch (_) {}
  }

  static Future<void> clearRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyRecentSearches);
    } catch (_) {}
  }

  static const _keyRepeatMode = 'sonix_repeat_mode';
  static const _keyShuffle = 'sonix_shuffle';

  static Future<String> getRepeatMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyRepeatMode) ?? 'off';
    } catch (_) {
      return 'off';
    }
  }

  static Future<void> saveRepeatMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyRepeatMode, mode);
    } catch (_) {}
  }

  static Future<bool> getShuffle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyShuffle) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveShuffle(bool shuffle) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyShuffle, shuffle);
    } catch (_) {}
  }

  static Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyOnboardingDone);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserAge);
    await prefs.remove(_keyUserLanguage);
    await prefs.remove(_keyLikedSongs);
    await prefs.remove(_keyHistorySongs);
    await prefs.remove(_keyOfflineSongs);
    await prefs.remove(_keyRecentSearches);
    await prefs.remove(_keySongQuality);
    await prefs.remove(_keyCrossfadeSeconds);
    await prefs.remove(_keyThemeMode);
    await prefs.remove(_keyEqEnabled);
    await prefs.remove(_keyEqPreset);
    await prefs.remove(_keyEqBands);
    await prefs.remove(_keyEqBassBoost);
    await prefs.remove(_keyRepeatMode);
    await prefs.remove(_keyShuffle);
  }
}
