import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:dart_des/dart_des.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:phosphor_icons/phosphor_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'audio_handler.dart';
import 'constants.dart';
import 'crossfade_player.dart';
import 'onboarding_screen.dart';
import 'user_storage.dart';

/// Two distinct playback modes.
enum PlaybackMode { suggestions, playlist }

/// Repeat playback modes for track queues.
enum PlaybackRepeatMode { off, all, one }

const _fallbackArt = AppConstants.fallbackArtworkUrl;
const _ink = AppConstants.colorInk;
const _surface = AppConstants.colorSurface;
const _muted = AppConstants.colorMuted;

/* -------------------------------------------------------------------------- */
/*                           CRYPTO & PARSING HELPERS                         */
/* -------------------------------------------------------------------------- */

/// Client-side Triple-DES / DES-ECB decryption of JioSaavn's encrypted_media_url.
/// Key is "38346591" with PKCS7 padding.
String? decryptMediaUrl(String? encryptedB64) {
  if (encryptedB64 == null || encryptedB64.trim().isEmpty) return null;
  try {
    final key = utf8.encode('38346591');
    final encryptedBytes = base64Decode(encryptedB64.trim());
    final des = DES(key: key, mode: DESMode.ECB, paddingType: DESPaddingType.PKCS7);
    final decryptedBytes = des.decrypt(encryptedBytes);
    final url = utf8.decode(decryptedBytes).trim();
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url.replaceFirst('http://', 'https://');
    }
  } catch (_) {}
  return null;
}

/// Generates stream URLs for all available bitrates from the decrypted base URL.
List<Map<String, dynamic>> buildQualityUrls(String? url) {
  if (url == null || url.isEmpty) return const [];
  final clean = url.replaceFirst('http://', 'https://');
  final base = clean.replaceAll(RegExp(r'_(96|160|320|48|12)\.mp4.*$'), '');
  return [
    {'quality': '320kbps', 'url': '${base}_320.mp4'},
    {'quality': '160kbps', 'url': '${base}_160.mp4'},
    {'quality': '96kbps', 'url': '${base}_96.mp4'},
    {'quality': '48kbps', 'url': '${base}_48.mp4'},
  ];
}

/// Decodes common HTML entities returned in JioSaavn text fields.
String decodeHtmlEntities(String? input) {
  if (input == null || input.isEmpty) return '';
  return input
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&copy;', '©')
      .trim();
}

/// Upgrades low-resolution JioSaavn artwork URLs to 500x500.
String upgradeArtwork(String? url) {
  if (url == null || url.isEmpty) return '';
  return url.replaceAll(RegExp(r'\d+x\d+'), '500x500');
}

/// Runs on a dedicated background isolate — zero impact on the Flutter UI thread!
List<String> _scanMusicDirectoriesInBackground(List<String> knownPaths) {
  final knownSet = knownPaths.toSet();
  final allowedExts = {
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.wma',
  };
  final found = <String>[];

  final targetDirNames = ['Music', 'Download', 'Podcasts', 'Audiobooks', 'Recordings'];
  final candidateRoots = [
    '/storage/emulated/0',
    '/sdcard',
  ];

  final dirsToScan = <Directory>[];
  for (final root in candidateRoots) {
    for (final name in targetDirNames) {
      final d = Directory('$root/$name');
      try {
        if (d.existsSync()) {
          dirsToScan.add(d);
        }
      } catch (_) {}
    }
  }

  int dirsProcessed = 0;
  const maxDirs = 60;

  while (dirsToScan.isNotEmpty && dirsProcessed < maxDirs) {
    final dir = dirsToScan.removeAt(0);
    dirsProcessed++;

    try {
      final entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        final path = entity.path;
        final lower = path.toLowerCase();
        if (lower.contains('whatsapp') ||
            lower.contains('com.whatsapp') ||
            lower.endsWith('.opus')) {
          continue;
        }

        if (entity is File) {
          if (allowedExts.any((ext) => lower.endsWith(ext))) {
            if (!knownSet.contains(path)) {
              knownSet.add(path);
              found.add(path);
            }
          }
        } else if (entity is Directory) {
          final dirName = path.split(Platform.pathSeparator).last;
          if (!dirName.startsWith('.') && dirName.toLowerCase() != 'android') {
            dirsToScan.add(entity);
          }
        }
      }
    } catch (_) {}
  }

  return found;
}

/* -------------------------------------------------------------------------- */
/*                                   MODELS                                   */
/* -------------------------------------------------------------------------- */

class Song {
  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.artwork = '',
    this.duration = 0,
    this.streamUrl,
    this.downloadUrls = const [],
  });

  final String id, title, artist, album, artwork;
  final int duration;
  final String? streamUrl;
  final List<Map<String, dynamic>> downloadUrls;

  factory Song.fromJson(Map<String, dynamic> json) {
    final moreInfo = json['more_info'] is Map ? json['more_info'] as Map : null;

    // 1. Artwork URL
    String artworkUrl = '';
    final rawImage = json['image'] ?? json['artwork'];
    if (rawImage is String) {
      artworkUrl = upgradeArtwork(rawImage);
    } else if (rawImage is List) {
      final images = rawImage.whereType<Map>().toList();
      final image = images.firstWhere(
        (item) => item['quality'] == '500x500',
        orElse: () => images.isEmpty ? const {} : images.last,
      );
      artworkUrl = upgradeArtwork('${image['url'] ?? ''}');
    }

    // 2. Title
    final rawTitle = json['title'] ?? json['song'] ?? json['name'] ?? 'Unknown title';
    final title = decodeHtmlEntities('$rawTitle');

    // 3. Artist name extraction
    String artist = '';
    if (moreInfo != null && moreInfo['artistMap'] is Map) {
      final am = moreInfo['artistMap'] as Map;
      final primary = am['primary_artists'] as List? ?? const [];
      final primaryNames = primary
          .whereType<Map>()
          .map((a) => decodeHtmlEntities(a['name']?.toString()))
          .where((n) => n.isNotEmpty)
          .join(', ');
      if (primaryNames.isNotEmpty) artist = primaryNames;
    }
    if (artist.isEmpty && json['artists'] is Map) {
      final primary = json['artists']['primary'] as List? ?? const [];
      final names = primary
          .whereType<Map>()
          .map((a) => decodeHtmlEntities(a['name']?.toString()))
          .where((n) => n.isNotEmpty)
          .join(', ');
      if (names.isNotEmpty) artist = names;
    }
    if (artist.isEmpty) {
      final rawArtist = json['primaryArtists'] ??
          json['singers'] ??
          json['artist'] ??
          json['subtitle'] ??
          'Unknown artist';
      artist = decodeHtmlEntities('$rawArtist');
    }

    // 4. Album name
    String albumName = '';
    if (moreInfo != null && moreInfo['album'] != null) {
      albumName = decodeHtmlEntities('${moreInfo['album']}');
    } else if (json['album'] is Map) {
      albumName = decodeHtmlEntities('${json['album']['name'] ?? ''}');
    } else if (json['album'] != null) {
      albumName = decodeHtmlEntities('${json['album']}');
    }

    // 5. Duration in seconds
    int duration = 0;
    if (moreInfo != null && moreInfo['duration'] != null) {
      duration = int.tryParse('${moreInfo['duration']}') ?? 0;
    } else if (json['duration'] != null) {
      duration = int.tryParse('${json['duration']}') ?? 0;
    }

    // 6. Audio stream and download URLs (decrypt on-the-fly if needed)
    List<Map<String, dynamic>> urls = [];
    final existingUrls = json['downloadUrl'] ?? json['downloadUrls'];
    if (existingUrls is List && existingUrls.isNotEmpty) {
      urls = existingUrls
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }

    if (urls.isEmpty) {
      final encryptedUrl = (moreInfo?['encrypted_media_url'] ??
              moreInfo?['encrypted_media_path'] ??
              json['encrypted_media_url']) as String?;
      if (encryptedUrl != null && encryptedUrl.isNotEmpty) {
        final decrypted = decryptMediaUrl(encryptedUrl);
        if (decrypted != null) {
          urls = buildQualityUrls(decrypted);
        }
      }
    }

    String? streamUrl;
    if (urls.isNotEmpty) {
      final highest = urls.firstWhere(
        (u) => u['quality'] == '320kbps',
        orElse: () => urls.first,
      );
      streamUrl = highest['url'] as String?;
    } else {
      streamUrl = json['streamUrl'] as String? ?? json['audioUrl'] as String?;
    }

    return Song(
      id: '${json['id'] ?? title}',
      title: title.isEmpty ? 'Unknown title' : title,
      artist: artist.isEmpty ? 'Unknown artist' : artist,
      album: albumName,
      artwork: artworkUrl,
      duration: duration,
      streamUrl: streamUrl,
      downloadUrls: urls,
    );
  }

  Song copyWith({
    String? streamUrl,
    List<Map<String, dynamic>>? downloadUrls,
  }) => Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    artwork: artwork,
    duration: duration,
    streamUrl: streamUrl ?? this.streamUrl,
    downloadUrls: downloadUrls ?? this.downloadUrls,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'artwork': artwork,
    'image': [
      {'quality': '500x500', 'url': artwork},
    ],
    'duration': duration,
    'streamUrl': streamUrl,
    'audioUrl': streamUrl,
    'downloadUrl': downloadUrls,
  };
}

class LyricLine {
  const LyricLine(this.time, this.text);
  final double time;
  final String text;
}

class Playlist {
  Playlist({
    required this.id,
    required this.title,
    this.description = '',
    this.artwork = '',
    this.url = '',
    this.language = '',
    this.songCount = 0,
    this.songs = const [],
    this.type = 'PLAYLIST',
  });

  final String id;
  final String title;
  final String description;
  final String artwork;
  final String url;
  final String language;
  final int songCount;
  final List<Song> songs;
  final String type;

  Playlist copyWith({
    String? id,
    String? title,
    String? description,
    String? artwork,
    String? url,
    String? language,
    int? songCount,
    List<Song>? songs,
    String? type,
  }) => Playlist(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    artwork: artwork ?? this.artwork,
    url: url ?? this.url,
    language: language ?? this.language,
    songCount: songCount ?? this.songCount,
    songs: songs ?? this.songs,
    type: type ?? this.type,
  );

  factory Playlist.fromJson(Map<String, dynamic> json) {
    String artworkUrl = '';
    final rawImage = json['image'] ?? json['artwork'];
    if (rawImage is String) {
      artworkUrl = upgradeArtwork(rawImage);
    } else if (rawImage is List) {
      final images = rawImage.whereType<Map>().toList();
      final image = images.firstWhere(
        (item) => item['quality'] == '500x500',
        orElse: () => images.isEmpty ? const {} : images.last,
      );
      artworkUrl = upgradeArtwork('${image['url'] ?? ''}');
    }

    final songsRaw = json['songs'] ?? json['list'];
    final songsList = (songsRaw is List ? songsRaw : const [])
        .whereType<Map>()
        .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    final count = int.tryParse(
          '${json['songCount'] ?? json['list_count'] ?? json['more_info']?['song_count'] ?? songsList.length}',
        ) ??
        songsList.length;

    return Playlist(
      id: '${json['id'] ?? json['listid'] ?? ''}',
      title: decodeHtmlEntities(
        '${json['title'] ?? json['name'] ?? json['listname'] ?? 'Playlist'}',
      ),
      description: decodeHtmlEntities(
        '${json['description'] ?? json['subtitle'] ?? json['header_desc'] ?? ''}',
      ),
      artwork: artworkUrl,
      url: '${json['url'] ?? json['permaUrl'] ?? json['perma_url'] ?? ''}',
      language: '${json['language'] ?? ''}',
      songCount: count,
      songs: songsList,
      type: json['type']?.toString().toUpperCase() ?? 'PLAYLIST',
    );
  }
}

class Artist {
  Artist({
    required this.id,
    required this.name,
    this.image = '',
    this.role = 'Artist',
  });

  final String id;
  final String name;
  final String image;
  final String role;

  factory Artist.fromJson(Map<String, dynamic> json) {
    final rawImage = json['image']?.toString() ?? '';
    final name = decodeHtmlEntities(
      json['name']?.toString() ?? json['title']?.toString() ?? 'Artist',
    );
    return Artist(
      id: '${json['id'] ?? ''}',
      name: name.isEmpty ? 'Artist' : name,
      image: upgradeArtwork(rawImage),
      role: decodeHtmlEntities(json['role']?.toString() ?? 'Artist'),
    );
  }

  Playlist toPlaylist() => Playlist(
    id: id,
    title: name,
    description: role.isNotEmpty ? role : 'Artist',
    artwork: image,
    songCount: 0,
    songs: const [],
    type: 'ARTIST',
  );
}

class Album {
  Album({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.artwork = '',
    this.year = '',
    this.songCount = 0,
    this.songs = const [],
  });

  final String id;
  final String title;
  final String subtitle;
  final String artwork;
  final String year;
  final int songCount;
  final List<Song> songs;

  factory Album.fromJson(Map<String, dynamic> json) {
    final rawImage = json['image']?.toString() ?? json['artwork']?.toString() ?? '';
    final title = decodeHtmlEntities(
      json['title']?.toString() ?? json['name']?.toString() ?? 'Album',
    );
    final subtitle = decodeHtmlEntities(
      json['subtitle']?.toString() ?? json['header_desc']?.toString() ?? '',
    );
    final count = int.tryParse(
          '${json['songCount'] ?? json['more_info']?['song_count'] ?? json['list_count'] ?? 0}',
        ) ??
        0;
    final year = json['year']?.toString() ?? '';

    final songsRaw = json['songs'] ?? json['list'];
    final songsList = (songsRaw is List ? songsRaw : const [])
        .whereType<Map>()
        .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    return Album(
      id: '${json['id'] ?? ''}',
      title: title.isEmpty ? 'Album' : title,
      subtitle: subtitle,
      artwork: upgradeArtwork(rawImage),
      year: year,
      songCount: count > 0 ? count : songsList.length,
      songs: songsList,
    );
  }

  Playlist toPlaylist() => Playlist(
    id: id,
    title: title,
    description: subtitle.isNotEmpty ? subtitle : (year.isNotEmpty ? 'Album • $year' : 'Album'),
    artwork: artwork,
    songCount: songCount,
    songs: songs,
    type: 'ALBUM',
  );
}

class SearchSuggestion {
  const SearchSuggestion({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.image,
    this.permaUrl = '',
  });

  final String id;
  final String type; // 'song', 'artist', 'album', 'playlist'
  final String title;
  final String subtitle;
  final String image;
  final String permaUrl;

  bool get isSong => type == 'song';
  bool get isArtist => type == 'artist';
  bool get isAlbum => type == 'album';
  bool get isPlaylist => type == 'playlist';
}

/* -------------------------------------------------------------------------- */
/*                                    API                                     */
/* -------------------------------------------------------------------------- */

class Api {
  /// Search artists directly from JioSaavn public API.
  static Future<List<Artist>> searchArtists(String query, {int n = 10, int page = 1}) async {
    final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
      '__call': 'search.getArtistResults',
      'q': query,
      'p': '$page',
      'n': '$n',
      '_format': 'json',
      '_marker': '0',
      'api_version': '4',
      'ctx': 'web6dot0',
    });
    final response = await http.get(uri, headers: AppConstants.saavnHeaders);
    if (response.statusCode >= 400) return [];
    final data = jsonDecode(response.body);
    final results = (data['results'] ?? data['artists']) as List? ?? const [];
    return results
        .whereType<Map>()
        .map((item) => Artist.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  /// Search albums directly from JioSaavn public API.
  static Future<List<Album>> searchAlbums(String query, {int n = 10, int page = 1}) async {
    final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
      '__call': 'search.getAlbumResults',
      'q': query,
      'p': '$page',
      'n': '$n',
      '_format': 'json',
      '_marker': '0',
      'api_version': '4',
      'ctx': 'web6dot0',
    });
    final response = await http.get(uri, headers: AppConstants.saavnHeaders);
    if (response.statusCode >= 400) return [];
    final data = jsonDecode(response.body);
    final results = (data['results'] ?? data['albums']) as List? ?? const [];
    return results
        .whereType<Map>()
        .map((item) => Album.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  /// Search songs directly from JioSaavn public API.
  static Future<List<Song>> searchSongs(String query, {int n = 20, int page = 1}) async {
    final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
      '__call': 'search.getResults',
      'q': query,
      'p': '$page',
      'n': '$n',
      '_format': 'json',
      '_marker': '0',
      'api_version': '4',
      'ctx': 'web6dot0',
    });
    final response = await http.get(uri, headers: AppConstants.saavnHeaders);
    if (response.statusCode >= 400) throw Exception('Search songs failed');
    final data = jsonDecode(response.body);
    final results = (data['results'] ?? data['songs']) as List? ?? const [];
    return results
        .whereType<Map>()
        .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  /// Search playlists directly from JioSaavn public API.
  static Future<List<Playlist>> searchPlaylists(String query, {int n = 20, int page = 1}) async {
    final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
      '__call': 'search.getPlaylistResults',
      'q': query,
      'p': '$page',
      'n': '$n',
      '_format': 'json',
      '_marker': '0',
      'api_version': '4',
      'ctx': 'web6dot0',
    });
    final response = await http.get(uri, headers: AppConstants.saavnHeaders);
    if (response.statusCode >= 400) return [];
    final data = jsonDecode(response.body);
    final results = data['results'] as List? ?? const [];
    return results
        .whereType<Map>()
        .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  /// Autocomplete live search suggestions across songs, artists, albums, and playlists.
  static Future<List<SearchSuggestion>> getSuggestions(String query, {int limit = 16}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    try {
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'autocomplete.get',
        'query': q,
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final response = await http.get(uri, headers: AppConstants.saavnHeaders);
      if (response.statusCode >= 400) return [];

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map) return [];

      const buckets = ['topquery', 'songs', 'artists', 'albums', 'playlists'];
      final out = <SearchSuggestion>[];
      final seen = <String>{};

      String normaliseSuggestType(dynamic t, String fallback) {
        final s = (t?.toString() ?? fallback).toLowerCase();
        if (s.startsWith('song') || s.startsWith('track')) return 'song';
        if (s.startsWith('album')) return 'album';
        if (s.startsWith('artist') || s.startsWith('singer')) return 'artist';
        if (s.startsWith('playlist')) return 'playlist';
        return fallback.startsWith('song') ? 'song' : fallback;
      }

      for (final bucket in buckets) {
        final bData = decoded[bucket];
        if (bData is! Map) continue;
        final rows = bData['data'];
        if (rows is! List) continue;

        for (final item in rows) {
          if (item is! Map) continue;
          final id = item['id']?.toString() ?? '';
          if (id.isEmpty) continue;

          final type = normaliseSuggestType(item['type'], bucket);
          final key = '$type:$id';
          if (seen.contains(key)) continue;
          seen.add(key);

          final rawTitle = item['title']?.toString() ?? item['name']?.toString() ?? '';
          final rawSubtitle = item['subtitle']?.toString() ??
              item['description']?.toString() ??
              item['extra']?.toString() ??
              '';
          final rawImage = item['image']?.toString() ?? item['artwork']?.toString() ?? '';

          out.add(
            SearchSuggestion(
              id: id,
              type: type,
              title: decodeHtmlEntities(rawTitle),
              subtitle: decodeHtmlEntities(rawSubtitle),
              image: upgradeArtwork(rawImage),
              permaUrl: item['perma_url']?.toString() ?? item['url']?.toString() ?? '',
            ),
          );
          if (out.length >= limit) break;
        }
        if (out.length >= limit) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Fetch full song details and decrypted streams directly from JioSaavn.
  static Future<Map<String, dynamic>?> details(String id) async {
    final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
      '__call': 'song.getDetails',
      'pids': id,
      '_format': 'json',
      '_marker': '0',
      'api_version': '4',
      'ctx': 'web6dot0',
    });
    final response = await http.get(uri, headers: AppConstants.saavnHeaders);
    if (response.statusCode >= 400) return null;
    final data = jsonDecode(response.body);
    List? songs = data['songs'] as List?;
    if (songs == null || songs.isEmpty) {
      final fallbackUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'webapi.get',
        'token': id,
        'type': 'song',
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final fbRes = await http.get(fallbackUri, headers: AppConstants.saavnHeaders);
      if (fbRes.statusCode < 400) {
        final fbData = jsonDecode(fbRes.body);
        if (fbData is Map && fbData['songs'] is List) {
          songs = fbData['songs'] as List;
        } else if (fbData is Map && fbData.containsKey('id')) {
          songs = [fbData];
        }
      }
    }
    if (songs != null && songs.isNotEmpty) {
      final rawSong = Map<String, dynamic>.from(songs.first as Map);
      final parsedSong = Song.fromJson(rawSong);
      return parsedSong.toJson();
    }
    return null;
  }

  /// Fetch related songs (Up Next) using album siblings + primary artists mix.
  static Future<List<Song>> suggestions(String songId,
      {int limit = AppConstants.suggestionsBatchSize}) async {
    try {
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'song.getDetails',
        'pids': songId,
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final response = await http.get(uri, headers: AppConstants.saavnHeaders);
      if (response.statusCode >= 400) return [];
      final data = jsonDecode(response.body);
      final songs = data['songs'] as List?;
      if (songs == null || songs.isEmpty) return [];

      final seedSong = songs.first as Map;
      final mi = seedSong['more_info'] is Map ? seedSong['more_info'] as Map : null;
      final albumId = mi?['album_id']?.toString();
      final primaryArtists = (mi?['artistMap']?['primary_artists'] as List? ?? const [])
          .whereType<Map>()
          .toList();

      final seenIds = <String>{songId};
      final albumPicks = <Song>[];
      final artistPicks = <Song>[];

      // 1. Album siblings
      if (albumId != null && albumId.isNotEmpty && albumId != '0') {
        try {
          final albUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
            '__call': 'content.getAlbumDetails',
            'albumid': albumId,
            '_format': 'json',
            '_marker': '0',
            'api_version': '4',
            'ctx': 'web6dot0',
          });
          final albRes = await http.get(albUri, headers: AppConstants.saavnHeaders);
          if (albRes.statusCode < 400) {
            final albData = jsonDecode(albRes.body);
            final list = (albData['list'] ?? albData['songs']) as List? ?? const [];
            for (final item in list.whereType<Map>()) {
              final s = Song.fromJson(Map<String, dynamic>.from(item));
              if (s.id.isNotEmpty && !seenIds.contains(s.id)) {
                seenIds.add(s.id);
                albumPicks.add(s);
              }
            }
          }
        } catch (_) {}
      }

      // 2. Artist top tracks
      for (final artist in primaryArtists.take(2)) {
        final artistId = artist['id']?.toString();
        if (artistId == null || artistId.isEmpty) continue;
        try {
          final artUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
            '__call': 'artist.getArtistPageDetails',
            'artistId': artistId,
            'n_song': '20',
            '_format': 'json',
            '_marker': '0',
            'api_version': '4',
            'ctx': 'web6dot0',
          });
          final artRes = await http.get(artUri, headers: AppConstants.saavnHeaders);
          if (artRes.statusCode < 400) {
            final artData = jsonDecode(artRes.body);
            final top = (artData['topSongs'] ?? artData['songs']) as List? ?? const [];
            for (final item in top.whereType<Map>()) {
              final s = Song.fromJson(Map<String, dynamic>.from(item));
              if (s.id.isNotEmpty && !seenIds.contains(s.id)) {
                seenIds.add(s.id);
                artistPicks.add(s);
              }
            }
          }
        } catch (_) {}
      }

      // 3. Interleave recommendations
      final merged = <Song>[];
      final aQueue = List<Song>.from(albumPicks);
      final bQueue = List<Song>.from(artistPicks);
      while (aQueue.isNotEmpty || bQueue.isNotEmpty) {
        if (aQueue.isNotEmpty) merged.add(aQueue.removeAt(0));
        if (bQueue.isNotEmpty) merged.add(bQueue.removeAt(0));
        if (aQueue.length > 3) merged.add(aQueue.removeAt(0));
      }

      return merged.take(limit).toList();
    } catch (_) {
      return [];
    }
  }

  /// Playlist details directly from JioSaavn.
  static Future<Playlist?> playlist(String id,
      {int limit = AppConstants.playlistFetchLimit}) async {
    try {
      // 1. Try playlist.getDetails with listid
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'playlist.getDetails',
        'listid': id,
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final response = await http.get(uri, headers: AppConstants.saavnHeaders);
      if (response.statusCode < 400) {
        final data = jsonDecode(response.body);
        if (data is Map && (data.containsKey('id') || data.containsKey('listid') || data.containsKey('songs') || data.containsKey('list'))) {
          return Playlist.fromJson(Map<String, dynamic>.from(data));
        }
      }

      // 2. Fallback: webapi.get with token
      final tokenUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'webapi.get',
        'token': id,
        'type': 'playlist',
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final tokenRes = await http.get(tokenUri, headers: AppConstants.saavnHeaders);
      if (tokenRes.statusCode < 400) {
        final data = jsonDecode(tokenRes.body);
        if (data is Map && (data.containsKey('id') || data.containsKey('songs') || data.containsKey('list'))) {
          return Playlist.fromJson(Map<String, dynamic>.from(data));
        }
      }
    } catch (_) {}
    return null;
  }

  /// Album details directly from JioSaavn.
  static Future<Playlist?> album(String id) async {
    try {
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'content.getAlbumDetails',
        'albumid': id,
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final res = await http.get(uri, headers: AppConstants.saavnHeaders);
      if (res.statusCode < 400) {
        final data = jsonDecode(res.body);
        if (data is Map && (data.containsKey('id') || data.containsKey('list') || data.containsKey('songs'))) {
          return Album.fromJson(Map<String, dynamic>.from(data)).toPlaylist();
        }
      }
      final fbUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'webapi.get',
        'token': id,
        'type': 'album',
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final fbRes = await http.get(fbUri, headers: AppConstants.saavnHeaders);
      if (fbRes.statusCode < 400) {
        final data = jsonDecode(fbRes.body);
        if (data is Map && (data.containsKey('id') || data.containsKey('list') || data.containsKey('songs'))) {
          return Album.fromJson(Map<String, dynamic>.from(data)).toPlaylist();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Artist details and top songs directly from JioSaavn.
  static Future<Playlist?> artist(String id) async {
    try {
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'artist.getArtistPageDetails',
        'artistId': id,
        'n_song': '50',
        'n_album': '10',
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final res = await http.get(uri, headers: AppConstants.saavnHeaders);
      if (res.statusCode < 400) {
        final data = jsonDecode(res.body);
        if (data is Map) {
          final top = (data['topSongs'] ?? data['songs']) as List? ?? const [];
          final songs = top
              .whereType<Map>()
              .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
              .toList();
          final name = decodeHtmlEntities(data['name']?.toString() ?? 'Artist');
          final rawImage = data['image']?.toString() ?? '';
          return Playlist(
            id: id,
            title: name,
            description: 'Top Songs by $name',
            artwork: upgradeArtwork(rawImage),
            songCount: songs.length,
            songs: songs,
            type: 'ARTIST',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Synced or plain lyrics (LRCLIB prioritized for sync timestamps, JioSaavn fallback).
  static Future<Map<String, dynamic>?> lyrics(Song song) async {
    // 1. LRCLIB for timestamped synced lyrics
    try {
      final lrclibData = await _lrclibFallback(song);
      if (lrclibData != null &&
          ((lrclibData['syncedLyrics'] != null && '${lrclibData['syncedLyrics']}'.trim().isNotEmpty) ||
           (lrclibData['plainLyrics'] != null && '${lrclibData['plainLyrics']}'.trim().isNotEmpty))) {
        return lrclibData;
      }
    } catch (_) {}

    // 2. JioSaavn lyrics fallback
    try {
      final uri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
        '__call': 'song.getDetails',
        'pids': song.id,
        '_format': 'json',
        '_marker': '0',
        'api_version': '4',
        'ctx': 'web6dot0',
      });
      final res = await http
          .get(uri, headers: AppConstants.saavnHeaders)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode < 400) {
        final data = jsonDecode(res.body);
        final songs = data['songs'] as List?;
        if (songs != null && songs.isNotEmpty) {
          final s = songs.first;
          final lyricsId = s['more_info']?['lyrics_id'];
          if (lyricsId != null && '$lyricsId'.isNotEmpty) {
            final lyrUri = Uri.parse(AppConstants.saavnApiBaseUrl).replace(queryParameters: {
              '__call': 'lyrics.getLyrics',
              'lyrics_id': '$lyricsId',
              '_format': 'json',
              '_marker': '0',
              'api_version': '4',
              'ctx': 'web6dot0',
            });
            final lyrRes = await http
                .get(lyrUri, headers: AppConstants.saavnHeaders)
                .timeout(const Duration(seconds: 5));
            if (lyrRes.statusCode < 400) {
              final lyrData = jsonDecode(lyrRes.body);
              final rawLyrics = lyrData['lyrics'] ?? lyrData['lyrics_text'] ?? lyrData['data']?['lyrics'];
              if (rawLyrics != null && '$rawLyrics'.isNotEmpty) {
                final cleaned = decodeHtmlEntities('$rawLyrics')
                    .replaceAll('<br>', '\n')
                    .replaceAll('<br/>', '\n');
                return {
                  'syncedLyrics': null,
                  'plainLyrics': cleaned,
                };
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// LRCLIB lookup helper for lyrics.
  static Future<Map<String, dynamic>?> _lrclibFallback(Song song) async {
    final artist = song.artist
        .split(RegExp(r',|&|feat\.|ft\.', caseSensitive: false))
        .first
        .trim();
    final uri = Uri.parse('https://lrclib.net/api/get').replace(
      queryParameters: {
        'track_name': song.title,
        'artist_name': artist,
        if (song.album.isNotEmpty) 'album_name': song.album,
        if (song.duration > 0) 'duration': '${song.duration}',
      },
    );
    final response = await http
        .get(uri)
        .timeout(const Duration(seconds: 5));
    return response.statusCode == 200
        ? jsonDecode(response.body) as Map<String, dynamic>
        : null;
  }
}

List<LyricLine> parseLyrics(String? source) {
  if (source == null) return [];
  final result = <LyricLine>[];
  final pattern = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
  for (final raw in source.split('\n')) {
    final match = pattern.firstMatch(raw.trim());
    if (match == null) continue;
    final fraction = match.group(3) == null
        ? 0.0
        : double.parse('0.${match.group(3)}');
    final text = raw.replaceAll(pattern, '').trim();
    result.add(
      LyricLine(
        int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!) + fraction,
        text.isEmpty ? '♪' : text,
      ),
    );
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/* -------------------------------------------------------------------------- */
/*                                 STATIC DATA                                */
/* -------------------------------------------------------------------------- */

final _speedDialSongs = <Song>[
  // Page 1
  Song(
    id: '3IoDK8qI',
    title: 'Levitating',
    artist: 'Dua Lipa',
    album: 'Future Nostalgia',
    artwork:
        'https://c.saavncdn.com/665/Future-Nostalgia-English-2020-20260306223201-500x500.jpg',
  ),
  Song(
    id: 'v4xkJtw9',
    title: 'Take Me Out',
    artist: 'Franz Ferdinand',
    album: 'Franz Ferdinand',
    artwork:
        'https://c.saavncdn.com/074/Fita-Perdida-Soul-Blues-Vol-1-Portuguese-2026-20251223100039-500x500.jpg',
  ),
  Song(
    id: '8Ti1DvzG',
    title: 'Sweater Weather',
    artist: 'The Neighbourhood',
    album: 'I Love You.',
    artwork:
        'https://c.saavncdn.com/834/I-Love-You--English-2013-20220323205211-500x500.jpg',
  ),
  Song(
    id: 'Rf0Y2Hfl',
    title: 'The Hills',
    artist: 'The Weeknd',
    album: 'Beauty Behind the Madness',
    artwork:
        'https://c.saavncdn.com/464/The-Hills-English-2015-500x500.jpg',
  ),
  Song(
    id: 'CG4tAd4L',
    title: 'Lose Yourself',
    artist: 'Eminem',
    album: 'Curtain Call: The Hits',
    artwork:
        'https://c.saavncdn.com/810/Just-Lose-It-English-2004-20190314081750-500x500.jpg',
  ),
  Song(
    id: 'o008byuo',
    title: 'Animals',
    artist: 'Martin Garrix',
    album: 'Gold Skies',
    artwork:
        'https://c.saavncdn.com/732/Now-That-s-What-I-Call-EDM-2014-2014-500x500.jpg',
  ),
  Song(
    id: 'L3Sv41-x',
    title: 'Do I Wanna Know?',
    artist: 'Arctic Monkeys',
    album: 'AM',
    artwork:
        'https://c.saavncdn.com/267/Do-I-Wanna-Know-Unknown-2013-20221004085010-500x500.jpg',
  ),
  Song(
    id: '-Q6Q6kd-',
    title: "Ain't No Sunshine",
    artist: 'Bill Withers',
    album: 'Just as I Am',
    artwork:
        'https://c.saavncdn.com/894/Love-Ballads-Vol-2-English-2015-500x500.jpg',
  ),
  Song(
    id: '3-YCxCgm',
    title: 'Uptown Funk',
    artist: 'Mark Ronson ft. Bruno Mars',
    album: 'Uptown Special',
    artwork:
        'https://c.saavncdn.com/797/Uptown-Special-English-2015-20200916193614-500x500.jpg',
  ),

  // Page 2
  Song(
    id: 'vFL4IlAt',
    title: 'Teenage Dream',
    artist: 'Katy Perry',
    album: 'Teenage Dream',
    artwork:
        'https://c.saavncdn.com/349/Love-Songs-2010s-English-2026-20260923163739-500x500.jpg',
  ),
  Song(
    id: 'hY3DnlHM',
    title: 'Boulevard of Broken Dreams',
    artist: 'Green Day',
    album: 'American Idiot',
    artwork:
        'https://c.saavncdn.com/891/Boulevard-of-Broken-Dreams-English-2009-20190607050628-500x500.jpg',
  ),
  Song(
    id: 'aNiYDMgM',
    title: 'Rather Be',
    artist: 'Clean Bandit',
    album: 'New Eyes',
    artwork:
        'https://c.saavncdn.com/636/Rather-Be-feat-Jess-Glynne--English-2014-20190607044522-500x500.jpg',
  ),
  Song(
    id: 'V25xkriv',
    title: 'Earned It',
    artist: 'The Weeknd',
    album: 'Fifty Shades of Grey',
    artwork:
        'https://c.saavncdn.com/396/The-Highlights-English-2021-20240207045714-500x500.jpg',
  ),
  Song(
    id: 'ddiNyJMU',
    title: 'Counting Stars',
    artist: 'OneRepublic',
    album: 'Native',
    artwork:
        'https://c.saavncdn.com/574/Native-English-2014-20250626055252-500x500.jpg',
  ),
  Song(
    id: 'd0gj_v_e',
    title: 'Riptide',
    artist: 'Vance Joy',
    album: 'Dream Your Life Away',
    artwork:
        'https://c.saavncdn.com/653/Dream-Your-Life-Away-English-2014-20190607044515-500x500.jpg',
  ),
  Song(
    id: 'qlZqBC5n',
    title: 'The Nights',
    artist: 'Avicii',
    album: 'The Days / Nights',
    artwork:
        'https://c.saavncdn.com/148/2014-Vibes-English-2026-20260605203017-500x500.jpg',
  ),
  Song(
    id: 'cst2LxFR',
    title: 'Without Me',
    artist: 'Eminem',
    album: 'The Eminem Show',
    artwork:
        'https://c.saavncdn.com/020/The-Eminem-Show-Unknown-2007-20250826100622-500x500.jpg',
  ),
  Song(
    id: 'XJ2N9gez',
    title: 'Payphone',
    artist: 'Maroon 5',
    album: 'Overexposed',
    artwork:
        'https://c.saavncdn.com/057/Payphone-2012-500x500.jpg',
  ),

  // Page 3
  Song(
    id: '3g5G9QTu',
    title: 'Demons',
    artist: 'Imagine Dragons',
    album: 'Night Visions',
    artwork:
        'https://c.saavncdn.com/210/Night-Visions-2013-500x500.jpg',
  ),
  Song(
    id: 'sG5akHmg',
    title: 'Stolen Dance',
    artist: 'Milky Chance',
    album: 'Sadnecessary',
    artwork:
        'https://c.saavncdn.com/160/Sadnecessary-English-2013-20220204225002-500x500.jpg',
  ),
  Song(
    id: 'AbFGQGPX',
    title: 'Stay With Me',
    artist: 'Sam Smith',
    album: 'In the Lonely Hour',
    artwork:
        'https://c.saavncdn.com/722/In-The-Lonely-Hour-English-2014-500x500.jpg',
  ),
  Song(
    id: 'Ppq9UTh8',
    title: 'Radioactive',
    artist: 'Imagine Dragons',
    album: 'Night Visions',
    artwork:
        'https://c.saavncdn.com/039/Radioactive-2014-500x500.jpg',
  ),
  Song(
    id: '7Q9IVoty',
    title: 'Pompeii',
    artist: 'Bastille',
    album: 'Bad Blood',
    artwork:
        'https://c.saavncdn.com/077/Best-Safe-for-Work-Songs-English-2026-20260914164525-500x500.jpg',
  ),
  Song(
    id: 'jgURVd6V',
    title: 'Wake Me Up',
    artist: 'Avicii',
    album: 'True',
    artwork:
        'https://c.saavncdn.com/466/Sport-Motivation-Booster-High-Energy-English-2026-20260605184016-500x500.jpg',
  ),
  Song(
    id: 'u3b2we7c',
    title: 'Somebody That I Used to Know',
    artist: 'Gotye ft. Kimbra',
    album: 'Making Mirrors',
    artwork:
        'https://c.saavncdn.com/856/Somebody-That-I-Used-To-Know-Remixes-2012-500x500.jpg',
  ),
  Song(
    id: 'Vfs5WLX-',
    title: 'Locked Out of Heaven',
    artist: 'Bruno Mars',
    album: 'Unorthodox Jukebox',
    artwork:
        'https://c.saavncdn.com/856/Locked-Out-Of-Heaven-English-2012-500x500.jpg',
  ),
  Song(
    id: 'eCaKjCac',
    title: 'Midnight City',
    artist: 'M83',
    album: "Hurry Up, We're Dreaming",
    artwork:
        'https://c.saavncdn.com/647/Hurry-up-We-re-Dreaming-English-2011-500x500.jpg',
  ),
];

final _trendingSongs = <Song>[
  Song(
    id: 'kd8JSDbB',
    title: 'STAY',
    artist: 'The Kid LAROI, Justin Bieber',
    album: 'STAY',
    artwork:
        'https://c.saavncdn.com/895/Stay-English-2021-20210706223809-500x500.jpg',
  ),
  Song(
    id: 'W8wYUcCq',
    title: 'Bad Habits',
    artist: 'Ed Sheeran',
    album: 'Bad Habits',
    artwork:
        'https://c.saavncdn.com/316/Bad-Habits-English-2021-20211022044755-500x500.jpg',
  ),
  Song(
    id: 'BhKP6P-H',
    title: 'Espresso',
    artist: 'Sabrina Carpenter',
    album: 'Espresso',
    artwork:
        'https://c.saavncdn.com/111/Espresso-English-2024-20240412064803-500x500.jpg',
  ),
  Song(
    id: 'ID-tpbGP',
    title: 'People',
    artist: 'Libianca',
    album: 'People',
    artwork:
        'https://c.saavncdn.com/607/People-English-2022-20221207081653-500x500.jpg',
  ),
  Song(
    id: 'Plabk03R',
    title: 'Unholy',
    artist: 'Sam Smith, Kim Petras',
    album: 'Gloria',
    artwork:
        'https://c.saavncdn.com/041/Gloria-English-2023-20231116192310-500x500.jpg',
  ),
  Song(
    id: 'pDKPIf7z',
    title: 'Loser',
    artist: 'Charlie Puth',
    album: 'CHARLIE',
    artwork:
        'https://c.saavncdn.com/589/CHARLIE-English-2022-20221005173517-500x500.jpg',
  ),
];

final _suggestedSongs = <Song>[
  Song(
    id: '1xqHQw3J',
    title: 'Faded',
    artist: 'Alan Walker',
    album: 'Faded',
    artwork:
        'https://c.saavncdn.com/981/Faded-English-2015-20260508161540-500x500.jpg',
  ),
  Song(
    id: '2YCl6FD8',
    title: 'On The Floor',
    artist: 'Jennifer Lopez, Pitbull',
    album: 'LOVE?',
    artwork:
        'https://c.saavncdn.com/343/LOVE-English-2011-20260522055435-500x500.jpg',
  ),
  Song(
    id: 'OPIPEsPe',
    title: 'Bad Boy',
    artist: 'Tungevaag, Raaban',
    album: 'Bad Boy',
    artwork:
        'https://c.saavncdn.com/509/Bad-Boy-feat-Luana-Kiara--English-2018-20190607042030-500x500.jpg',
  ),
  Song(
    id: '9LuvX9pB',
    title: 'Love Me Like You Do',
    artist: 'Ellie Goulding',
    album: 'Fifty Shades Freed',
    artwork:
        'https://c.saavncdn.com/756/Fifty-Shades-Freed-English-2018-20180208000209-500x500.jpg',
  ),
  Song(
    id: 'o1qyko3N',
    title: 'Peaches',
    artist: 'Justin Bieber',
    album: 'Justice',
    artwork:
        'https://c.saavncdn.com/983/Justice-English-2021-20210325102906-500x500.jpg',
  ),
  Song(
    id: 'Oc72uyuq',
    title: 'Yummy',
    artist: 'Justin Bieber',
    album: 'Yummy',
    artwork:
        'https://c.saavncdn.com/522/Yummy-English-2020-20200103035142-500x500.jpg',
  ),
  Song(
    id: 'p5TDxRD9',
    title: 'Gangnam Style',
    artist: 'PSY',
    album: 'Gangnam Style (강남스타일)',
    artwork:
        'https://c.saavncdn.com/032/Gangnam-Style--English-2012-20200421073139-500x500.jpg',
  ),
];

final _mostPlayedSongs = <Song>[
  Song(
    id: 'j8hvJDPs',
    title: 'Let Me Love You',
    artist: 'DJ Snake, Justin Bieber',
    album: 'Encore',
    artwork:
        'https://c.saavncdn.com/273/Encore-English-2016-20190419221937-500x500.jpg',
  ),
  Song(
    id: 'pizXlfUB',
    title: 'Blinding Lights',
    artist: 'The Weeknd',
    album: 'The Highlights',
    artwork:
        'https://c.saavncdn.com/396/The-Highlights-English-2021-20240207045714-500x500.jpg',
  ),
  Song(
    id: '1xqHQw3J',
    title: 'Faded',
    artist: 'Alan Walker',
    album: 'Faded',
    artwork:
        'https://c.saavncdn.com/981/Faded-English-2015-20260508161540-500x500.jpg',
  ),
  Song(
    id: 'xKlnh38y',
    title: 'One Dance',
    artist: 'Drake',
    album: 'Views',
    artwork:
        'https://c.saavncdn.com/521/Views-English-2016-20240201113111-500x500.jpg',
  ),
  Song(
    id: 'Hvma-gqd',
    title: 'Safari',
    artist: 'Serena',
    album: 'Safari',
    artwork:
        'https://c.saavncdn.com/292/Safari-English-2017-20240919033905-500x500.jpg',
  ),
  Song(
    id: 'NJ_W1AG6',
    title: 'On My Way',
    artist: 'Alan Walker, Sabrina Carpenter, Farruko',
    album: 'On My Way',
    artwork:
        'https://c.saavncdn.com/866/On-My-Way-English-2019-20190308195918-500x500.jpg',
  ),
];

final _topHitsSongs = <Song>[
  Song(
    id: 'vQ8QjgoY',
    title: 'Intentions',
    artist: 'Justin Bieber, Quavo',
    album: 'Intentions',
    artwork:
        'https://c.saavncdn.com/294/Intentions-English-2020-20200207033302-500x500.jpg',
  ),
  Song(
    id: 'Oc72uyuq',
    title: 'Yummy',
    artist: 'Justin Bieber',
    album: 'Yummy',
    artwork:
        'https://c.saavncdn.com/522/Yummy-English-2020-20200103035142-500x500.jpg',
  ),
  Song(
    id: 'Rl5YltJX',
    title: 'Headlights',
    artist: 'Alok, Alan Walker, KIDDO',
    album: 'Headlights',
    artwork:
        'https://c.saavncdn.com/723/Headlights-feat-KIDDO--English-2022-20220215120150-500x500.jpg',
  ),
  Song(
    id: 'C9_s3NUf',
    title: 'Stuck with U',
    artist: 'Ariana Grande, Justin Bieber',
    album: 'Stuck with U',
    artwork:
        'https://c.saavncdn.com/307/Stuck-with-U-English-2020-20200508041707-500x500.jpg',
  ),
  Song(
    id: 'DOldeDpy',
    title: 'Dai Dai',
    artist: 'Shakira, Burna Boy',
    album: 'Dai Dai',
    artwork:
        'https://c.saavncdn.com/037/Dai-Dai-English-2026-20260807003044-500x500.jpg',
  ),
  Song(
    id: 'iWt8op78',
    title: 'Cheap Thrills',
    artist: 'Sia',
    album: 'This Is Acting',
    artwork:
        'https://c.saavncdn.com/203/This-Is-Acting-English-2016-500x500.jpg',
  ),
];


final _featuredPlaylists = <Playlist>[
  Playlist(
    id: '90522027',
    title: 'Alan Walker',
    description: 'Electronic anthems and chart-topping hits.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayAlanWalker_20241122142442_500x500.jpg',
    songCount: 30,
  ),
  Playlist(
    id: '84989841',
    title: 'Ariana Grande',
    description: 'Essential pop and R&B hits by Ariana Grande.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayArianaGrande_20250312064753_500x500.jpg',
    songCount: 30,
  ),
  Playlist(
    id: '791714467',
    title: 'Sabrina Carpenter',
    description: 'Top tracks and viral pop sensations.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlaySabrinaCarpenter_20250312064201_500x500.jpg',
    songCount: 25,
  ),
  Playlist(
    id: '81580124',
    title: 'Ed Sheeran',
    description: 'Acoustic favorites and global records.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayEdSheeran_20250513105854_500x500.jpg',
    songCount: 30,
  ),
  Playlist(
    id: '81134817',
    title: 'Shakira',
    description: 'Latin pop powerhouses and global anthems.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayShakira_20260203052437_500x500.jpg',
    songCount: 30,
  ),
  Playlist(
    id: '52312344',
    title: 'Justin Bieber',
    description: 'Unforgettable pop and R&B classics.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayJustinBieber_20241122142527_500x500.jpg',
    songCount: 30,
  ),
];

final _hindiSpeedDialSongs = <Song>[
  // Page 1
  Song(
    id: 'rjkrTnma',
    title: 'Kesariya',
    artist: 'Pritam',
    album: 'Brahmastra',
    artwork:
        'https://c.saavncdn.com/871/Brahmastra-Original-Motion-Picture-Soundtrack-Hindi-2022-20221006155213-500x500.jpg',
  ),
  Song(
    id: 'aRZbUYD7',
    title: 'Tum Hi Ho',
    artist: 'Mithoon',
    album: 'Aashiqui 2',
    artwork: 'https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-500x500.jpg',
  ),
  Song(
    id: 'mPTrDSun',
    title: 'Raataan Lambiyan',
    artist: 'Tanishk Bagchi',
    album: 'Shershaah',
    artwork:
        'https://c.saavncdn.com/238/Shershaah-Original-Motion-Picture-Soundtrack--Hindi-2021-20210815181610-500x500.jpg',
  ),
  Song(
    id: 'koWi7GRH',
    title: 'Apna Bana Le',
    artist: 'Amitabh Bhattacharya',
    album: 'Bhediya',
    artwork:
        'https://c.saavncdn.com/228/Sachin-Jigar-Bollywood-Hits-Hindi-2026-20260630213800-500x500.jpg',
  ),
  Song(
    id: 'yDnFw7my',
    title: 'Chaleya',
    artist: 'Anirudh Ravichander',
    album: 'Jawan',
    artwork:
        'https://c.saavncdn.com/179/World-Music-Day-Best-Of-Bollywood-Hits-Hindi-2026-20260622111029-500x500.jpg',
  ),
  Song(
    id: 'rBltEr7X',
    title: 'Tere Vaaste',
    artist: 'Amitabh Bhattacharya',
    album: 'Zara Hatke Zara Bachke',
    artwork:
        'https://c.saavncdn.com/336/Zara-Hatke-Zara-Bachke-Hindi-2023-20250129153124-500x500.jpg',
  ),
  Song(
    id: '_rJmbKSP',
    title: 'Shayad',
    artist: 'Pritam',
    album: 'Love Aaj Kal',
    artwork:
        'https://c.saavncdn.com/862/Love-Aaj-Kal-Hindi-2020-20200214140423-500x500.jpg',
  ),
  Song(
    id: 'RgLLRnht',
    title: 'Dil Diyan Gallan',
    artist: 'Atif Aslam',
    album: 'Tiger Zinda Hai',
    artwork:
        'https://c.saavncdn.com/893/Dil-Diyan-Gallan-From-Carry-On-Jatta-4-Punjabi-2026-20260520103640-500x500.jpg',
  ),
  Song(
    id: 'TfJX33Qk',
    title: 'Kal Ho Naa Ho',
    artist: 'Shankar-Ehsaan-Loy',
    album: 'Kal Ho Naa Ho',
    artwork:
        'https://c.saavncdn.com/587/Kal-Ho-Naa-Ho-Hindi-2003-20190516130956-500x500.jpg',
  ),

  // Page 2
  Song(
    id: 'AYHP28Sh',
    title: 'Phir Aur Kya Chahiye',
    artist: 'Amitabh Bhattacharya',
    album: 'Zara Hatke Zara Bachke',
    artwork:
        'https://c.saavncdn.com/336/Zara-Hatke-Zara-Bachke-Hindi-2023-20250129153124-500x500.jpg',
  ),
  Song(
    id: 'wcsDiSsA',
    title: 'O Maahi',
    artist: 'Pritam',
    album: 'Dunki',
    artwork:
        'https://c.saavncdn.com/139/Dunki-Hindi-2023-20231220211003-500x500.jpg',
  ),
  Song(
    id: 'Ni6noMmw',
    title: 'Agar Tum Saath Ho',
    artist: 'Alka Yagnik',
    album: 'Tamasha',
    artwork:
        'https://c.saavncdn.com/994/Tamasha-Hindi-2015-500x500.jpg',
  ),
  Song(
    id: 'uiEWT3kP',
    title: 'Channa Mereya',
    artist: 'Pritam',
    album: 'Ae Dil Hai Mushkil',
    artwork:
        'https://c.saavncdn.com/257/Ae-Dil-Hai-Mushkil-Hindi-2016-500x500.jpg',
  ),
  Song(
    id: 'NIidiD9g',
    title: 'Heeriye',
    artist: 'Jasleen Royal, Arijit Singh',
    album: 'Heeriye',
    artwork:
        'https://c.saavncdn.com/022/Heeriye-feat-Arijit-Singh-Hindi-2023-20230928050405-500x500.jpg',
  ),
  Song(
    id: 'OtKh5C06',
    title: 'Bekhayali',
    artist: 'Sachet Tandon',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: '4NRpZd1v',
    title: 'Hawayein',
    artist: 'Pritam',
    album: 'Jab Harry Met Sejal',
    artwork:
        'https://c.saavncdn.com/584/Jab-Harry-Met-Sejal-Hindi-2017-20170803161007-500x500.jpg',
  ),
  Song(
    id: '05BTlVwi',
    title: 'Tere Hawaale',
    artist: 'Amitabh Bhattacharya',
    album: 'Laal Singh Chaddha',
    artwork:
        'https://c.saavncdn.com/179/World-Music-Day-Best-Of-Bollywood-Hits-Hindi-2026-20260622111029-500x500.jpg',
  ),
  Song(
    id: '4CI_0bzt',
    title: 'Ilahi',
    artist: 'Pritam',
    album: 'Yeh Jawaani Hai Deewani',
    artwork:
        'https://c.saavncdn.com/440/Yeh-Jawaani-Hai-Deewani-2013-500x500.jpg',
  ),

  // Page 3
  Song(
    id: 'LXTWWvvX',
    title: 'Subhanallah',
    artist: 'Pritam',
    album: 'Yeh Jawaani Hai Deewani',
    artwork:
        'https://c.saavncdn.com/440/Yeh-Jawaani-Hai-Deewani-2013-500x500.jpg',
  ),
  Song(
    id: 'oqSP8nSu',
    title: 'Zaalima',
    artist: 'Arijit Singh',
    album: 'Raees',
    artwork:
        'https://c.saavncdn.com/238/Romantic-Classics-Hits-Hindi-2026-20260529163838-500x500.jpg',
  ),
  Song(
    id: 'Nu9ulzC7',
    title: 'Kun Faya Kun',
    artist: 'A.R. Rahman',
    album: 'Rockstar',
    artwork:
        'https://c.saavncdn.com/333/A-R-Rahman-Special-Hindi-2025-20250429141118-500x500.jpg',
  ),
  Song(
    id: '1e0En7YX',
    title: 'Pehle Bhi Main',
    artist: 'Vishal Mishra',
    album: 'ANIMAL',
    artwork:
        'https://c.saavncdn.com/092/ANIMAL-Hindi-2023-20260724191152-500x500.jpg',
  ),
  Song(
    id: 'LU5-HHC1',
    title: 'Satranga',
    artist: 'Arijit Singh',
    album: 'ANIMAL',
    artwork:
        'https://c.saavncdn.com/179/World-Music-Day-Best-Of-Bollywood-Hits-Hindi-2026-20260622111029-500x500.jpg',
  ),
  Song(
    id: 'Ke9TPSUf',
    title: 'Tujhe Kitna Chahne Lage',
    artist: 'Arijit Singh',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: 'xJZBjDck',
    title: 'Raabta',
    artist: 'Arijit Singh',
    album: 'Agent Vinod',
    artwork:
        'https://c.saavncdn.com/840/Best-Of-Arijit-Singh-Collection-Of-Romantic-Songs-Hindi-2025-20251203161112-500x500.jpg',
  ),
  Song(
    id: 'uf2JX_12',
    title: 'Tera Ban Jaunga',
    artist: 'Akhil Sachdeva',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: 'st2Dycrf',
    title: 'Gerua',
    artist: 'Pritam',
    album: 'Dilwale',
    artwork:
        'https://c.saavncdn.com/297/Dilwale-Hindi-2015-20260120201359-500x500.jpg',
  ),
];

final _hindiTrendingSongs = <Song>[
  Song(
    id: 'faloMmjX',
    title: 'Chaleya',
    artist: 'Anirudh Ravichander',
    album: 'Jawan',
    artwork:
        'https://c.saavncdn.com/047/Jawan-Hindi-2023-20230921190854-500x500.jpg',
  ),
  Song(
    id: 'koWi7GRH',
    title: 'Apna Bana Le',
    artist: 'Amitabh Bhattacharya',
    album: 'Bhediya',
    artwork:
        'https://c.saavncdn.com/228/Sachin-Jigar-Bollywood-Hits-Hindi-2026-20260630213800-500x500.jpg',
  ),
  Song(
    id: 'rBltEr7X',
    title: 'Tere Vaaste',
    artist: 'Amitabh Bhattacharya',
    album: 'Zara Hatke Zara Bachke',
    artwork:
        'https://c.saavncdn.com/336/Zara-Hatke-Zara-Bachke-Hindi-2023-20250129153124-500x500.jpg',
  ),
  Song(
    id: '4mHUvJ4u',
    title: 'Satranga',
    artist: 'Arijit Singh',
    album: 'ANIMAL',
    artwork:
        'https://c.saavncdn.com/092/ANIMAL-Hindi-2023-20260724191152-500x500.jpg',
  ),
  Song(
    id: 'wcsDiSsA',
    title: 'O Maahi',
    artist: 'Pritam',
    album: 'Dunki',
    artwork:
        'https://c.saavncdn.com/139/Dunki-Hindi-2023-20231220211003-500x500.jpg',
  ),
  Song(
    id: 'NIidiD9g',
    title: 'Heeriye',
    artist: 'Jasleen Royal, Arijit Singh',
    album: 'Heeriye',
    artwork:
        'https://c.saavncdn.com/022/Heeriye-feat-Arijit-Singh-Hindi-2023-20230928050405-500x500.jpg',
  ),
];

final _hindiSuggestedSongs = <Song>[
  Song(
    id: 'rjkrTnma',
    title: 'Kesariya',
    artist: 'Pritam',
    album: 'Brahmastra',
    artwork:
        'https://c.saavncdn.com/871/Brahmastra-Original-Motion-Picture-Soundtrack-Hindi-2022-20221006155213-500x500.jpg',
  ),
  Song(
    id: 'aRZbUYD7',
    title: 'Tum Hi Ho',
    artist: 'Mithoon',
    album: 'Aashiqui 2',
    artwork: 'https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-500x500.jpg',
  ),
  Song(
    id: 'mPTrDSun',
    title: 'Raataan Lambiyan',
    artist: 'Tanishk Bagchi',
    album: 'Shershaah',
    artwork:
        'https://c.saavncdn.com/238/Shershaah-Original-Motion-Picture-Soundtrack--Hindi-2021-20210815181610-500x500.jpg',
  ),
  Song(
    id: '_rJmbKSP',
    title: 'Shayad',
    artist: 'Pritam',
    album: 'Love Aaj Kal',
    artwork:
        'https://c.saavncdn.com/862/Love-Aaj-Kal-Hindi-2020-20200214140423-500x500.jpg',
  ),
  Song(
    id: 'Ni6noMmw',
    title: 'Agar Tum Saath Ho',
    artist: 'Alka Yagnik',
    album: 'Tamasha',
    artwork:
        'https://c.saavncdn.com/994/Tamasha-Hindi-2015-500x500.jpg',
  ),
  Song(
    id: 'TfJX33Qk',
    title: 'Kal Ho Naa Ho',
    artist: 'Shankar-Ehsaan-Loy',
    album: 'Kal Ho Naa Ho',
    artwork:
        'https://c.saavncdn.com/587/Kal-Ho-Naa-Ho-Hindi-2003-20190516130956-500x500.jpg',
  ),
  Song(
    id: '4NRpZd1v',
    title: 'Hawayein',
    artist: 'Pritam',
    album: 'Jab Harry Met Sejal',
    artwork:
        'https://c.saavncdn.com/584/Jab-Harry-Met-Sejal-Hindi-2017-20170803161007-500x500.jpg',
  ),
];

final _hindiMostPlayedSongs = <Song>[
  Song(
    id: 'uiEWT3kP',
    title: 'Channa Mereya',
    artist: 'Pritam',
    album: 'Ae Dil Hai Mushkil',
    artwork:
        'https://c.saavncdn.com/257/Ae-Dil-Hai-Mushkil-Hindi-2016-500x500.jpg',
  ),
  Song(
    id: 'OtKh5C06',
    title: 'Bekhayali',
    artist: 'Sachet Tandon',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: '1e0En7YX',
    title: 'Pehle Bhi Main',
    artist: 'Vishal Mishra',
    album: 'ANIMAL',
    artwork:
        'https://c.saavncdn.com/092/ANIMAL-Hindi-2023-20260724191152-500x500.jpg',
  ),
  Song(
    id: 'Ke9TPSUf',
    title: 'Tujhe Kitna Chahne Lage',
    artist: 'Arijit Singh',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: '4CI_0bzt',
    title: 'Ilahi',
    artist: 'Pritam',
    album: 'Yeh Jawaani Hai Deewani',
    artwork:
        'https://c.saavncdn.com/440/Yeh-Jawaani-Hai-Deewani-2013-500x500.jpg',
  ),
  Song(
    id: 'RgLLRnht',
    title: 'Dil Diyan Gallan',
    artist: 'Atif Aslam',
    album: 'Tiger Zinda Hai',
    artwork:
        'https://c.saavncdn.com/893/Dil-Diyan-Gallan-From-Carry-On-Jatta-4-Punjabi-2026-20260520103640-500x500.jpg',
  ),
];

final _hindiTopHitsSongs = <Song>[
  Song(
    id: 'LXTWWvvX',
    title: 'Subhanallah',
    artist: 'Pritam',
    album: 'Yeh Jawaani Hai Deewani',
    artwork:
        'https://c.saavncdn.com/440/Yeh-Jawaani-Hai-Deewani-2013-500x500.jpg',
  ),
  Song(
    id: 'Ra9F5rTD',
    title: 'Zaalima',
    artist: 'Arijit Singh',
    album: 'Raees',
    artwork:
        'https://c.saavncdn.com/334/Raees-Hindi-2016-20200430093124-500x500.jpg',
  ),
  Song(
    id: 'csaEsVWV',
    title: 'Kun Faaya Kun',
    artist: 'A.R. Rahman',
    album: 'Rockstar',
    artwork:
        'https://c.saavncdn.com/408/Rockstar-Hindi-2011-20221212023139-500x500.jpg',
  ),
  Song(
    id: 'Wn_eONzu',
    title: 'Raabta',
    artist: 'Pritam',
    album: 'Agent Vinod',
    artwork:
        'https://c.saavncdn.com/603/Agent-Vinod-2012-500x500.jpg',
  ),
  Song(
    id: 'uf2JX_12',
    title: 'Tera Ban Jaunga',
    artist: 'Akhil Sachdeva',
    album: 'Kabir Singh',
    artwork:
        'https://c.saavncdn.com/807/Kabir-Singh-Hindi-2019-20240131131003-500x500.jpg',
  ),
  Song(
    id: 'st2Dycrf',
    title: 'Gerua',
    artist: 'Pritam',
    album: 'Dilwale',
    artwork:
        'https://c.saavncdn.com/297/Dilwale-Hindi-2015-20260120201359-500x500.jpg',
  ),
];

final _hindiFeaturedPlaylists = <Playlist>[
  Playlist(
    id: '1191141029',
    title: 'Arijit Singh',
    description: 'King of modern Bollywood romance and melodies.',
    artwork:
        'https://c.saavncdn.com/editorial/BestofRomanceArijitSingh_20231005095622_500x500.jpg',
    songCount: 56,
  ),
  Playlist(
    id: '5519117',
    title: 'A.R. Rahman',
    description: 'Masterpieces by the Mozart of Madras.',
    artwork:
        'https://c.saavncdn.com/editorial/Let_sPlayA-R-RahmanHindi_20240531054747_500x500.jpg',
    songCount: 50,
  ),
  Playlist(
    id: '902531265',
    title: 'Shreya Ghoshal',
    description: 'Soulful melodies and timeless classics.',
    artwork:
        'https://c.saavncdn.com/editorial/ShreyaGhoshalLoveSongsHindi_20240730105308_500x500.jpg',
    songCount: 33,
  ),
  Playlist(
    id: '109717418',
    title: 'Pritam',
    description: 'Chart-topping Bollywood anthems.',
    artwork:
        'https://c.saavncdn.com/editorial/LetsPlayPritamArijit_20250109115337_500x500.jpg',
    songCount: 29,
  ),
  Playlist(
    id: '905269229',
    title: 'Sonu Nigam',
    description: 'Golden voice of iconic Bollywood hits.',
    artwork:
        'https://c.saavncdn.com/editorial/SonuNigamLoveSongsHindi_20240318054814_500x500.jpg',
    songCount: 32,
  ),
  Playlist(
    id: '154546814',
    title: '90s Romance',
    description: 'Timeless love anthems and nostalgic 90s magic.',
    artwork:
        'https://c.saavncdn.com/editorial/90sRomanceHindi_20260302042658_500x500.jpg',
    songCount: 40,
  ),
];


late final SonixAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init(
    builder: () => SonixAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          'com.example.song_player_mobile.channel.audio',
      androidNotificationChannelName: 'Sonix Music Playback',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidShowNotificationBadge: true,
      androidStopForegroundOnPause: true,
    ),
  );
  runApp(const SonixApp());
}

class SonixApp extends StatefulWidget {
  const SonixApp({super.key});

  @override
  State<SonixApp> createState() => _SonixAppState();
}

class _SonixAppState extends State<SonixApp> {
  bool _checkedOnboarding = false;
  bool _isOnboarded = false;
  UserProfile? _userProfile;
  String _themeMode = AppConstants.defaultTheme;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final theme = await UserStorage.getThemeMode();
    final done = await UserStorage.isOnboardingComplete();
    UserProfile? profile;
    if (done) {
      profile = await UserStorage.getProfile();
    }
    if (mounted) {
      setState(() {
        _themeMode = theme;
        _isOnboarded = done;
        _userProfile = profile;
        _checkedOnboarding = true;
      });
    }
  }

  void _onComplete(UserProfile profile) {
    setState(() {
      _userProfile = profile;
      _isOnboarded = true;
    });
  }

  void _onThemeChanged(String mode) {
    setState(() => _themeMode = mode);
    UserStorage.saveThemeMode(mode);
  }

  ThemeMode get _effectiveThemeMode {
    if (_themeMode == 'light') return ThemeMode.light;
    if (_themeMode == 'dark') return ThemeMode.dark;
    return ThemeMode.system;
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppConstants.colorLightBackground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff0f172a),
        brightness: Brightness.light,
        surface: AppConstants.colorLightSurface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xff0f172a),
        elevation: 0,
      ),
      cardColor: AppConstants.colorLightSurface,
      dividerColor: const Color(0x14000000),
      iconTheme: const IconThemeData(color: Color(0xff334155)),
      textTheme: GoogleFonts.manropeTextTheme(
        ThemeData(brightness: Brightness.light).textTheme.apply(
          bodyColor: const Color(0xff0f172a),
          displayColor: const Color(0xff0f172a),
        ),
      ),
      fontFamily: GoogleFonts.manrope().fontFamily,
    );

    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.white,
        brightness: Brightness.dark,
        surface: _surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xee080808),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardColor: _surface,
      dividerColor: Colors.white12,
      iconTheme: const IconThemeData(color: Colors.white),
      textTheme: GoogleFonts.manropeTextTheme(
        ThemeData(brightness: Brightness.dark).textTheme,
      ),
      fontFamily: GoogleFonts.manrope().fontFamily,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sonix',
      themeMode: _effectiveThemeMode,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: !_checkedOnboarding
          ? Scaffold(
              backgroundColor: _effectiveThemeMode == ThemeMode.light
                  ? AppConstants.colorLightBackground
                  : _ink,
              body: Center(
                child: CircularProgressIndicator(
                  color: _effectiveThemeMode == ThemeMode.light
                      ? const Color(0xff0f172a)
                      : Colors.white,
                ),
              ),
            )
          : (_isOnboarded
                ? SonixHome(
                    userProfile: _userProfile,
                    currentTheme: _themeMode,
                    onAppThemeChanged: _onThemeChanged,
                  )
                : OnboardingScreen(onComplete: _onComplete)),
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                    HOME                                    */
/* -------------------------------------------------------------------------- */

class SonixHome extends StatefulWidget {
  const SonixHome({
    super.key,
    this.userProfile,
    this.currentTheme,
    this.onAppThemeChanged,
  });

  final UserProfile? userProfile;
  final String? currentTheme;
  final ValueChanged<String>? onAppThemeChanged;

  @override
  State<SonixHome> createState() => _SonixHomeState();
}

class _SonixHomeState extends State<SonixHome> with TickerProviderStateMixin {
  UserProfile? _userProfile;
  final _search = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<SearchSuggestion> _searchSuggestions = [];
  bool _loadingSuggestions = false;
  Timer? _searchDebounceTimer;
  bool _fullSearchSubmitted = false;
  List<String> _recentSearches = [];
  late final CrossfadePlayer _audio;
  late final AnimationController _gradientAnim;
  late final AnimationController _queueAnim;

  List<Artist> _artistResults = [];
  List<Song> _results = [];
  List<Album> _albumResults = [];
  List<Playlist> _playlistResults = [];
  List<Song> _history = [];
  final List<Song> _playbackHistory = [];
  int _playbackHistoryIndex = -1;
  bool _isNavigatingHistory = false;

  // ---- Queue / playback mode state ----
  PlaybackMode _playbackMode = PlaybackMode.suggestions;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  bool _isShuffle = false;
  List<Song> _unshuffledPlaylist = [];
  List<Song> _suggestionQueue = [];   // holds 15 suggestions at a time
  List<Song> _playlistQueue = [];     // all songs for playlist repeat
  int _playlistQueueIndex = -1;       // current index inside _playlistQueue
  bool _isFetchingSuggestions = false; // guard concurrent fetches
  Song? _preparedSong;
  String? _preparedStreamUrl;

  Map<String, Song> _likedSongs = {};
  bool _viewingLikedSongs = false;
  List<Song> _offlineSongs = [];
  bool _viewingOfflineSongs = false;
  bool _isScanningOffline = false;
  String _songQuality = '320kbps';
  String _themeMode = AppConstants.defaultTheme;
  String _musicLanguage = 'English';
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;
  bool _eqEnabled = false;
  String _eqPreset = 'Flat';
  List<double> _eqBands = [0.0, 0.0, 0.0, 0.0, 0.0];
  double _eqBassBoost = 0.0;
  late final PageController _speedDialPageCtrl;
  int _speedDialPage = 0;
  late final PageController _fullScreenPageCtrl;
  double _fsVerticalDragDist = 0.0;

  bool get _isHindi => _musicLanguage.toLowerCase() == 'hindi';
  List<Song> get _effectiveSpeedDialSongs =>
      _isHindi ? _hindiSpeedDialSongs : _speedDialSongs;
  List<Song> get _effectiveTrendingSongs =>
      _isHindi ? _hindiTrendingSongs : _trendingSongs;
  List<Song> get _effectiveSuggestedSongs =>
      _isHindi ? _hindiSuggestedSongs : _suggestedSongs;
  List<Song> get _effectiveMostPlayedSongs =>
      _isHindi ? _hindiMostPlayedSongs : _mostPlayedSongs;
  List<Song> get _effectiveTopHitsSongs =>
      _isHindi ? _hindiTopHitsSongs : _topHitsSongs;
  List<Playlist> get _effectiveFeaturedPlaylists =>
      _isHindi ? _hindiFeaturedPlaylists : _featuredPlaylists;

  bool get _isLight => Theme.of(context).brightness == Brightness.light;
  Color get _bg =>
      _isLight ? AppConstants.colorLightBackground : AppConstants.colorInk;
  Color get _cardBg =>
      _isLight ? AppConstants.colorLightSurface : AppConstants.colorSurface;
  Color get _sheetBg =>
      _isLight ? AppConstants.colorSheetLight : AppConstants.colorSheetDark;
  Color get _headerBg =>
      _isLight ? AppConstants.colorHeaderLight : AppConstants.colorHeaderDark;
  Color get _textColor =>
      _isLight ? AppConstants.colorTextLight : AppConstants.colorTextDark;
  Color get _subtextColor =>
      _isLight ? AppConstants.colorSubtextLight : AppConstants.colorSubtextDark;
  Color get _borderColor =>
      _isLight ? AppConstants.colorBorderLight : AppConstants.colorBorderDark;
  Color get _dividerColor =>
      _isLight ? AppConstants.colorDividerLight : AppConstants.colorDividerDark;
  Color get _inputFill =>
      _isLight ? AppConstants.colorInputFillLight : AppConstants.colorInputFillDark;

  Playlist? _openedPlaylist;
  bool _loadingPlaylist = false;

  Song? _current;
  bool _searching = false;
  bool _homeMode = true;
  bool _noticeVisible = true;
  bool _fullScreen = false;
  bool _fullScreenLyrics = false;
  bool _lyricsOpen = false;
  bool _isLoadingTrack = false;
  bool _isLoadingLyrics = false;
  int _playRequest = 0;

  Map<String, dynamic>? _lyrics;
  List<LyricLine> _parsedLyrics = [];

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<ProcessingState>? _processingStateSub;
  StreamSubscription<Duration>? _historyPositionSub;
  final Stopwatch _songPlayStopwatch = Stopwatch();
  bool _historyAddedForCurrent = false;
  final Map<String, Future<List<Color>>> _paletteFutures = {};

  @override
  void didUpdateWidget(covariant SonixHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentTheme != null &&
        widget.currentTheme != oldWidget.currentTheme) {
      _themeMode = widget.currentTheme!;
    }
  }

  @override
  void initState() {
    super.initState();
    _themeMode = widget.currentTheme ?? AppConstants.defaultTheme;
    _audio = audioHandler.player;
    audioHandler.onSkipNext = _next;
    audioHandler.onSkipPrevious = _previous;
    _audio.onPrepareNextTrack = _onPrepareNextTrack;
    _audio.onAutoCrossfadeTriggered = _onCrossfadeTriggered;

    _userProfile = widget.userProfile;
    if (_userProfile != null && _userProfile!.language.isNotEmpty) {
      _musicLanguage = _userProfile!.language;
    }
    UserStorage.getLanguage().then((l) {
      if (mounted) setState(() => _musicLanguage = l);
    });
    if (_userProfile == null) {
      UserStorage.getProfile().then((p) {
        if (mounted && p != null) {
          setState(() {
            _userProfile = p;
            if (p.language.isNotEmpty) {
              _musicLanguage = p.language;
            }
          });
        }
      });
    }
    _loadLikedSongs();
    _loadOfflineSongs();
    _loadRecentSearches();
    _loadHistory();
    _loadEqualizer();
    UserStorage.getSongQuality().then((q) {
      if (mounted) setState(() => _songQuality = q);
    });
    UserStorage.getThemeMode().then((m) {
      if (mounted) setState(() => _themeMode = m);
    });
    UserStorage.getRepeatMode().then((modeStr) {
      if (!mounted) return;
      setState(() {
        switch (modeStr) {
          case 'all':
            _repeatMode = PlaybackRepeatMode.all;
            break;
          case 'one':
            _repeatMode = PlaybackRepeatMode.one;
            break;
          default:
            _repeatMode = PlaybackRepeatMode.off;
            break;
        }
      });
    });
    UserStorage.getShuffle().then((shuffled) {
      if (mounted) setState(() => _isShuffle = shuffled);
    });
    _gradientAnim = AnimationController(
      vsync: this,
      duration: const Duration(
          seconds: AppConstants.backgroundAnimationDurationSeconds),
    )..repeat(reverse: true);
    _queueAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _speedDialPageCtrl = PageController();
    _fullScreenPageCtrl = PageController();
    _search.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _playingSub = _audio.playingStream.listen((isPlaying) {
      if (isPlaying) {
        if (!_historyAddedForCurrent && _current != null) {
          _songPlayStopwatch.start();
        }
      } else {
        _songPlayStopwatch.stop();
      }
      if (mounted) setState(() {});
    });
    _historyPositionSub = _audio.positionStream.listen((pos) {
      if (!_historyAddedForCurrent && _current != null) {
        final elapsedMs = _songPlayStopwatch.elapsedMilliseconds;
        final dur = _audio.duration;
        final thresholdMs =
            AppConstants.minPlayDurationForHistorySeconds * 1000;
        final isShortTrack = dur != null &&
            dur.inSeconds > 0 &&
            dur.inSeconds < AppConstants.minPlayDurationForHistorySeconds;
        final thresholdMet = elapsedMs >= thresholdMs ||
            (isShortTrack && pos >= dur * 0.5);

        if (thresholdMet) {
          _historyAddedForCurrent = true;
          _onSongMeaningfullyPlayed(_current!);
          if (mounted) setState(() {});
        }
      }
    });
    // Detect song completion to auto-advance and update UI on state changes.
    _processingStateSub = _audio.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onSongCompleted();
      }
      if (mounted) setState(() {});
    });
  }

  void _onSearchFocusChanged() {
    if (_searchFocusNode.hasFocus && _homeMode) {
      setState(() {
        _homeMode = false;
        _fullSearchSubmitted = false;
      });
    }
  }

  Future<void> _loadRecentSearches() async {
    final list = await UserStorage.getRecentSearches();
    if (mounted) setState(() => _recentSearches = list);
  }

  void _onSearchChanged() {
    final query = _search.text.trim();
    if (query.isEmpty) {
      _searchDebounceTimer?.cancel();
      if (mounted) {
        setState(() {
          _searchSuggestions = [];
          _loadingSuggestions = false;
          _fullSearchSubmitted = false;
        });
      }
      return;
    }

    if (_homeMode) {
      setState(() {
        _homeMode = false;
        _fullSearchSubmitted = false;
      });
    } else if (_fullSearchSubmitted) {
      setState(() => _fullSearchSubmitted = false);
    }

    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      _fetchSearchSuggestions(query);
    });
  }

  Future<void> _fetchSearchSuggestions(String query) async {
    if (!mounted || query.isEmpty) return;
    setState(() => _loadingSuggestions = true);
    final suggestions = await Api.getSuggestions(query, limit: 16);
    if (!mounted || _search.text.trim() != query) return;
    setState(() {
      _searchSuggestions = suggestions;
      _loadingSuggestions = false;
    });
  }

  void _exitSearch() {
    _search.clear();
    _searchFocusNode.unfocus();
    _searchDebounceTimer?.cancel();
    setState(() {
      _homeMode = true;
      _fullSearchSubmitted = false;
      _searchSuggestions = [];
      _loadingSuggestions = false;
      _artistResults = [];
      _results = [];
      _albumResults = [];
      _playlistResults = [];
    });
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _gradientAnim.dispose();
    _queueAnim.dispose();
    _speedDialPageCtrl.dispose();
    _fullScreenPageCtrl.dispose();
    _searchDebounceTimer?.cancel();
    _search.removeListener(_onSearchChanged);
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _playingSub?.cancel();
    _processingStateSub?.cancel();
    _historyPositionSub?.cancel();
    _songPlayStopwatch.stop();
    _search.dispose();
    super.dispose();
  }

  /* ------------------------------- SEARCH -------------------------------- */

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      _exitSearch();
      return;
    }
    _searchFocusNode.unfocus();
    _searchDebounceTimer?.cancel();

    // Persist to recent searches
    await UserStorage.saveRecentSearch(query);
    unawaited(_loadRecentSearches());

    setState(() {
      _searching = true;
      _homeMode = false;
      _fullSearchSubmitted = true;
      _searchSuggestions = [];
      _openedPlaylist = null;
      _viewingLikedSongs = false;
      _viewingOfflineSongs = false;
    });
    try {
      // Fetch artists, songs, albums, and playlists in parallel
      final searchResults = await Future.wait([
        Api.searchArtists(query, n: 10),
        Api.searchSongs(query, n: 20),
        Api.searchAlbums(query, n: 10),
        Api.searchPlaylists(query, n: 10),
      ]);
      final artists = searchResults[0] as List<Artist>;
      final songs = searchResults[1] as List<Song>;
      final albums = searchResults[2] as List<Album>;
      final playlists = searchResults[3] as List<Playlist>;
      if (!mounted) return;
      setState(() {
        _artistResults = artists;
        _results = songs;
        _albumResults = albums;
        _playlistResults = playlists;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Search failed. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _playSuggestionSong(SearchSuggestion suggestion) async {
    final song = Song(
      id: suggestion.id,
      title: suggestion.title,
      artist: suggestion.subtitle.isNotEmpty ? suggestion.subtitle : 'Artist',
      album: 'JioSaavn',
      artwork: suggestion.image,
    );
    await _playSongForSuggestionMode(song);
  }

  Future<void> _openAlbumById(String id, [String? title, String? artwork]) async {
    await _openPlaylist(Playlist(
      id: id,
      title: title ?? 'Album',
      artwork: artwork ?? '',
      type: 'ALBUM',
    ));
  }

  Future<void> _openArtistById(String id, [String? name, String? image]) async {
    await _openPlaylist(Playlist(
      id: id,
      title: name ?? 'Artist',
      artwork: image ?? '',
      type: 'ARTIST',
    ));
  }

  Future<void> _openPlaylistById(String id, [String? title, String? artwork]) async {
    await _openPlaylist(Playlist(
      id: id,
      title: title ?? 'Playlist',
      artwork: artwork ?? '',
      type: 'PLAYLIST',
    ));
  }

  Future<void> _onSuggestionTapped(SearchSuggestion suggestion) async {
    await UserStorage.saveRecentSearch(suggestion.title);
    unawaited(_loadRecentSearches());

    if (suggestion.isSong) {
      await _playSuggestionSong(suggestion);
    } else if (suggestion.isAlbum) {
      await _openAlbumById(suggestion.id, suggestion.title, suggestion.image);
    } else if (suggestion.isArtist) {
      await _openArtistById(suggestion.id, suggestion.title, suggestion.image);
    } else if (suggestion.isPlaylist) {
      await _openPlaylistById(suggestion.id, suggestion.title, suggestion.image);
    } else {
      _runSearch(suggestion.title);
    }
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    setState(() {
      _openedPlaylist = playlist;
      _viewingLikedSongs = false;
      _viewingOfflineSongs = false;
      _loadingPlaylist = playlist.songs.isEmpty;
    });

    if (playlist.songs.isEmpty) {
      try {
        final Playlist? full;
        if (playlist.type == 'ALBUM') {
          full = await Api.album(playlist.id);
        } else if (playlist.type == 'ARTIST') {
          full = await Api.artist(playlist.id);
        } else {
          full = await Api.playlist(playlist.id);
        }
        if (full != null && mounted && _openedPlaylist?.id == playlist.id) {
          setState(() {
            _openedPlaylist = full;
            _loadingPlaylist = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loadingPlaylist = false);
      }
    }
  }

  /* ------------------------------ PLAYBACK ------------------------------- */

  AudioSource _sourceForSong(Song song, String stream) {
    if (stream.startsWith('/') ||
        stream.startsWith('file:') ||
        (stream.length > 2 && stream[1] == ':')) {
      final cleanPath = stream.startsWith('file://')
          ? Uri.parse(stream).toFilePath()
          : stream;
      return AudioSource.file(cleanPath, tag: song.id);
    }
    return AudioSource.uri(Uri.parse(stream), tag: song.id);
  }

  /// Resolve a song's stream URL and full metadata via the API.
  Future<(Song, String?)?> _resolveSong(Song song) async {
    if (song.id.startsWith('offline_') ||
        (song.streamUrl != null &&
            (song.streamUrl!.startsWith('/') ||
                song.streamUrl!.startsWith('file:') ||
                (song.streamUrl!.length > 2 && song.streamUrl![1] == ':')))) {
      return (song, song.streamUrl);
    }
    Map<String, dynamic>? details;
    try {
      details = await Api.details(song.id);
    } catch (_) {}
    Song resolved = details == null ? song : Song.fromJson(details);
    if (resolved.downloadUrls.isEmpty) {
      try {
        final query = '${song.title} ${song.artist}';
        final results = await Api.searchSongs(query, n: 5);
        if (results.isNotEmpty) {
          final first = results.first;
          final moreDetails = await Api.details(first.id);
          if (moreDetails != null) {
            resolved = Song.fromJson(moreDetails);
          } else {
            resolved = first;
          }
        }
      } catch (_) {}
    }
    final urls = resolved.downloadUrls;
    final match = urls.where((item) => item['quality'] == _songQuality).toList();
    final stream =
        (match.isNotEmpty
                ? match.first
                : (urls
                          .where((item) => item['quality'] == '320kbps')
                          .isNotEmpty
                      ? urls.firstWhere(
                          (item) => item['quality'] == '320kbps',
                        )
                      : (urls.isEmpty ? null : urls.last)))?['url']
            as String?;
    return (resolved, stream);
  }

  /// Low-level: play a single song directly on the CrossfadePlayer.
  /// Does NOT touch queues or modes — callers manage that.
  Future<void> _play(Song song, {bool isHistoryNavigation = false}) async {
    final request = ++_playRequest;
    _preparedSong = null;
    _preparedStreamUrl = null;
    _isNavigatingHistory = isHistoryNavigation;

    // Same track -> just toggle play/pause.
    if (_current?.id == song.id && !_isLoadingTrack) {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        unawaited(_audio.play());
      }
      if (mounted) setState(() {});
      return;
    }

    // If starting a new track outside of history navigation, truncate any forward history branch
    if (!isHistoryNavigation) {
      if (_playbackHistoryIndex >= 0 &&
          _playbackHistoryIndex < _playbackHistory.length - 1) {
        _playbackHistory.removeRange(
          _playbackHistoryIndex + 1,
          _playbackHistory.length,
        );
      }
    }

    // 1. Immediately update notification metadata with the incoming song so it never disappears
    audioHandler.setSongItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      artwork: song.artwork,
      duration: song.duration > 0 ? Duration(seconds: song.duration) : null,
    );
    // 2. Keep the notification persistent in buffering state so Android OS does not dismiss it
    audioHandler.setLoading(true);

    // Stop previous track immediately so old audio doesn't play while new song is being fetched
    unawaited(_audio.stop());

    setState(() {
      _current = song;
      _isLoadingTrack = true;
      _isLoadingLyrics = true;
      _lyrics = null;
      _parsedLyrics = [];
      _lyricsOpen = false;
      _songPlayStopwatch.reset();
      _historyAddedForCurrent = false;
    });

    try {
      if (!mounted || request != _playRequest) {
        audioHandler.setLoading(false);
        return;
      }

      final result = await _resolveSong(song);
      if (!mounted || request != _playRequest) {
        audioHandler.setLoading(false);
        return;
      }

      if (result == null) {
        audioHandler.setLoading(false);
        setState(() {
          _isLoadingTrack = false;
          _isLoadingLyrics = false;
        });
        return;
      }

      final (resolved, stream) = result;

      setState(() => _current = resolved.copyWith(streamUrl: stream));

      if (stream != null) {
        final source = _sourceForSong(resolved, stream);
        audioHandler.setSongItem(
          id: resolved.id,
          title: resolved.title,
          artist: resolved.artist,
          album: resolved.album,
          artwork: resolved.artwork,
          duration: resolved.duration > 0
              ? Duration(seconds: resolved.duration)
              : null,
        );
        audioHandler.setLoading(false);
        await _audio.playDirect(source, fadeCurrentOut: false);
        if (!mounted || request != _playRequest) return;
        if (_audio.playing) {
          _songPlayStopwatch.start();
        }
        setState(() => _isLoadingTrack = false);
      } else if (mounted && request == _playRequest) {
        audioHandler.setLoading(false);
        setState(() {
          _isLoadingTrack = false;
          _isLoadingLyrics = false;
        });
      }

      // Fetch lyrics in background (online tracks only).
      if (!resolved.id.startsWith('offline_')) {
        final lyricData = await Api.lyrics(resolved);
        if (!mounted || request != _playRequest) return;
        setState(() {
          _lyrics = lyricData;
          _parsedLyrics = parseLyrics(lyricData?['syncedLyrics'] as String?);
          _isLoadingLyrics = false;
        });
      } else {
        setState(() {
          _lyrics = null;
          _parsedLyrics = [];
          _isLoadingLyrics = false;
        });
      }
    } catch (_) {
      audioHandler.setLoading(false);
      if (mounted && request == _playRequest) {
        setState(() {
          _isLoadingTrack = false;
          _isLoadingLyrics = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This track could not be loaded.')),
        );
      }
    }
  }

  /* ------------- MODE 1: Individual song + suggestions queue ------------- */

  /// Called when user selects an individual song (from Home, Search, etc.).
  /// Clears existing queue, plays the song, fetches 15 suggestions.
  Future<void> _playSongForSuggestionMode(Song song) async {
    // Switch to suggestion mode and clear everything.
    setState(() {
      _playbackMode = PlaybackMode.suggestions;
      _suggestionQueue = [];
      _playlistQueue = [];
      _playlistQueueIndex = -1;
    });

    // Play the selected song.
    await _play(song);
    if (!mounted || _current?.id != song.id) return;

    // Fetch 15 suggestions.
    unawaited(_fetchSuggestions(song.id));
  }

  /// Fetch exactly 15 suggestions. Replaces the suggestion queue entirely.
  Future<void> _fetchSuggestions(String songId) async {
    if (_playbackMode == PlaybackMode.playlist || songId.startsWith('offline_')) {
      return;
    }
    if (_isFetchingSuggestions) return;
    _isFetchingSuggestions = true;
    try {
      final suggestions = await Api.suggestions(songId, limit: 15);
      if (!mounted) return;
      // Filter out the currently playing song to avoid duplication.
      final currentId = _current?.id;
      final unique = suggestions
          .where((s) => s.id != currentId)
          .toList();
      setState(() => _suggestionQueue = unique);
    } catch (_) {
      // Silently ignore fetch errors.
    } finally {
      _isFetchingSuggestions = false;
    }
  }

  /* -------------------- MODE 2: Playlist repeat queue -------------------- */

  /// Called when user presses Play All / Shuffle on a playlist or liked songs.
  /// Clears suggestion queue, loads all playlist songs, plays first, repeats.
  Future<void> _playPlaylist(List<Song> songs) => _playPlaylistSong(songs, 0);

  /// Plays a playlist starting at a specific song index in playlist repeat mode.
  Future<void> _playPlaylistSong(List<Song> songs, int startIndex) async {
    if (songs.isEmpty || startIndex < 0 || startIndex >= songs.length) return;

    setState(() {
      _playbackMode = PlaybackMode.playlist;
      _suggestionQueue = [];
      _unshuffledPlaylist = List<Song>.from(songs);
      if (_isShuffle && songs.length > 2) {
        final startSong = songs[startIndex];
        final remaining = <Song>[];
        for (int i = 0; i < songs.length; i++) {
          if (i != startIndex) remaining.add(songs[i]);
        }
        remaining.shuffle();
        _playlistQueue = [startSong, ...remaining];
        _playlistQueueIndex = 0;
      } else {
        _playlistQueue = [...songs];
        _playlistQueueIndex = startIndex;
      }
    });

    await _play(songs[startIndex]);
  }

  /* -------------------- Song completion / auto-advance ------------------- */

  /// Called when the active player reaches ProcessingState.completed.
  void _onSongCompleted() {
    if (_isLoadingTrack || _current == null) return;
    // If an active crossfade is currently transitioning, skip auto-advance.
    if (_audio.isCrossfading) return;
    if (_repeatMode == PlaybackRepeatMode.one) {
      _audio.seek(Duration.zero);
      _audio.play();
      _songPlayStopwatch.reset();
      _historyAddedForCurrent = false;
      if (mounted) setState(() {});
      return;
    }
    _next();
  }

  /// Advance to the next song based on current playback mode.
  void _advanceToNextSong() {
    if (_playbackMode == PlaybackMode.playlist) {
      _advancePlaylist();
    } else {
      _advanceSuggestionQueue();
    }
  }

  void _advancePlaylist() {
    if (_playlistQueue.isEmpty) return;
    final nextIdx = _playlistQueueIndex + 1;
    if (nextIdx < _playlistQueue.length) {
      _playlistQueueIndex = nextIdx;
      _play(_playlistQueue[_playlistQueueIndex]);
    } else if (_repeatMode == PlaybackRepeatMode.all) {
      _playlistQueueIndex = 0;
      _play(_playlistQueue[_playlistQueueIndex]);
    } else {
      _audio.pause();
      _audio.seek(Duration.zero);
      if (mounted) setState(() {});
    }
  }

  void _advanceSuggestionQueue() {
    if (_suggestionQueue.isEmpty) {
      // Queue exhausted — fetch more based on current song.
      if (_current != null) {
        _fetchSuggestions(_current!.id).then((_) {
          if (_suggestionQueue.isNotEmpty && mounted) {
            final next = _suggestionQueue.removeAt(0);
            setState(() {});
            _play(next);
          }
        });
      }
      return;
    }

    final next = _suggestionQueue.removeAt(0);
    setState(() {});
    _play(next);

    // If queue is now empty after this removal, prefetch next batch.
    if (_suggestionQueue.isEmpty && _current != null) {
      unawaited(_fetchSuggestions(next.id));
    }
  }

  /* ----------------------- Crossfade callbacks --------------------------- */

  /// Called ~13s before song ends (prefetch window: 8s before crossfade starts).
  void _onPrepareNextTrack() {
    if (_repeatMode == PlaybackRepeatMode.one) return;
    final nextSong = _peekNextSong();
    if (nextSong == null) return;

    _resolveSong(nextSong).then((result) {
      if (result == null || !mounted) return;
      final (resolved, stream) = result;
      if (stream != null) {
        _preparedSong = resolved;
        _preparedStreamUrl = stream;
        _audio.prepareNext(_sourceForSong(resolved, stream), uri: stream);
      }
    }).catchError((_) {});
  }

  /// Called when 5 seconds remain — start the 5s crossfade transition.
  void _onCrossfadeTriggered() {
    if (_repeatMode == PlaybackRepeatMode.one) return;
    if (_audio.isCrossfading || _isLoadingTrack) return;
    final nextSong = _peekNextSong();
    if (nextSong == null) return;

    void executeCrossfade(Song resolved, String stream) {
      final source = _sourceForSong(resolved, stream);
      _audio.startCrossfade(
        nextSource: source,
        nextUri: stream,
        onCompleted: () {
          if (!mounted) return;
          _consumeNextSong(resolved);

          setState(() {
            _current = resolved.copyWith(streamUrl: stream);
            _isLoadingTrack = false;
            _songPlayStopwatch.reset();
            _historyAddedForCurrent = false;
            _lyrics = null;
            _parsedLyrics = [];
            _isLoadingLyrics = true;
            if (_audio.playing) {
              _songPlayStopwatch.start();
            }
          });

          _preparedSong = null;
          _preparedStreamUrl = null;

          audioHandler.setSongItem(
            id: resolved.id,
            title: resolved.title,
            artist: resolved.artist,
            album: resolved.album,
            artwork: resolved.artwork,
            duration: resolved.duration > 0
                ? Duration(seconds: resolved.duration)
                : null,
          );

          Api.lyrics(resolved).then((lyricData) {
            if (mounted && _current?.id == resolved.id) {
              setState(() {
                _lyrics = lyricData;
                _parsedLyrics = parseLyrics(lyricData?['syncedLyrics'] as String?);
                _isLoadingLyrics = false;
              });
            }
          }).catchError((_) {
            if (mounted && _current?.id == resolved.id) {
              setState(() {
                _isLoadingLyrics = false;
              });
            }
          });
        },
      );
    }

    if (_preparedSong != null &&
        _preparedSong!.id == nextSong.id &&
        _preparedStreamUrl != null) {
      executeCrossfade(_preparedSong!, _preparedStreamUrl!);
    } else {
      _resolveSong(nextSong).then((result) {
        if (result == null || !mounted) return;
        final (resolved, stream) = result;
        if (stream == null) return;
        executeCrossfade(resolved, stream);
      }).catchError((_) {});
    }
  }

  /// Peek at the next song WITHOUT removing it from the queue.
  Song? _peekNextSong() {
    if (_repeatMode == PlaybackRepeatMode.one) return null;
    if (_playbackHistoryIndex < _playbackHistory.length - 1) {
      return _playbackHistory[_playbackHistoryIndex + 1];
    }
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isEmpty) return null;
      final nextIdx = _playlistQueueIndex + 1;
      if (nextIdx < _playlistQueue.length) {
        return _playlistQueue[nextIdx];
      } else if (_repeatMode == PlaybackRepeatMode.all) {
        return _playlistQueue.first;
      } else {
        return null;
      }
    } else {
      return _suggestionQueue.isNotEmpty ? _suggestionQueue.first : null;
    }
  }

  /// Consume (advance past) the next song in the queue.
  void _consumeNextSong([Song? justPlayed]) {
    if (_playbackHistoryIndex < _playbackHistory.length - 1) {
      _playbackHistoryIndex++;
      setState(() {});
      return;
    }
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isEmpty) return;
      final nextIdx = _playlistQueueIndex + 1;
      if (nextIdx < _playlistQueue.length) {
        _playlistQueueIndex = nextIdx;
      } else if (_repeatMode == PlaybackRepeatMode.all) {
        _playlistQueueIndex = 0;
      }
    } else {
      if (_suggestionQueue.isNotEmpty) {
        final consumed = _suggestionQueue.removeAt(0);
        // If queue just became empty, trigger a prefetch.
        if (_suggestionQueue.isEmpty) {
          final targetSong = justPlayed ?? _current ?? consumed;
          unawaited(_fetchSuggestions(targetSong.id));
        }
      }
    }
    setState(() {});
  }

  /* ---------------------- Next / Previous / Controls --------------------- */

  void _next() {
    if (_isLoadingTrack || _current == null) return;

    // Traverse forward in session playback history if user navigated backward earlier
    if (_playbackHistoryIndex < _playbackHistory.length - 1) {
      _playbackHistoryIndex++;
      final nextSong = _playbackHistory[_playbackHistoryIndex];
      _play(nextSong, isHistoryNavigation: true).then((_) {
        // If we reached the tip of playback history and queue is empty, prefetch suggestions
        if (_playbackHistoryIndex == _playbackHistory.length - 1 &&
            _suggestionQueue.isEmpty &&
            mounted) {
          unawaited(_fetchSuggestions(nextSong.id));
        }
      });
      return;
    }

    // At the tip: advance to next song in queue/mode
    _advanceToNextSong();
  }

  void _previous() {
    if (_isLoadingTrack) return;

    Song? songToPlay;

    // 1. Navigate backward in active session playback history
    if (_playbackHistoryIndex > 0) {
      _playbackHistoryIndex--;
      songToPlay = _playbackHistory[_playbackHistoryIndex];
    } else {
      // 2. Fall back to persistent recently played history
      if (_history.isNotEmpty) {
        final currentIdx = _history.indexWhere((s) => s.id == _current?.id);
        if (currentIdx >= 0 && currentIdx + 1 < _history.length) {
          songToPlay = _history[currentIdx + 1];
        } else if (_history.length > 1) {
          songToPlay = _history[1];
        } else if (_history.isNotEmpty && _history.first.id != _current?.id) {
          songToPlay = _history.first;
        }
        if (songToPlay != null) {
          _playbackHistory.insert(0, songToPlay);
          _playbackHistoryIndex = 0;
        }
      }
    }

    if (_playbackMode == PlaybackMode.playlist &&
        _playlistQueue.isNotEmpty) {
      _playlistQueueIndex =
          (_playlistQueueIndex - 1 + _playlistQueue.length) %
              _playlistQueue.length;
      songToPlay = _playlistQueue[_playlistQueueIndex];
      _play(songToPlay, isHistoryNavigation: true);
      return;
    }

    if (songToPlay == null) return;

    // CRITICAL USER REQUIREMENT:
    // Whenever the user clicks previous button, the queue must be empty
    // and the next 15 songs will be fetched from suggestions and put into the queue.
    setState(() {
      _suggestionQueue = [];
      _playlistQueue = [];
      _playbackMode = PlaybackMode.suggestions;
    });

    _play(songToPlay, isHistoryNavigation: true).then((_) {
      if (mounted) {
        unawaited(_fetchSuggestions(songToPlay!.id));
      }
    });
  }

  void _togglePlayPause() {
    if (_current == null) return;
    if (_audio.processingState == ProcessingState.completed) {
      _advanceToNextSong();
      return;
    }
    if (_audio.playing) {
      unawaited(_audio.pause());
    } else {
      unawaited(_audio.play());
    }
  }

  /// Builds a unified play/pause button that visibly shows a loading spinner
  /// whenever the song is resolving, loading, or buffering.
  Widget _buildPlayPauseButton({
    required double iconSize,
    required double spinnerSize,
    required double strokeWidth,
    Color? color,
  }) {
    final effectiveColor =
        color ?? (_isLight ? const Color(0xff0f172a) : Colors.white);
    return StreamBuilder<bool>(
      stream: _audio.playingStream,
      initialData: _audio.playing,
      builder: (_, playSnap) {
        final isPlaying = playSnap.data ?? _audio.playing;
        return StreamBuilder<ProcessingState>(
          stream: _audio.processingStateStream,
          initialData: _audio.processingState,
          builder: (_, procSnap) {
            final proc = procSnap.data ?? _audio.processingState;
            final isBuffering = _isLoadingTrack ||
                proc == ProcessingState.buffering ||
                proc == ProcessingState.loading;

            return IconButton(
              onPressed: isBuffering ? null : _togglePlayPause,
              icon: isBuffering
                  ? SizedBox(
                      width: spinnerSize,
                      height: spinnerSize,
                      child: CircularProgressIndicator(
                        strokeWidth: strokeWidth,
                        color: effectiveColor,
                      ),
                    )
                  : Icon(
                      isPlaying
                          ? PhosphorIconsRegular.pauseCircle
                          : PhosphorIconsRegular.playCircle,
                      size: iconSize,
                      color: effectiveColor,
                    ),
            );
          },
        );
      },
    );
  }

  void _seek(double seconds) =>
      _audio.seek(Duration(milliseconds: (seconds * 1000).round()));

  Future<void> _download(Song song) async {
    String? url = song.streamUrl;
    if (url == null && song.downloadUrls.isNotEmpty) {
      final match = song.downloadUrls
          .where((i) => i['quality'] == _songQuality)
          .toList();
      url =
          (match.isNotEmpty ? match.first : song.downloadUrls.last)['url']
              as String?;
    }
    if (url == null) {
      try {
        final details = await Api.details(song.id);
        if (details != null) {
          final resolved = Song.fromJson(details);
          final urls = resolved.downloadUrls;
          final match = urls
              .where((item) => item['quality'] == _songQuality)
              .toList();
          url =
              (match.isNotEmpty
                      ? match.first
                      : (urls
                                .where((item) => item['quality'] == '320kbps')
                                .isNotEmpty
                            ? urls.firstWhere(
                                (item) => item['quality'] == '320kbps',
                              )
                            : (urls.isEmpty ? null : urls.last)))?['url']
                  as String?;
        }
      } catch (_) {}
    }

    if (url == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Download link not available for this track'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /* ------------------------------- PALETTE ------------------------------- */

  Future<List<Color>> _paletteFor(Song song) {
    final key = song.artwork.trim().isEmpty
        ? _fallbackArt
        : song.artwork.trim();
    return _paletteFutures.putIfAbsent(key, () async {
      try {
        final ImageProvider imageProvider;
        if (key.startsWith('/') ||
            key.startsWith('file:') ||
            (key.length > 2 && key[1] == ':')) {
          final clean =
              key.startsWith('file://') ? Uri.parse(key).toFilePath() : key;
          imageProvider = FileImage(File(clean));
        } else {
          imageProvider = NetworkImage(key);
        }
        final palette = await PaletteGenerator.fromImageProvider(
          imageProvider,
          maximumColorCount: 12,
        );
        final colors = <Color>[
          if (palette.dominantColor != null) palette.dominantColor!.color,
          ...palette.colors,
        ];
        final representative = <Color>[];
        for (final color in colors) {
          final toned = _toneArtworkColor(color);
          if (representative.every(
            (item) => _colorDistance(item, toned) > 42,
          )) {
            representative.add(toned);
          }
          if (representative.length == 3) break;
        }
        return representative.isEmpty
            ? const [Color(0xff25213f), Color(0xff0b0b12)]
            : representative;
      } catch (_) {
        return const [Color(0xff25213f), Color(0xff0b0b12)];
      }
    });
  }

  List<Color> _paletteOrDefault(AsyncSnapshot<List<Color>> snapshot) =>
      snapshot.data ?? const [Color(0xff25213f), Color(0xff0b0b12)];

  Color _toneArtworkColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation * 1.1).clamp(.35, .95))
        .withLightness(hsl.lightness.clamp(.28, .62))
        .toColor();
  }

  double _colorDistance(Color first, Color second) {
    final red = (first.r - second.r) * 255;
    final green = (first.g - second.g) * 255;
    final blue = (first.b - second.b) * 255;
    return math.sqrt(red * red + green * green + blue * blue);
  }

  /* -------------------------------- BUILD -------------------------------- */

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullScreen &&
          _openedPlaylist == null &&
          !_viewingLikedSongs &&
          !_viewingOfflineSongs &&
          _homeMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_fullScreen) {
            if (_queueAnim.value > 0.05) {
              _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
              return;
            }
            setState(() => _fullScreen = false);
          } else if (_openedPlaylist != null) {
            setState(() => _openedPlaylist = null);
          } else if (_viewingLikedSongs) {
            setState(() => _viewingLikedSongs = false);
          } else if (_viewingOfflineSongs) {
            setState(() => _viewingOfflineSongs = false);
          } else if (!_homeMode) {
            if (_fullSearchSubmitted && _search.text.trim().isNotEmpty) {
              setState(() => _fullSearchSubmitted = false);
            } else {
              _exitSearch();
            }
          }
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  if (_openedPlaylist != null)
                    _playlistHeader()
                  else if (_viewingLikedSongs)
                    _likedSongsHeader()
                  else if (_viewingOfflineSongs)
                    _offlineSongsHeader()
                  else
                    _header(),
                  Expanded(
                    child: _openedPlaylist != null
                        ? _playlistView()
                        : (_viewingLikedSongs
                              ? _likedSongsView()
                              : (_viewingOfflineSongs
                                    ? _offlineSongsView()
                                    : (_homeMode
                                          ? _home()
                                          : (_fullSearchSubmitted
                                                ? _searchResults()
                                                : _searchSuggestionsPage())))),
                  ),
                  if (_current != null) _playerBar(),
                ],
              ),
            ),

            // Lyrics bottom sheet overlay.
            if (_lyricsOpen && _current != null) ...[
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _lyricsOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: .55)),
                ),
              ),
              Positioned.fill(child: _lyricsSheet()),
            ],

            // Full screen player overlay.
            if (_fullScreen && _current != null)
              Positioned.fill(child: _fullScreenView()),
          ],
        ),
      ),
    );
  }

  void _openFullScreen() {
    if (_current == null) return;
    _queueAnim.value = 0.0;
    setState(() {
      _lyricsOpen = false;
      _fullScreenLyrics = false;
      _fullScreen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_fullScreenPageCtrl.hasClients) {
        _fullScreenPageCtrl.jumpToPage(0);
      }
    });
  }

  /* -------------------------------- HEADER ------------------------------- */

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
    decoration: BoxDecoration(
      color: _headerBg,
      border: Border(bottom: BorderSide(color: _borderColor)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_homeMode) ...[
          GestureDetector(
            onTap: () {
              _search.clear();
              setState(() {
                _homeMode = true;
                _openedPlaylist = null;
                _viewingLikedSongs = false;
                _viewingOfflineSongs = false;
                _artistResults = [];
                _results = [];
                _albumResults = [];
                _playlistResults = [];
              });
            },
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xfff1f3f5)
                        : Colors.white.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    PhosphorIconsRegular.musicNote,
                    color: _textColor,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_userProfile != null && _userProfile!.name.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Hello, ',
                            style: GoogleFonts.manrope(
                              fontSize: 19.5,
                              fontWeight: FontWeight.w900,
                              color: _textColor,
                              letterSpacing: -0.4,
                            ),
                          ),
                          ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: AppConstants.userNameGradientColors,
                            ).createShader(
                              Rect.fromLTWH(0, 0, bounds.width, bounds.height),
                            ),
                            blendMode: BlendMode.srcIn,
                            child: Text(
                              () {
                                final first = _userProfile!.name
                                    .trim()
                                    .split(RegExp(r'\s+'))
                                    .first;
                                if (first.length >
                                    AppConstants.maxFirstNameLength) {
                                  return first.substring(
                                    0,
                                    AppConstants.maxFirstNameLength,
                                  );
                                }
                                return first;
                              }(),
                              style: GoogleFonts.manrope(
                                fontSize: 19.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: AppConstants.userNameGradientColors,
                        ).createShader(
                          Rect.fromLTWH(0, 0, bounds.width, bounds.height),
                        ),
                        blendMode: BlendMode.srcIn,
                        child: Text(
                          'Sonix',
                          style: GoogleFonts.manrope(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    Text(
                      _userProfile != null && _userProfile!.name.isNotEmpty
                          ? 'ENJOY YOUR MUSIC'
                          : 'SONG PLAYER',
                      style: GoogleFonts.manrope(
                        fontSize: 9.5,
                        color: _subtextColor,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _openEqualizerSheet,
                  child: Container(
                    width: 38,
                    height: 38,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: _isLight
                          ? const Color(0xfff1f3f5)
                          : Colors.white.withValues(alpha: .12),
                      shape: BoxShape.circle,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          PhosphorIconsRegular.slidersHorizontal,
                          size: 20,
                          color:
                              _eqEnabled ? const Color(0xff3B82F6) : _textColor,
                        ),
                        if (_eqEnabled)
                          Positioned(
                            top: 7,
                            right: 7,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xff3B82F6),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _openUserMenu,
                  child: CustomPaint(
                    foregroundPainter: const _GradientCircleBorderPainter(
                      gradient: LinearGradient(
                        colors: AppConstants.userNameGradientColors,
                      ),
                      strokeWidth: 1,
                    ),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: _isLight
                            ? const Color(0xfff1f3f5)
                            : Colors.white.withValues(alpha: .12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        PhosphorIconsBold.user,
                        size: 20,
                        color: _textColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _search,
          focusNode: _searchFocusNode,
          textInputAction: TextInputAction.search,
          onSubmitted: _runSearch,
          onTap: () {
            if (_homeMode) {
              setState(() {
                _homeMode = false;
                _fullSearchSubmitted = false;
              });
            }
          },
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: _textColor,
          ),
          decoration: InputDecoration(
            hintText: 'Search songs, artists, albums...',
            hintStyle: TextStyle(
              color: _subtextColor,
              fontWeight: FontWeight.w400,
            ),
            prefixIcon: !_homeMode
                ? IconButton(
                    icon: Icon(
                      PhosphorIconsRegular.arrowLeft,
                      size: 20,
                      color: _textColor,
                    ),
                    onPressed: _exitSearch,
                    tooltip: 'Back to Home',
                  )
                : Icon(
                    PhosphorIconsRegular.magnifyingGlass,
                    size: 19,
                    color: _subtextColor,
                  ),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    icon: Icon(
                      PhosphorIconsRegular.x,
                      size: 17,
                      color: _subtextColor,
                    ),
                    onPressed: () {
                      _search.clear();
                      setState(() {
                        _searchSuggestions = [];
                        _loadingSuggestions = false;
                        _fullSearchSubmitted = false;
                      });
                    },
                    tooltip: 'Clear',
                  ),
            filled: true,
            fillColor: _inputFill,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(30),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    ),
  );

  /* --------------------------------- HOME -------------------------------- */

  Widget _home() => ListView(
    padding: const EdgeInsets.fromLTRB(14, 18, 14, 120),
    children: [
      if (_noticeVisible && AppConstants.noticeContent.trim().isNotEmpty)
        _notice(),
      _speedDialSection(),
      _section('Trending', _effectiveTrendingSongs, horizontal: true),
      _section('Suggested for You', _effectiveSuggestedSongs),
      _section('Most Played', _effectiveMostPlayedSongs, horizontal: true),
      _section('Top Hits', _effectiveTopHitsSongs, horizontal: true),
      _featuredPlaylistsSection(),
      _historySection(),
      const SizedBox(height: 16),
      Center(
        child: Text(
          'Next-generation music streaming experience',
          style: TextStyle(color: _subtextColor, fontSize: 12),
        ),
      ),
      const SizedBox(height: 6),
      Center(
        child: Text(
          '© 2026 Sonix Music Streaming Inc.',
          style: TextStyle(
            color: _isLight
                ? const Color(0xff94a3b8)
                : const Color(0xff57575d),
            fontSize: 11,
          ),
        ),
      ),
    ],
  );

  Widget _notice() {
    if (AppConstants.noticeContent.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _isLight ? AppConstants.noticeBgLight : AppConstants.noticeBgDark,
        border: Border.all(
          color: _isLight
              ? AppConstants.noticeBorderLight
              : AppConstants.noticeBorderDark,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.info,
            color: _isLight
                ? AppConstants.noticeIconLight
                : AppConstants.noticeIconDark,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (AppConstants.noticeTitle.trim().isNotEmpty)
                  Text(
                    AppConstants.noticeTitle,
                    style: TextStyle(
                      color: _isLight
                          ? AppConstants.noticeTitleLight
                          : AppConstants.noticeTitleDark,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                Text(
                  AppConstants.noticeContent,
                  style: TextStyle(
                    fontSize: 12,
                    color: _isLight
                        ? AppConstants.noticeTextLight
                        : AppConstants.noticeTextDark,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _noticeVisible = false),
            icon: Icon(
              PhosphorIconsRegular.x,
              size: 17,
              color: _isLight
                  ? AppConstants.noticeCloseIconLight
                  : AppConstants.noticeCloseIconDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedDialSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header & Note
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Speed Dial',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: _textColor,
                ),
              ),
              if (AppConstants.speedDialNoteText.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  AppConstants.speedDialNoteText.trim(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _subtextColor,
                  ),
                ),
              ],
            ],
          ),
        ),

        // 3x3 Grid across 3 Horizontally Swipeable Pages
        LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            final itemSpacing = AppConstants.speedDialItemSpacing;
            final slideGap = AppConstants.speedDialSlideGap;
            final slideHorizontalPadding = slideGap / 2.0;
            const crossAxisCount = 3;

            // Width available for the 3 columns on a single slide
            final availableSlideWidth =
                totalWidth - (slideHorizontalPadding * 2);
            final cardWidth =
                (availableSlideWidth - (itemSpacing * (crossAxisCount - 1))) /
                    crossAxisCount;
            final cardHeight = cardWidth + 24.0;
            final gridHeight = (cardHeight * 3) + (itemSpacing * 2);

            return SizedBox(
              height: gridHeight,
              child: PageView.builder(
                controller: _speedDialPageCtrl,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                clipBehavior: Clip.none,
                itemCount: 3,
                onPageChanged: (page) => setState(() => _speedDialPage = page),
                itemBuilder: (context, pageIndex) {
                  final songsList = _effectiveSpeedDialSongs;
                  final startIndex = pageIndex * 9;
                  final endIndex =
                      math.min(startIndex + 9, songsList.length);
                  final pageSongs = songsList.sublist(
                    startIndex.clamp(0, songsList.length),
                    endIndex.clamp(0, songsList.length),
                  );

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: slideHorizontalPadding,
                    ),
                    child: Column(
                      children: [
                        for (int row = 0; row < 3; row++) ...[
                          if (row > 0) SizedBox(height: itemSpacing),
                          Row(
                            children: [
                              for (int col = 0; col < 3; col++) ...[
                                if (col > 0) SizedBox(width: itemSpacing),
                                Expanded(
                                  child: (row * 3 + col < pageSongs.length)
                                      ? _speedDialCard(
                                          pageSongs[row * 3 + col],
                                          cardWidth,
                                        )
                                      : const SizedBox(),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),

        const SizedBox(height: 12),

        // Pagination Dots Indicator
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final isActive = _speedDialPage == index;
              return GestureDetector(
                onTap: () {
                  _speedDialPageCtrl.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                  );
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 4,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    width: isActive ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xff3B82F6)
                          : (_isLight
                              ? const Color(0x28000000)
                              : Colors.white.withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),

        const SizedBox(height: 26),
      ],
    );
  }

  Widget _speedDialCard(Song song, double size) {
    final isCurrent = _current != null &&
        (_current!.id == song.id ||
            (_current!.title.toLowerCase() == song.title.toLowerCase()));
    final isPlaying = isCurrent && _audio.playing;

    return GestureDetector(
      onTap: () => _playSongForSuggestionMode(song),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Square album artwork with rounded corners
          AspectRatio(
            aspectRatio: 1.0,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _art(song.artwork, width: size, height: size),
                ),
                // Darkened image and centered wave sound icon when playing
                if (isCurrent) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.44),
                    ),
                  ),
                  Center(
                    child: Icon(
                      isPlaying
                          ? PhosphorIconsBold.waveform
                          : PhosphorIconsFill.play,
                      size: (size * 0.28).clamp(22.0, 30.0),
                      color: Colors.white,
                    ),
                  ),
                ],
                // Subtle progress indicator for the currently playing song
                if (isCurrent)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: StreamBuilder<Duration>(
                      stream: _audio.positionStream,
                      builder: (context, snapshot) {
                        final pos = snapshot.data ?? Duration.zero;
                        final dur = _audio.duration ?? Duration.zero;
                        final progress = (dur.inMilliseconds > 0)
                            ? (pos.inMilliseconds / dur.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0;
                        return ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(10),
                          ),
                          child: Container(
                            height: 3.5,
                            color: Colors.black38,
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress,
                              child: Container(
                                color: const Color(0xff3B82F6),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Song title at the bottom with ellipsis
          Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.manrope(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Song> songs, {bool horizontal = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              title,
              style: GoogleFonts.manrope(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: _textColor,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (horizontal)
            SizedBox(
              height: 245,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: songs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, i) => _card(songs[i], songs),
              ),
            )
          else
            Column(children: songs.map((s) => _row(s, songs)).toList()),
          const SizedBox(height: 26),
        ],
      );

  Widget _card(Song song, [List<Song>? contextQueue]) {
    final isCurrent = _current?.id == song.id;
    return GestureDetector(
      onTap: () => _playSongForSuggestionMode(song),
      child: SizedBox(
        width: 145,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _art(song.artwork, width: 145, height: 178),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () => _showSongOptions(song, contextQueue),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .65),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Icon(
                        PhosphorIconsRegular.dotsThreeVertical,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 9,
                  bottom: 9,
                  child: CircleAvatar(
                    radius: 19,
                    backgroundColor: Colors.white,
                    child: Icon(
                      isCurrent && _audio.playing
                          ? PhosphorIconsRegular.pause
                          : PhosphorIconsRegular.play,
                      color: Colors.black,
                      size: 21,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              song.artist.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _subtextColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: .7,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.manrope(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: _textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featuredPlaylistsSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Icon(PhosphorIconsRegular.playlist, size: 22, color: _textColor),
            const SizedBox(width: 8),
            Text(
              'Featured Playlists',
              style: GoogleFonts.manrope(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: _textColor,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 240,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _effectiveFeaturedPlaylists.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, i) => _playlistCard(_effectiveFeaturedPlaylists[i]),
        ),
      ),
      const SizedBox(height: 26),
    ],
  );

  Widget _historySection() {
    if (_history.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Recently Played',
              style: GoogleFonts.manrope(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: _textColor,
                letterSpacing: -0.3,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(9),
              border: _isLight ? Border.all(color: _borderColor) : null,
            ),
            child: Center(
              child: Text(
                'No recently played songs yet',
                style: TextStyle(color: _subtextColor, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 26),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recently Played',
                style: GoogleFonts.manrope(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: _textColor,
                  letterSpacing: -0.3,
                ),
              ),
              GestureDetector(
                onTap: _clearHistory,
                child: Text(
                  'Clear',
                  style: TextStyle(
                    color: _subtextColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Column(children: _history.map((s) => _row(s, _history)).toList()),
        const SizedBox(height: 26),
      ],
    );
  }

  Widget _playlistCard(Playlist playlist) => GestureDetector(
    onTap: () => _openPlaylist(playlist),
    child: SizedBox(
      width: 155,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _art(playlist.artwork, width: 155, height: 155),
              ),
              Positioned(
                bottom: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        PhosphorIconsRegular.musicNotes,
                        size: 11,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${playlist.songCount > 0 ? playlist.songCount : 20} songs',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: CircleAvatar(
                  radius: 17,
                  backgroundColor: Colors.white,
                  child: const Icon(
                    PhosphorIconsRegular.play,
                    color: Colors.black,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            playlist.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.manrope(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: _textColor,
              height: 1.25,
            ),
          ),
          if (playlist.description.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              playlist.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _subtextColor,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _row(Song song, [List<Song>? contextQueue]) {
    final isCurrent = _current?.id == song.id;
    final isLiked = _likedSongs.containsKey(song.id);
    return InkWell(
      onTap: () => _playSongForSuggestionMode(song),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: isCurrent
              ? (_isLight
                  ? const Color(0xffe2e8f0)
                  : Colors.white.withValues(alpha: .1))
              : _cardBg,
          borderRadius: BorderRadius.circular(9),
          border: _isLight ? Border.all(color: _borderColor) : null,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppConstants.songRowThumbnailRadius,
              ),
              child: _art(song.artwork, width: 55, height: 55),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _subtextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: _textColor,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _subtextColor,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, contextQueue),
              icon: Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
                color: _subtextColor,
              ),
              tooltip: 'More options',
            ),
          ],
        ),
      ),
    );
  }

  Widget _art(String url, {required double width, required double height}) {
    final cleanUrl = url.trim();
    if (cleanUrl.isNotEmpty &&
        (cleanUrl.startsWith('/') ||
            cleanUrl.startsWith('file:') ||
            (cleanUrl.length > 2 && cleanUrl[1] == ':'))) {
      final cleanPath = cleanUrl.startsWith('file://')
          ? Uri.parse(cleanUrl).toFilePath()
          : cleanUrl;
      final file = File(cleanPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackArtWidget(width, height),
        );
      }
    }
    final effectiveUrl = cleanUrl.isEmpty ? _fallbackArt : cleanUrl;
    return Image.network(
      effectiveUrl,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Image.network(
        _fallbackArt,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallbackArtWidget(width, height),
      ),
    );
  }

  Widget _fallbackArtWidget(double width, double height) => Container(
        width: width,
        height: height,
        color: _cardBg,
        child: Icon(PhosphorIconsRegular.musicNote, color: _subtextColor),
      );

  /* ----------------------------- SEARCH RESULT ---------------------------- */

  Widget _searchSectionHeader(String title, IconData icon, [int? count]) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Icon(icon, size: 20, color: _textColor),
        const SizedBox(width: 8),
        Text(
          count != null && count > 0 ? '$title ($count)' : title,
          style: GoogleFonts.manrope(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: _textColor,
            letterSpacing: -0.3,
          ),
        ),
      ],
    ),
  );

  Widget _artistCard(Artist artist) => GestureDetector(
    onTap: () => _openPlaylist(artist.toPlaylist()),
    child: SizedBox(
      width: 130,
      child: Column(
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _isLight ? const Color(0x18000000) : Colors.white24,
                width: 2.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isLight
                      ? Colors.black.withValues(alpha: .08)
                      : Colors.black.withValues(alpha: .5),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipOval(
              child: _art(artist.image, width: 120, height: 120),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.manrope(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            artist.role.isNotEmpty ? artist.role : 'Artist',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: _subtextColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _albumCard(Album album) => GestureDetector(
    onTap: () => _openPlaylist(album.toPlaylist()),
    child: SizedBox(
      width: 142,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _art(album.artwork, width: 142, height: 142),
              ),
              if (album.year.isNotEmpty)
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .75),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      album.year,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .4),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    PhosphorIconsFill.play,
                    size: 14,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.manrope(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            album.subtitle.isNotEmpty
                ? album.subtitle
                : (album.songCount > 0 ? '${album.songCount} songs' : 'Album'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: _subtextColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );

  /* ---------------------- SEARCH SUGGESTIONS & AUTOCOMPLETE PAGE -------------------- */

  Widget _searchSuggestionsPage() {
    final query = _search.text.trim();
    if (query.isEmpty) {
      return _searchHubView();
    }
    return _searchQuerySuggestionsView(query);
  }

  Widget _searchHubView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
      children: [
        if (_recentSearches.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Searches',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _textColor,
                  letterSpacing: .2,
                ),
              ),
              TextButton(
                onPressed: () async {
                  await UserStorage.clearRecentSearches();
                  if (mounted) setState(() => _recentSearches = []);
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _subtextColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._recentSearches.map((term) => _recentSearchRow(term)),
          const SizedBox(height: 24),
        ],

        Row(
          children: [
            const Icon(
              PhosphorIconsRegular.flame,
              size: 18,
              color: Color(0xffff416c),
            ),
            const SizedBox(width: 7),
            Text(
              'Trending Searches',
              style: GoogleFonts.manrope(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: _textColor,
                letterSpacing: .2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: (_isHindi
                  ? const [
                      'Arijit Singh',
                      'Bollywood Hits',
                      'Sidhu Moose Wala',
                      'Trending Hindi',
                      'Shreya Ghoshal',
                      'Lo-Fi Beats',
                      'Punjabi Pop',
                      'Romantic Songs',
                      'Anuv Jain',
                      'Pritam',
                    ]
                  : const [
                      'Taylor Swift',
                      'The Weeknd',
                      'Drake',
                      'Billie Eilish',
                      'Pop Hits',
                      'Hip Hop Hits',
                      'Ed Sheeran',
                      'Dua Lipa',
                      'Top 50 Global',
                      'Coldplay',
                      'Justin Bieber',
                      'Bruno Mars',
                    ])
              .map((tag) => _trendingSearchTag(tag))
              .toList(),
        ),
      ],
    );
  }

  Widget _recentSearchRow(String term) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        _search.text = term;
        _search.selection = TextSelection.collapsed(offset: term.length);
        _runSearch(term);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              PhosphorIconsRegular.clockCounterClockwise,
              size: 18,
              color: _subtextColor,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                term,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: _textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                PhosphorIconsRegular.x,
                size: 15,
                color: _subtextColor,
              ),
              onPressed: () async {
                await UserStorage.removeRecentSearch(term);
                unawaited(_loadRecentSearches());
              },
              tooltip: 'Remove',
            ),
          ],
        ),
      ),
    );
  }

  Widget _trendingSearchTag(String tag) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        _search.text = tag;
        _search.selection = TextSelection.collapsed(offset: tag.length);
        _runSearch(tag);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _isLight
              ? const Color(0xfff1f5f9)
              : Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PhosphorIconsRegular.magnifyingGlass,
              size: 13,
              color: _subtextColor,
            ),
            const SizedBox(width: 6),
            Text(
              tag,
              style: GoogleFonts.manrope(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchQuerySuggestionsView(String query) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
      children: [
        // 1. Direct Search Action Banner
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _runSearch(query),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _isLight
                  ? const Color(0xfff8fafc)
                  : Colors.white.withValues(alpha: .05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isLight
                    ? const Color(0xffe2e8f0)
                    : Colors.white.withValues(alpha: .08),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xff0f172a)
                        : Colors.white.withValues(alpha: .15),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      PhosphorIconsRegular.magnifyingGlass,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Search for "$query"',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _textColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Search across songs, artists, albums & playlists',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: _subtextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  PhosphorIconsRegular.arrowRight,
                  size: 16,
                  color: _subtextColor,
                ),
              ],
            ),
          ),
        ),

        if (_loadingSuggestions && _searchSuggestions.isEmpty) ...[
          const SizedBox(height: 36),
          Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _isLight ? const Color(0xff0f172a) : Colors.white70,
              ),
            ),
          ),
        ] else if (_searchSuggestions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'SUGGESTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  color: _subtextColor,
                ),
              ),
              if (_loadingSuggestions)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: _subtextColor,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ..._searchSuggestions.map((s) => _suggestionRow(s, query)),
        ] else if (!_loadingSuggestions) ...[
          const SizedBox(height: 48),
          Center(
            child: Column(
              children: [
                Icon(
                  PhosphorIconsRegular.magnifyingGlass,
                  size: 44,
                  color: _subtextColor.withValues(alpha: .5),
                ),
                const SizedBox(height: 14),
                Text(
                  'No direct suggestions found',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _textColor,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Press Enter or tap above to search everywhere',
                  style: TextStyle(fontSize: 12, color: _subtextColor),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _suggestionRow(SearchSuggestion suggestion, String query) {
    Color badgeColor;
    Color badgeBg;
    IconData typeIcon;
    String typeLabel;

    if (suggestion.isArtist) {
      badgeColor = const Color(0xffa855f7);
      badgeBg = const Color(0xffa855f7).withValues(alpha: .12);
      typeIcon = PhosphorIconsRegular.user;
      typeLabel = 'ARTIST';
    } else if (suggestion.isAlbum) {
      badgeColor = const Color(0xfff59e0b);
      badgeBg = const Color(0xfff59e0b).withValues(alpha: .12);
      typeIcon = PhosphorIconsRegular.disc;
      typeLabel = 'ALBUM';
    } else if (suggestion.isPlaylist) {
      badgeColor = const Color(0xff14b8a6);
      badgeBg = const Color(0xff14b8a6).withValues(alpha: .12);
      typeIcon = PhosphorIconsRegular.playlist;
      typeLabel = 'PLAYLIST';
    } else {
      badgeColor = const Color(0xff3b82f6);
      badgeBg = const Color(0xff3b82f6).withValues(alpha: .12);
      typeIcon = PhosphorIconsRegular.musicNote;
      typeLabel = 'SONG';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _onSuggestionTapped(suggestion),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(
          children: [
            // Artwork / Avatar
            suggestion.isArtist
                ? ClipOval(
                    child: _art(suggestion.image, width: 44, height: 44),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _art(suggestion.image, width: 44, height: 44),
                  ),
            const SizedBox(width: 12),

            // Title & Subtitle + Badge
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: badgeBg,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(typeIcon, size: 9, color: badgeColor),
                            const SizedBox(width: 3),
                            Text(
                              typeLabel,
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: .5,
                                color: badgeColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (suggestion.subtitle.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            suggestion.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _subtextColor,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Insert into search bar button
            IconButton(
              icon: Icon(
                PhosphorIconsRegular.arrowUpLeft,
                size: 18,
                color: _subtextColor,
              ),
              tooltip: 'Insert into search',
              onPressed: () {
                _search.text = suggestion.title;
                _search.selection = TextSelection.collapsed(
                  offset: suggestion.title.length,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchResults() {
    if (_searching) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Searching music universe...'),
          ],
        ),
      );
    }
    final hasAny = _artistResults.isNotEmpty ||
        _results.isNotEmpty ||
        _albumResults.isNotEmpty ||
        _playlistResults.isNotEmpty;

    if (!hasAny) {
      return const Center(
        child: Text(
          'Discover any song, artist, album, or playlist',
          style: TextStyle(color: _muted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 22, 14, 120),
      children: [
        // 1. First row: Artists section (cards)
        if (_artistResults.isNotEmpty) ...[
          _searchSectionHeader(
            'Artists',
            PhosphorIconsRegular.userCircle,
            _artistResults.length,
          ),
          SizedBox(
            height: 188,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _artistResults.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _artistCard(_artistResults[i]),
            ),
          ),
          const SizedBox(height: 26),
        ],

        // 2. Second section: Songs list (top 10 songs only)
        if (_results.isNotEmpty) ...[
          _searchSectionHeader(
            'Songs',
            PhosphorIconsRegular.musicNotes,
            math.min(10, _results.length),
          ),
          ..._results.take(10).toList().asMap().entries.map(
            (entry) => _searchRow(entry.key, entry.value),
          ),
          const SizedBox(height: 26),
        ],

        // 3. Third section: Albums (cards)
        if (_albumResults.isNotEmpty) ...[
          _searchSectionHeader(
            'Albums',
            PhosphorIconsRegular.disc,
            _albumResults.length,
          ),
          SizedBox(
            height: 205,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _albumResults.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _albumCard(_albumResults[i]),
            ),
          ),
          const SizedBox(height: 26),
        ],

        // 4. Fourth section: Playlists (cards)
        if (_playlistResults.isNotEmpty) ...[
          _searchSectionHeader(
            'Playlists',
            PhosphorIconsRegular.playlist,
            _playlistResults.length,
          ),
          SizedBox(
            height: 235,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _playlistResults.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _playlistCard(_playlistResults[i]),
            ),
          ),
        ],
      ],
    );
  }

  /* ------------------------------ PLAYLIST VIEW --------------------------- */

  Widget _playlistHeader() => Container(
    padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
    decoration: BoxDecoration(
      color: _headerBg,
      border: Border(bottom: BorderSide(color: _borderColor)),
    ),
    child: Row(
      children: [
        IconButton(
          icon: Icon(PhosphorIconsRegular.arrowLeft, size: 22, color: _textColor),
          onPressed: () => setState(() => _openedPlaylist = null),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            _openedPlaylist?.title ?? 'Playlist',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.manrope(
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _playlistView() {
    final playlist = _openedPlaylist!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _art(playlist.artwork, width: 130, height: 130),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _isLight
                          ? const Color(0xff0f172a).withValues(alpha: .08)
                          : Colors.white.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      playlist.type.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: _textColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    playlist.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      height: 1.2,
                      color: _textColor,
                    ),
                  ),
                  if (playlist.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      playlist.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _subtextColor, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${playlist.songs.isNotEmpty ? playlist.songs.length : (playlist.songCount > 0 ? playlist.songCount : 0)} Songs',
                    style: TextStyle(
                      color: _subtextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: playlist.songs.isEmpty
                    ? null
                    : () => _playPlaylist(playlist.songs),
                icon: Icon(
                  PhosphorIconsFill.play,
                  size: 18,
                  color: _isLight ? Colors.white : Colors.black,
                ),
                label: Text(
                  'Play All',
                  style: TextStyle(
                    color: _isLight ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isLight ? const Color(0xff0f172a) : Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: playlist.songs.isEmpty
                    ? null
                    : () {
                        final shuffled = [...playlist.songs]..shuffle();
                        _playPlaylist(shuffled);
                      },
                icon: Icon(
                  PhosphorIconsRegular.shuffle,
                  size: 18,
                  color: _textColor,
                ),
                label: Text(
                  'Shuffle',
                  style: TextStyle(
                    color: _textColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_loadingPlaylist) ...[
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Loading playlist songs...',
                  style: TextStyle(color: _subtextColor),
                ),
              ],
            ),
          ),
        ] else if (playlist.songs.isEmpty) ...[
          const SizedBox(height: 40),
          Center(
            child: Text(
              'No songs available in this playlist',
              style: TextStyle(color: _subtextColor),
            ),
          ),
        ] else ...[
          Text(
            'Tracks (${playlist.songs.length})',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
          const SizedBox(height: 10),
          ...playlist.songs.asMap().entries.map(
            (entry) => _playlistSongRow(entry.key, entry.value, playlist),
          ),
        ],
      ],
    );
  }

  Widget _playlistSongRow(int index, Song song, Playlist playlist) {
    final isCurrent = _current?.id == song.id;
    final isLiked = _likedSongs.containsKey(song.id);
    return InkWell(
      onTap: () => _playSongForSuggestionMode(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 28,
              alignment: Alignment.centerLeft,
              child: isCurrent && _audio.playing
                  ? Icon(
                      PhosphorIconsFill.play,
                      size: 14,
                      color: _isLight
                          ? const Color(0xff0f172a)
                          : Colors.white,
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isCurrent ? _textColor : _subtextColor,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppConstants.songRowThumbnailRadius,
              ),
              child: _art(song.artwork, width: 48, height: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isCurrent
                          ? (_isLight ? const Color(0xff2563eb) : const Color(0xff60a5fa))
                          : _textColor.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _subtextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (song.duration > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  _time(Duration(seconds: song.duration)),
                  style: TextStyle(color: _subtextColor, fontSize: 11),
                ),
              ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _subtextColor,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, playlist.songs),
              icon: Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
                color: _subtextColor,
              ),
              tooltip: 'More options',
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchRow(int index, Song song) {
    final isCurrent = _current?.id == song.id;
    final isLiked = _likedSongs.containsKey(song.id);
    return InkWell(
      onTap: () => _playSongForSuggestionMode(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 28,
              alignment: Alignment.centerLeft,
              child: isCurrent && _audio.playing
                  ? Icon(
                      PhosphorIconsFill.play,
                      size: 14,
                      color: _isLight
                          ? const Color(0xff0f172a)
                          : Colors.white,
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isCurrent ? _textColor : _subtextColor,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppConstants.songRowThumbnailRadius,
              ),
              child: _art(song.artwork, width: 53, height: 53),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _subtextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _subtextColor,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, _results),
              icon: Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
                color: _subtextColor,
              ),
              tooltip: 'More options',
            ),
          ],
        ),
      ),
    );
  }

  /* ------------------------------- PLAYER BAR ----------------------------- */

  Widget _playerBar() {
    final track = _current!;
    return Container(
      decoration: BoxDecoration(
        color: _isLight ? Colors.white : _surface,
        border: Border(top: BorderSide(color: _borderColor)),
        boxShadow: _isLight
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .06),
                  blurRadius: 10,
                  offset: const Offset(0, -3),
                ),
              ]
            : null,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openFullScreen,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _progressBar(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: _art(track.artwork, width: 44, height: 44),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.manrope(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  color: _textColor,
                                ),
                              ),
                              Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _subtextColor,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _toggleLike(track),
                    icon: Icon(
                      _likedSongs.containsKey(track.id)
                          ? PhosphorIconsFill.heart
                          : PhosphorIconsRegular.heart,
                      size: 20,
                      color: _likedSongs.containsKey(track.id)
                          ? Colors.redAccent
                          : _subtextColor,
                    ),
                    tooltip: _likedSongs.containsKey(track.id)
                        ? 'Unlike'
                        : 'Like',
                  ),
                  IconButton(
                    onPressed: () => setState(() => _lyricsOpen = !_lyricsOpen),
                    icon: Icon(
                      PhosphorIconsRegular.textAa,
                      size: 20,
                      color: _lyricsOpen
                          ? (_isLight ? const Color(0xff0f172a) : Colors.white)
                          : _subtextColor,
                    ),
                    tooltip: 'Lyrics',
                  ),
                  IconButton(
                    onPressed: _previous,
                    icon: Icon(
                      PhosphorIconsRegular.skipBack,
                      size: 20,
                      color: _textColor,
                    ),
                  ),
                  _buildPlayPauseButton(
                    iconSize: 34,
                    spinnerSize: 24,
                    strokeWidth: 2.4,
                    color: _textColor,
                  ),
                  IconButton(
                    onPressed: _next,
                    icon: Icon(
                      PhosphorIconsRegular.skipForward,
                      size: 20,
                      color: _textColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Duration? get _currentTrackDuration {
    final playerDur = _audio.duration;
    if (playerDur != null && playerDur > Duration.zero) {
      return playerDur;
    }
    if (_current != null && _current!.duration > 0) {
      return Duration(seconds: _current!.duration);
    }
    return playerDur;
  }

  Widget _progressBar({double minHeight = 3}) => StreamBuilder<Duration?>(
    stream: _audio.durationStream,
    initialData: _currentTrackDuration,
    builder: (_, durationSnapshot) {
      final duration = durationSnapshot.data ?? _currentTrackDuration;
      return StreamBuilder<Duration>(
        stream: _audio.positionStream,
        initialData: _audio.position,
        builder: (_, positionSnapshot) {
          final position = positionSnapshot.data ?? _audio.position;
          final total = duration?.inMilliseconds ?? 0;
          final value = total <= 0
              ? 0.0
              : (position.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
          return LinearProgressIndicator(
            value: value,
            minHeight: minHeight,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation(
              _isLight ? const Color(0xff0f172a) : Colors.white,
            ),
          );
        },
      );
    },
  );

  /* -------------------------------- LYRICS -------------------------------- */

  Widget _lyricsSheet() => Align(
    alignment: Alignment.bottomCenter,
    child: FractionallySizedBox(
      heightFactor: 0.82,
      child: GestureDetector(
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! > 250) {
            setState(() => _lyricsOpen = false);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: _sheetBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(top: BorderSide(color: _borderColor)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _isLight ? const Color(0x20000000) : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  title: Text(
                    'Lyrics',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _textColor,
                    ),
                  ),
                  trailing: IconButton(
                    onPressed: () => setState(() => _lyricsOpen = false),
                    icon: Icon(PhosphorIconsRegular.x, color: _textColor),
                  ),
                ),
                Expanded(child: _lyricsBody()),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _lyricsBody([ScrollController? controller]) {
    return _LyricsAutoScrollView(
      lyrics: _lyrics,
      parsedLyrics: _parsedLyrics,
      isLoading: _isLoadingLyrics,
      positionStream: _audio.positionStream,
      initialPosition: _audio.position,
      onSeek: _seek,
      controller: controller,
    );
  }

  /* ------------------------------ FULL SCREEN ----------------------------- */
Widget _fullScreenView() {
  final track = _current!;
  final screenHeight = MediaQuery.sizeOf(context).height;
  final bottomPadding = MediaQuery.paddingOf(context).bottom;
  final collapsedHeight = 62.0 + bottomPadding;
  final maxSheetHeight = screenHeight * 0.78;

  return FutureBuilder<List<Color>>(
    future: _paletteFor(track),
    builder: (context, paletteSnapshot) {
      final colors = _paletteOrDefault(paletteSnapshot);
      final artworkColor = colors.first;
      final secondaryColor = colors.length > 1 ? colors[1] : artworkColor;
      final tertiaryColor = colors.length > 2 ? colors[2] : secondaryColor;
      return Material(
        color: _bg,
        child: Stack(
          children: [
            Container(
              color: _isLight
                  ? const Color(0xfff8f9fa)
                  : const ui.Color(0xff080808),
            ),
            // YouTube Music-style vertical gradient background.
            AnimatedBuilder(
              animation: _gradientAnim,
              builder: (context, child) {
                // Very subtle "breathing" drift so the background feels alive.
                final t = Curves.easeInOut.transform(_gradientAnim.value);
                final drift = (t - 0.5) * 0.06;

                // Top = artwork color, blended toward the base surface.
                final topColor = _isLight
                    ? Color.lerp(artworkColor, Colors.white, 0.25)!
                    : Color.lerp(artworkColor, Colors.black, 0.10)!;

                // Middle = artwork color heavily darkened.
                final midColor = _isLight
                    ? Color.lerp(secondaryColor, Colors.white, 0.55)!
                    : Color.lerp(artworkColor, Colors.black, 0.62)!;

                // Lower-mid = near-surface tone.
                final lowColor = _isLight
                    ? const Color(0xffeef1f5)
                    : Color.lerp(tertiaryColor, Colors.black, 0.88)!;

                return Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _isLight
                          ? [topColor, midColor, lowColor, lowColor]
                          : [
                              topColor,
                              midColor,
                              lowColor,
                              const ui.Color(0xff080808),
                            ],
                      stops: [
                        0.0,
                        0.34 + drift,
                        0.72 + drift,
                        1.0,
                      ],
                    ),
                  ),
                );
              },
            ),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) > 200) {
                        _queueAnim.value = 0.0;
                        setState(() => _fullScreen = false);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 12, 6),
                      child: Row(
                        children: [
                          Icon(
                            PhosphorIconsRegular.musicNote,
                            size: 19,
                            color: _textColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Now Playing',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _textColor,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => _toggleLike(track),
                            icon: Icon(
                              _likedSongs.containsKey(track.id)
                                  ? PhosphorIconsFill.heart
                                  : PhosphorIconsRegular.heart,
                              color: _likedSongs.containsKey(track.id)
                                  ? Colors.redAccent
                                  : _textColor,
                              size: 22,
                            ),
                            tooltip: _likedSongs.containsKey(track.id)
                                ? 'Unlike'
                                : 'Like',
                          ),
                          IconButton(
                            onPressed: () => _showSongOptions(track),
                            icon: Icon(
                              PhosphorIconsRegular.dotsThreeVertical,
                              size: 22,
                              color: _textColor,
                            ),
                            tooltip: 'Options',
                          ),
                          IconButton(
                            onPressed: () {
                              _queueAnim.value = 0.0;
                              setState(() => _fullScreen = false);
                            },
                            icon: Icon(
                              PhosphorIconsRegular.caretDown,
                              color: _textColor,
                            ),
                            tooltip: 'Minimize player',
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: _isLight
                          ? Colors.black.withValues(alpha: .06)
                          : Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _fullScreenTab(
                            icon: PhosphorIconsRegular.disc,
                            label: 'Player',
                            active: !_fullScreenLyrics,
                            onTap: () {
                              if (_fullScreenPageCtrl.hasClients) {
                                _fullScreenPageCtrl.animateToPage(
                                  0,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOutCubic,
                                );
                              } else {
                                setState(() => _fullScreenLyrics = false);
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: _fullScreenTab(
                            icon: PhosphorIconsRegular.textAa,
                            label: 'Lyrics',
                            active: _fullScreenLyrics,
                            onTap: () {
                              if (_fullScreenPageCtrl.hasClients) {
                                _fullScreenPageCtrl.animateToPage(
                                  1,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOutCubic,
                                );
                              } else {
                                setState(() => _fullScreenLyrics = true);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView(
                      controller: _fullScreenPageCtrl,
                      physics: const BouncingScrollPhysics(),
                      onPageChanged: (page) {
                        setState(() => _fullScreenLyrics = (page == 1));
                      },
                      children: [
                        // Page 0: Fullscreen Player
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onVerticalDragStart: (_) => _fsVerticalDragDist = 0.0,
                          onVerticalDragUpdate: (details) {
                            _fsVerticalDragDist += details.delta.dy;
                          },
                          onVerticalDragEnd: (details) {
                            final v = details.primaryVelocity ?? 0.0;
                            if (v > 250 || _fsVerticalDragDist > 60) {
                              _queueAnim.value = 0.0;
                              setState(() => _fullScreen = false);
                            } else if (v < -250 || _fsVerticalDragDist < -60) {
                              _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
                            }
                            _fsVerticalDragDist = 0.0;
                          },
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final availableHeight = constraints.maxHeight;
                              final artSize = (availableHeight * 0.36)
                                  .clamp(160.0, 240.0);

                              return NotificationListener<ScrollNotification>(
                                onNotification: (notification) {
                                  if (notification is OverscrollNotification &&
                                      notification.overscroll < -15) {
                                    _queueAnim.value = 0.0;
                                    setState(() => _fullScreen = false);
                                    return true;
                                  }
                                  return false;
                                },
                                child: SingleChildScrollView(
                                  physics: availableHeight < 460
                                      ? const ClampingScrollPhysics()
                                      : const NeverScrollableScrollPhysics(),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                        minHeight: availableHeight),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                            height: (availableHeight * 0.01)
                                                .clamp(16.0, 32.0)),
                                        Center(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: _isLight
                                                      ? artworkColor
                                                          .withValues(alpha: 0.3)
                                                      : Colors.black
                                                          .withValues(alpha: 0.5),
                                                  blurRadius: 28,
                                                  offset:
                                                      const Offset(0, 10),
                                                ),
                                              ],
                                            ),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              child: _art(
                                                track.artwork,
                                                width: artSize,
                                                height: artSize,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 18),
                                        Padding(
                                          padding: const EdgeInsets
                                              .symmetric(horizontal: 24),
                                          child: Text(
                                            track.title,
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.manrope(
                                              fontSize: 22,
                                              fontWeight: FontWeight.w900,
                                              color: _textColor,
                                              letterSpacing: -0.4,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Padding(
                                          padding: const EdgeInsets
                                              .symmetric(horizontal: 24),
                                          child: Text(
                                            track.artist,
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: _subtextColor,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 22),
                                        _fullScreenSlider(),
                                        _fullScreenControls(),
                                        const SizedBox(height: 12),
                                        SizedBox(height: collapsedHeight + 14),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),

                        // Page 1: Lyrics View
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onVerticalDragStart: (_) => _fsVerticalDragDist = 0.0,
                          onVerticalDragUpdate: (details) {
                            _fsVerticalDragDist += details.delta.dy;
                          },
                          onVerticalDragEnd: (details) {
                            final v = details.primaryVelocity ?? 0.0;
                            if (v > 250 || _fsVerticalDragDist > 60) {
                              _queueAnim.value = 0.0;
                              setState(() => _fullScreen = false);
                            } else if (v < -250 || _fsVerticalDragDist < -60) {
                              _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
                            }
                            _fsVerticalDragDist = 0.0;
                          },
                          child: Column(
                            children: [
                              Expanded(
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: (notification) {
                                    if (notification is OverscrollNotification) {
                                      if (notification.overscroll < -15) {
                                        _queueAnim.value = 0.0;
                                        setState(() => _fullScreen = false);
                                        return true;
                                      } else if (notification.overscroll > 12) {
                                        _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
                                        return true;
                                      }
                                    }
                                    if (notification is ScrollEndNotification) {
                                      final v = notification.dragDetails?.primaryVelocity ?? 0.0;
                                      if (notification.metrics.pixels <= 0 && v > 250) {
                                        _queueAnim.value = 0.0;
                                        setState(() => _fullScreen = false);
                                        return true;
                                      }
                                      if ((notification.metrics.pixels >= notification.metrics.maxScrollExtent - 20 ||
                                              notification.metrics.maxScrollExtent <= 0) &&
                                          v < -200) {
                                        _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
                                        return true;
                                      }
                                    }
                                    return false;
                                  },
                                  child: _lyricsBody(),
                                ),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onVerticalDragStart: (_) => _fsVerticalDragDist = 0.0,
                                onVerticalDragUpdate: (details) {
                                  _fsVerticalDragDist += details.delta.dy;
                                },
                                onVerticalDragEnd: (details) {
                                  final v = details.primaryVelocity ?? 0.0;
                                  if (v > 250 || _fsVerticalDragDist > 60) {
                                    _queueAnim.value = 0.0;
                                    setState(() => _fullScreen = false);
                                  } else if (v < -250 || _fsVerticalDragDist < -60) {
                                    _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
                                  }
                                  _fsVerticalDragDist = 0.0;
                                },
                                child: Column(
                                  children: [
                                    const SizedBox(height: 22),
                                    _fullScreenSlider(),
                                    _fullScreenControls(),
                                    const SizedBox(height: 12),
                                    SizedBox(height: collapsedHeight + 14),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Bottom-to-top Queue Scroller (YT Music style)
            AnimatedBuilder(
              animation: _queueAnim,
              builder: (context, _) {
                final animVal = _queueAnim.value;
                final currentHeight =
                    ui.lerpDouble(collapsedHeight, maxSheetHeight, animVal)!;
                final isExpanded = animVal > 0.03;

                return Stack(
                  children: [
                    if (isExpanded)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _queueAnim.animateTo(
                            0.0,
                            curve: Curves.easeOutCubic,
                          ),
                          onVerticalDragUpdate: (details) =>
                              _onQueueDragUpdate(
                            details,
                            collapsedHeight,
                            maxSheetHeight,
                          ),
                          onVerticalDragEnd: _onQueueDragEnd,
                          child: Container(
                            color:
                                Colors.black.withValues(alpha: 0.48 * animVal),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: currentHeight,
                      child: _buildUpNextSheet(
                        track: track,
                        artworkColor: artworkColor,
                        animVal: animVal,
                        collapsedHeight: collapsedHeight,
                        maxHeight: maxSheetHeight,
                        bottomPadding: bottomPadding,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      );
    },
  );
}

  Widget _fullScreenControls() {
    final shuffleActive = _isShuffle;
    final repeatActive = _repeatMode != PlaybackRepeatMode.off;
    final activeColor =
        _isLight ? const Color(0xff2563eb) : const Color(0xff60a5fa);
    final inactiveColor = _textColor.withValues(alpha: 0.50);

    final IconData repeatIcon = switch (_repeatMode) {
      PlaybackRepeatMode.off => PhosphorIconsRegular.repeat,
      PlaybackRepeatMode.all => PhosphorIconsRegular.repeat,
      PlaybackRepeatMode.one => PhosphorIconsRegular.repeatOnce,
    };

    final String repeatTooltip = switch (_repeatMode) {
      PlaybackRepeatMode.off => 'Repeat: Off',
      PlaybackRepeatMode.all => 'Repeat: All',
      PlaybackRepeatMode.one => 'Repeat: One',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: _toggleShuffle,
            splashRadius: 22,
            icon: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  PhosphorIconsRegular.shuffle,
                  size: 22,
                  color: shuffleActive ? activeColor : inactiveColor,
                ),
                const SizedBox(height: 3),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: shuffleActive ? activeColor : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            tooltip: shuffleActive ? 'Shuffle: On' : 'Shuffle: Off',
          ),
          IconButton(
            onPressed: _previous,
            splashRadius: 26,
            icon: Icon(
              PhosphorIconsRegular.skipBack,
              size: 30,
              color: _textColor,
            ),
            tooltip: 'Previous',
          ),
          _buildPlayPauseButton(
            iconSize: 62,
            spinnerSize: 50,
            strokeWidth: 3.0,
            color: _textColor,
          ),
          IconButton(
            onPressed: _next,
            splashRadius: 26,
            icon: Icon(
              PhosphorIconsRegular.skipForward,
              size: 30,
              color: _textColor,
            ),
            tooltip: 'Next',
          ),
          IconButton(
            onPressed: _toggleRepeatMode,
            splashRadius: 22,
            icon: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  repeatIcon,
                  size: 22,
                  color: repeatActive ? activeColor : inactiveColor,
                ),
                const SizedBox(height: 3),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: repeatActive ? activeColor : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            tooltip: repeatTooltip,
          ),
        ],
      ),
    );
  }

  Widget _fullScreenSlider() => StreamBuilder<Duration?>(
    stream: _audio.durationStream,
    initialData: _currentTrackDuration,
    builder: (_, durationSnapshot) {
      var duration = durationSnapshot.data ?? _currentTrackDuration;
      if (duration == null || duration == Duration.zero) {
        if (_current != null && _current!.duration > 0) {
          duration = Duration(seconds: _current!.duration);
        }
      }
      duration ??= Duration.zero;
      final maxMs = duration.inMilliseconds.toDouble();
      return StreamBuilder<Duration>(
        stream: _audio.positionStream,
        initialData: _audio.position,
        builder: (_, positionSnapshot) {
          final position = positionSnapshot.data ?? _audio.position;
          final value = maxMs <= 0
              ? 0.0
              : position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor:
                        _isLight ? const Color(0xff0f172a) : Colors.white,
                    inactiveTrackColor: _isLight
                        ? Colors.black.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.24),
                    thumbColor:
                        _isLight ? const Color(0xff0f172a) : Colors.white,
                    overlayColor: _isLight
                        ? const Color(0x1a0f172a)
                        : const Color(0x26ffffff),
                    trackHeight: 3.5,
                  ),
                  child: Slider(
                    value: value,
                    max: maxMs <= 0 ? 1 : maxMs,
                    onChanged: maxMs <= 0
                        ? null
                        : (v) => _audio.seek(Duration(milliseconds: v.round())),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _time(position),
                      style: TextStyle(
                        color: _subtextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _time(duration!),
                      style: TextStyle(
                        color: _subtextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );

  Widget _fullScreenTab({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: active
            ? (_isLight ? Colors.white : Colors.white)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        boxShadow: active && _isLight
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 17,
            color: active
                ? (_isLight ? const Color(0xff0f172a) : _ink)
                : (_isLight ? const Color(0xff64748b) : Colors.white70),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: active
                  ? (_isLight ? const Color(0xff0f172a) : _ink)
                  : (_isLight ? const Color(0xff64748b) : Colors.white70),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    ),
  );

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  /* --------------------------- UP NEXT QUEUE (YT MUSIC STYLE) ---------------- */

  List<Song> get _upcomingQueue {
    final list = <Song>[];
    if (_playbackHistoryIndex >= 0 &&
        _playbackHistoryIndex < _playbackHistory.length - 1) {
      list.addAll(_playbackHistory.sublist(_playbackHistoryIndex + 1));
    }
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isNotEmpty) {
        for (int i = 1; i < _playlistQueue.length; i++) {
          final idx = (_playlistQueueIndex + i) % _playlistQueue.length;
          list.add(_playlistQueue[idx]);
        }
      }
    } else {
      list.addAll(_suggestionQueue);
    }
    return list;
  }

  void _playFromQueue(int targetIdx) {
    if (_playbackHistoryIndex >= 0 &&
        _playbackHistoryIndex < _playbackHistory.length - 1) {
      final historyForwardCount =
          _playbackHistory.length - 1 - _playbackHistoryIndex;
      if (targetIdx < historyForwardCount) {
        _playbackHistoryIndex += (targetIdx + 1);
        _play(_playbackHistory[_playbackHistoryIndex],
            isHistoryNavigation: true);
        return;
      }
      targetIdx -= historyForwardCount;
    }

    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isNotEmpty) {
        _playlistQueueIndex =
            (_playlistQueueIndex + 1 + targetIdx) % _playlistQueue.length;
        _play(_playlistQueue[_playlistQueueIndex]);
      }
    } else {
      if (targetIdx >= 0 && targetIdx < _suggestionQueue.length) {
        final songToPlay = _suggestionQueue[targetIdx];
        _suggestionQueue.removeRange(0, targetIdx + 1);
        _play(songToPlay);
        if (_suggestionQueue.isEmpty) {
          unawaited(_fetchSuggestions(songToPlay.id));
        }
      }
    }
  }

  void _toggleRepeatMode() {
    setState(() {
      switch (_repeatMode) {
        case PlaybackRepeatMode.off:
          _repeatMode = PlaybackRepeatMode.all;
          break;
        case PlaybackRepeatMode.all:
          _repeatMode = PlaybackRepeatMode.one;
          break;
        case PlaybackRepeatMode.one:
          _repeatMode = PlaybackRepeatMode.off;
          break;
      }
    });
    UserStorage.saveRepeatMode(_repeatMode.name);
  }

  void _toggleShuffle() {
    setState(() {
      _isShuffle = !_isShuffle;
      if (_isShuffle) {
        if (_playbackMode == PlaybackMode.playlist) {
          if (_unshuffledPlaylist.isEmpty && _playlistQueue.isNotEmpty) {
            _unshuffledPlaylist = List<Song>.from(_playlistQueue);
          }
          _shuffleQueue();
        } else {
          if (_suggestionQueue.length > 1) {
            _suggestionQueue.shuffle();
          }
        }
      } else {
        if (_playbackMode == PlaybackMode.playlist &&
            _unshuffledPlaylist.isNotEmpty) {
          final cur = _current;
          _playlistQueue = List<Song>.from(_unshuffledPlaylist);
          if (cur != null) {
            final idx = _playlistQueue.indexWhere((s) => s.id == cur.id);
            _playlistQueueIndex = idx >= 0 ? idx : 0;
          }
        }
      }
    });
    UserStorage.saveShuffle(_isShuffle);
  }

  void _shuffleQueue() {
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.length > 2) {
        final currentSong = _playlistQueue[_playlistQueueIndex];
        final remaining = <Song>[];
        for (int i = 0; i < _playlistQueue.length; i++) {
          if (i != _playlistQueueIndex) remaining.add(_playlistQueue[i]);
        }
        remaining.shuffle();
        _playlistQueue = [currentSong, ...remaining];
        _playlistQueueIndex = 0;
        setState(() {});
      }
    } else {
      if (_suggestionQueue.length > 1) {
        _suggestionQueue.shuffle();
        setState(() {});
      }
    }
  }

  void _removeFromQueue(Song song) {
    setState(() {
      // 1. Remove from playlist queue (active playlist loop)
      final currentSong = (_playlistQueueIndex >= 0 && _playlistQueueIndex < _playlistQueue.length)
          ? _playlistQueue[_playlistQueueIndex]
          : null;
      _playlistQueue.removeWhere(
          (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == song.streamUrl));
      if (_playlistQueue.isEmpty) {
        _playlistQueueIndex = -1;
      } else if (currentSong != null) {
        final newIdx = _playlistQueue.indexWhere(
            (s) => s.id == currentSong.id || (s.streamUrl != null && s.streamUrl == currentSong.streamUrl));
        if (newIdx != -1) {
          _playlistQueueIndex = newIdx;
        } else {
          _playlistQueueIndex = _playlistQueueIndex.clamp(0, _playlistQueue.length - 1);
        }
      } else {
        _playlistQueueIndex = _playlistQueueIndex.clamp(0, _playlistQueue.length - 1);
      }

      // 2. Remove from suggestion queue (Up Next in suggestion mode)
      _suggestionQueue.removeWhere(
          (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == song.streamUrl));

      // 3. Remove from playback history forward queue (Up Next from history)
      _playbackHistory.removeWhere(
          (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == song.streamUrl));
      if (_playbackHistoryIndex >= _playbackHistory.length) {
        _playbackHistoryIndex = _playbackHistory.length - 1;
      }

      // 4. Invalidate prepared song and reset crossfade buffer if it was the removed track
      if (_preparedSong?.id == song.id ||
          (_preparedStreamUrl != null && _preparedStreamUrl == song.streamUrl)) {
        _preparedSong = null;
        _preparedStreamUrl = null;
        _audio.clearPrepared();
      }
    });
  }

  void _reorderQueueItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final currentUpcoming = List<Song>.from(_upcomingQueue);
    if (oldIndex < 0 || oldIndex >= currentUpcoming.length) return;
    if (newIndex < 0 || newIndex >= currentUpcoming.length) return;

    final movedSong = currentUpcoming.removeAt(oldIndex);
    currentUpcoming.insert(newIndex, movedSong);

    setState(() {
      _preparedSong = null;
      _preparedStreamUrl = null;

      if (_playbackHistoryIndex >= 0 &&
          _playbackHistoryIndex < _playbackHistory.length - 1) {
        _playbackHistory.removeRange(
          _playbackHistoryIndex + 1,
          _playbackHistory.length,
        );
      }

      if (_playbackMode == PlaybackMode.playlist) {
        if (_current != null) {
          _playlistQueue = [_current!, ...currentUpcoming];
          _playlistQueueIndex = 0;
        } else {
          _playlistQueue = currentUpcoming;
          _playlistQueueIndex = -1;
        }
      } else {
        _suggestionQueue = currentUpcoming;
      }
    });
  }

  void _onQueueDragUpdate(
    DragUpdateDetails details,
    double collapsedHeight,
    double maxHeight,
  ) {
    final travelDistance = maxHeight - collapsedHeight;
    if (travelDistance <= 0) return;
    final delta = details.primaryDelta ?? 0.0;
    _queueAnim.value =
        (_queueAnim.value - (delta / travelDistance)).clamp(0.0, 1.0);
  }

  void _onQueueDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0.0;
    if (velocity < -120) {
      _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
    } else if (velocity > 80) {
      _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
    } else if (_queueAnim.value < 0.70) {
      _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
    } else {
      _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
    }
  }

  Widget _buildUpNextSheet({
    required Song track,
    required Color artworkColor,
    required double animVal,
    required double collapsedHeight,
    required double maxHeight,
    required double bottomPadding,
  }) {
    final queue = _upcomingQueue;
    final solidSheetBg = _isLight ? Colors.white : const Color(0xff16161b);
    final collapsedSheetBg = _isLight
        ? Colors.white.withValues(alpha: 0.62)
        : const Color(0xff141418).withValues(alpha: 0.52);
    final sheetBgColor =
        Color.lerp(collapsedSheetBg, solidSheetBg, animVal)!;

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22 + 0.18 * animVal),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: sheetBgColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              border: Border(
                top: BorderSide(
                  color: _isLight
                      ? Colors.black.withValues(alpha: 0.08 + 0.04 * animVal)
                      : Colors.white.withValues(alpha: 0.14 + 0.06 * animVal),
                  width: 1.0,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildUpNextHeader(
                  queue: queue,
                  animVal: animVal,
                  collapsedHeight: collapsedHeight,
                  maxHeight: maxHeight,
                  bottomPadding: bottomPadding,
                ),
                Expanded(
                  child: animVal > 0.03
                      ? Opacity(
                          opacity: ((animVal - 0.03) / 0.20).clamp(0.0, 1.0),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is OverscrollNotification) {
                                if (notification.overscroll < -12) {
                                  _queueAnim.animateTo(
                                    0.0,
                                    curve: Curves.easeOutCubic,
                                  );
                                  return true;
                                }
                              } else if (notification
                                  is ScrollUpdateNotification) {
                                if (notification.metrics.pixels <= 0 &&
                                    (notification.scrollDelta ?? 0) < -12) {
                                  _queueAnim.animateTo(
                                    0.0,
                                    curve: Curves.easeOutCubic,
                                  );
                                  return true;
                                }
                              } else if (notification
                                  is ScrollEndNotification) {
                                final v = notification
                                        .dragDetails?.primaryVelocity ??
                                    0.0;
                                if (notification.metrics.pixels <= 5 &&
                                    (v > 100 ||
                                        notification.metrics.pixels < -10)) {
                                  _queueAnim.animateTo(
                                    0.0,
                                    curve: Curves.easeOutCubic,
                                  );
                                  return true;
                                }
                              }
                              return false;
                            },
                            child: _buildQueueList(track, queue),
                          ),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _queueAnim.animateTo(
                            1.0,
                            curve: Curves.easeOutCubic,
                          ),
                          onVerticalDragUpdate: (details) =>
                              _onQueueDragUpdate(
                            details,
                            collapsedHeight,
                            maxHeight,
                          ),
                          onVerticalDragEnd: _onQueueDragEnd,
                          child: const SizedBox.expand(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpNextHeader({
    required List<Song> queue,
    required double animVal,
    required double collapsedHeight,
    required double maxHeight,
    required double bottomPadding,
  }) {
    final bottomInset = bottomPadding * (1.0 - animVal).clamp(0.0, 1.0);
    final activeColor =
        _isLight ? const Color(0xff2563eb) : const Color(0xff60a5fa);
    final shuffleActive = _isShuffle;
    final repeatActive = _repeatMode != PlaybackRepeatMode.off;

    final IconData repeatIcon = switch (_repeatMode) {
      PlaybackRepeatMode.off => PhosphorIconsRegular.repeat,
      PlaybackRepeatMode.all => PhosphorIconsRegular.repeat,
      PlaybackRepeatMode.one => PhosphorIconsRegular.repeatOnce,
    };

    final String repeatTooltip = switch (_repeatMode) {
      PlaybackRepeatMode.off => 'Repeat: Off',
      PlaybackRepeatMode.all => 'Repeat: All',
      PlaybackRepeatMode.one => 'Repeat: One',
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_queueAnim.value < 0.5) {
          _queueAnim.animateTo(1.0, curve: Curves.easeOutCubic);
        } else {
          _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
        }
      },
      onVerticalDragUpdate: (details) =>
          _onQueueDragUpdate(details, collapsedHeight, maxHeight),
      onVerticalDragEnd: _onQueueDragEnd,
      child: Container(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 7),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _isLight
                      ? Colors.black.withValues(alpha: 0.20 + 0.10 * animVal)
                      : Colors.white.withValues(alpha: 0.24 + 0.10 * animVal),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 36,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Collapsed header row
                  Opacity(
                    opacity: (1.0 - animVal * 2.5).clamp(0.0, 1.0),
                    child: IgnorePointer(
                      ignoring: animVal > 0.15,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              PhosphorIconsRegular.playlist,
                              size: 17,
                              color: _textColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'UP NEXT',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: _textColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: _isLight
                                    ? Colors.black.withValues(alpha: 0.08)
                                    : Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${queue.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: _textColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            if (queue.isNotEmpty)
                              Expanded(
                                child: Text(
                                  'Next: ${queue.first.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _subtextColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            const SizedBox(width: 6),
                            Icon(
                              PhosphorIconsRegular.caretUp,
                              size: 16,
                              color: _subtextColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Expanded header row
                  Opacity(
                    opacity: ((animVal - 0.15) * 2.5).clamp(0.0, 1.0),
                    child: IgnorePointer(
                      ignoring: animVal < 0.15,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                        child: Row(
                          children: [
                            Icon(
                              PhosphorIconsRegular.playlist,
                              size: 20,
                              color: _textColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Up Next',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: _textColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _isLight
                                    ? Colors.black.withValues(alpha: 0.06)
                                    : Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${queue.length} ${queue.length == 1 ? 'song' : 'songs'}',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: _textColor,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Shuffle button
                          IconButton(
                            onPressed: _toggleShuffle,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            splashRadius: 18,
                            icon: Icon(
                              PhosphorIconsRegular.shuffle,
                              size: 19,
                              color: shuffleActive
                                  ? activeColor
                                  : _subtextColor,
                            ),
                            tooltip: shuffleActive
                                ? 'Shuffle: On'
                                : 'Shuffle: Off',
                          ),
                          const SizedBox(width: 4),
                          // Repeat button (Repeat One / Repeat All / Off)
                          IconButton(
                            onPressed: _toggleRepeatMode,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            splashRadius: 18,
                            icon: Icon(
                              repeatIcon,
                              size: 19,
                              color: repeatActive
                                  ? activeColor
                                  : _subtextColor,
                            ),
                            tooltip: repeatTooltip,
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: () => _queueAnim.animateTo(
                              0.0,
                              curve: Curves.easeOutCubic,
                            ),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            splashRadius: 18,
                            icon: Icon(
                              PhosphorIconsRegular.caretDown,
                              size: 20,
                              color: _textColor,
                            ),
                            tooltip: 'Collapse',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              ),
            ),
            if (animVal > 0.05)
              Opacity(
                opacity: animVal.clamp(0.0, 1.0),
                child: Divider(color: _borderColor, height: 1),
              ),
            if (bottomInset > 0) SizedBox(height: bottomInset),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueNowPlayingCard(Song currentSong) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'NOW PLAYING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: _subtextColor,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isLight
                ? const Color(0xff0f172a).withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isLight
                  ? const Color(0x18000000)
                  : Colors.white.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _art(currentSong.artwork, width: 44, height: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentSong.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentSong.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: _subtextColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                PhosphorIconsRegular.waveform,
                size: 20,
                color: _isLight ? const Color(0xff0f172a) : Colors.white,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQueueList(Song currentSong, List<Song> queue) {
    if (queue.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          10,
          16,
          math.max(MediaQuery.paddingOf(context).bottom, 16.0) + 12.0,
        ),
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 100) {
                _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
              }
            },
            child: _buildQueueNowPlayingCard(currentSong),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'UP NEXT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: _subtextColor,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    PhosphorIconsRegular.musicNotes,
                    size: 36,
                    color: _subtextColor.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'No more tracks in queue',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Suggestions will be added automatically as playback continues.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _subtextColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ReorderableListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        math.max(MediaQuery.paddingOf(context).bottom, 16.0) + 16.0,
      ),
      header: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 100) {
            _queueAnim.animateTo(0.0, curve: Curves.easeOutCubic);
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildQueueNowPlayingCard(currentSong),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'UP NEXT',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      color: _subtextColor,
                    ),
                  ),
                  Text(
                    'Hold or drag to reorder',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _subtextColor.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      itemCount: queue.length,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(animation.value);
            return Material(
              elevation: 10.0 * t,
              color: _isLight
                  ? Colors.white
                  : const Color(0xff22222a),
              shadowColor: Colors.black.withValues(alpha: 0.5 * t),
              borderRadius: BorderRadius.circular(12),
              child: child,
            );
          },
        );
      },
      itemBuilder: (context, i) {
        final song = queue[i];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('queue_song_${song.id}_${identityHashCode(song)}'),
          index: i,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildQueueItem(song, i),
              if (i < queue.length - 1)
                Divider(
                  color: _borderColor,
                  height: 1,
                  indent: 56,
                ),
            ],
          ),
        );
      },
      onReorderItem: _reorderQueueItem,
    );
  }

  Widget _buildQueueItem(Song song, int index) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _playFromQueue(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _subtextColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _art(song.artwork, width: 44, height: 44),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _subtextColor,
                    ),
                  ),
                ],
              ),
            ),
            if (song.duration > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  _time(Duration(seconds: song.duration)),
                  style: TextStyle(
                    fontSize: 12,
                    color: _subtextColor,
                  ),
                ),
              ),
            IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              splashRadius: 16,
              icon: Icon(
                PhosphorIconsRegular.x,
                size: 16,
                color: _subtextColor.withValues(alpha: 0.6),
              ),
              onPressed: () => _removeFromQueue(song),
              tooltip: 'Remove from queue',
            ),
            const SizedBox(width: 4),
            ReorderableDragStartListener(
              index: index,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Icon(
                  PhosphorIconsRegular.dotsSixVertical,
                  size: 20,
                  color: _subtextColor.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* -------------------------- LIKED SONGS & SETTINGS ----------------------- */

  Future<void> _loadLikedSongs() async {
    try {
      final rawList = await UserStorage.getLikedSongsRaw();
      final loaded = <String, Song>{};
      for (final item in rawList) {
        final song = Song.fromJson(item);
        loaded[song.id] = song;
      }
      if (mounted) {
        setState(() => _likedSongs = loaded);
      }
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    try {
      final rawList = await UserStorage.getHistorySongsRaw();
      final loaded = rawList
          .map((item) => Song.fromJson(item))
          .take(AppConstants.historyLimit)
          .toList();
      if (mounted) {
        setState(() => _history = loaded);
      }
    } catch (_) {}
  }

  Future<void> _loadEqualizer() async {
    final en = await UserStorage.getEqualizerEnabled();
    final p = await UserStorage.getEqualizerPreset();
    final b = await UserStorage.getEqualizerBands();
    final bb = await UserStorage.getEqualizerBassBoost();
    if (mounted) {
      setState(() {
        _eqEnabled = en;
        _eqPreset = p;
        _eqBands = b;
        _eqBassBoost = bb;
      });
    }
    await _audio.setEqualizerEnabled(en);
    await _audio.setAllEqualizerBands(b);
    await _audio.setBassBoost(bb);
  }

  void _openEqualizerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _EqualizerBottomSheet(
        audio: _audio,
        initialEnabled: _eqEnabled,
        initialPreset: _eqPreset,
        initialBands: List<double>.from(_eqBands),
        initialBassBoost: _eqBassBoost,
        onChanged: (enabled, preset, bands, bassBoost) {
          setState(() {
            _eqEnabled = enabled;
            _eqPreset = preset;
            _eqBands = List<double>.from(bands);
            _eqBassBoost = bassBoost;
          });
        },
      ),
    );
  }

  void _onSongMeaningfullyPlayed(Song song) {
    // 1. Update persistent Recently Played UI list (unique, updated to top, max 10)
    _history.removeWhere((item) => item.id == song.id);
    _history.insert(0, song);
    if (_history.length > AppConstants.historyLimit) {
      _history = _history.take(AppConstants.historyLimit).toList();
    }
    unawaited(UserStorage.saveHistorySongsRaw(
      _history.map((s) => s.toJson()).toList(),
    ));

    // 2. Update session playback history sequence (preserves repetitions)
    if (!_isNavigatingHistory) {
      _playbackHistory.add(song);
      _playbackHistoryIndex = _playbackHistory.length - 1;
    }
  }

  Future<void> _clearHistory() async {
    setState(() {
      _history = [];
      _playbackHistory.clear();
      _playbackHistoryIndex = -1;
    });
    await UserStorage.saveHistorySongsRaw([]);
  }

  Future<void> _toggleLike(Song song) async {
    final currentlyLiked = _likedSongs.containsKey(song.id);
    final updated = Map<String, Song>.from(_likedSongs);
    if (currentlyLiked) {
      updated.remove(song.id);
      _removeFromQueue(song);
    } else {
      updated[song.id] = song;
    }
    setState(() => _likedSongs = updated);

    final rawList = updated.values.map((s) => s.toJson()).toList();
    await UserStorage.saveLikedSongsRaw(rawList);
  }

  Future<void> _openUserMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.paddingOf(ctx).bottom,
          ),
          decoration: BoxDecoration(
            color: _sheetBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: _borderColor)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _isLight ? const Color(0x20000000) : Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xfff1f5f9)
                        : Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _borderColor),
                  ),
                  child: Icon(
                    PhosphorIconsFill.heart,
                    color: _textColor,
                    size: 22,
                  ),
                ),
                title: Text(
                  'Liked Songs',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                subtitle: Text(
                  '${_likedSongs.length} ${_likedSongs.length == 1 ? 'track' : 'tracks'}',
                  style: TextStyle(fontSize: 12, color: _subtextColor),
                ),
                trailing: Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _subtextColor,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop('liked');
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xfff1f5f9)
                        : Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _borderColor),
                  ),
                  child: Icon(
                    PhosphorIconsRegular.musicNotes,
                    color: _textColor,
                    size: 22,
                  ),
                ),
                title: Text(
                  'Offline Songs',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                subtitle: Text(
                  '${_offlineSongs.length} ${_offlineSongs.length == 1 ? 'device track' : 'device tracks'}',
                  style: TextStyle(fontSize: 12, color: _subtextColor),
                ),
                trailing: Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _subtextColor,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop('offline');
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xfff1f5f9)
                        : Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _borderColor),
                  ),
                  child: Icon(
                    PhosphorIconsRegular.slidersHorizontal,
                    color: _eqEnabled ? const Color(0xff3B82F6) : _textColor,
                    size: 22,
                  ),
                ),
                title: Text(
                  'Equalizer',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                subtitle: Text(
                  _eqEnabled ? 'Active · $_eqPreset' : 'Off (Original Audio)',
                  style: TextStyle(fontSize: 12, color: _subtextColor),
                ),
                trailing: Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _subtextColor,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop('equalizer');
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isLight
                        ? const Color(0xfff1f5f9)
                        : Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _borderColor),
                  ),
                  child: Icon(
                    PhosphorIconsRegular.gearSix,
                    color: _textColor,
                    size: 22,
                  ),
                ),
                title: Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                subtitle: Text(
                  'Audio quality, theme & profile preferences',
                  style: TextStyle(fontSize: 12, color: _subtextColor),
                ),
                trailing: Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _subtextColor,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop('settings');
                },
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted) return;
    if (choice == 'settings') {
      _openSettings();
    } else if (choice == 'equalizer') {
      _openEqualizerSheet();
    } else if (choice == 'liked') {
      setState(() {
        _viewingLikedSongs = true;
        _viewingOfflineSongs = false;
        _openedPlaylist = null;
        _homeMode = false;
      });
    } else if (choice == 'offline') {
      setState(() {
        _viewingOfflineSongs = true;
        _viewingLikedSongs = false;
        _openedPlaylist = null;
        _homeMode = false;
      });
      if (_offlineSongs.isEmpty && !_isScanningOffline) {
        unawaited(_scanDeviceForAudio(showFeedback: false));
      }
    }
  }

  Duration? get _sleepTimerRemaining {
    if (_sleepTimerEndTime == null) return null;
    final diff = _sleepTimerEndTime!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  void _setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    if (duration <= Duration.zero) {
      setState(() {
        _sleepTimer = null;
        _sleepTimerEndTime = null;
      });
      return;
    }
    setState(() {
      _sleepTimerEndTime = DateTime.now().add(duration);
    });
    _sleepTimer = Timer(duration, () async {
      await _audio.pause();
      if (mounted) {
        setState(() {
          _sleepTimer = null;
          _sleepTimerEndTime = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(
                  PhosphorIconsRegular.moonStars,
                  color: Colors.white,
                  size: 20,
                ),
                SizedBox(width: 10),
                Text(
                  'Sleep timer reached. Music paused.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            backgroundColor: const Color(0xee1c1c22),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    setState(() {
      _sleepTimer = null;
      _sleepTimerEndTime = null;
    });
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SettingsBottomSheet(
        userProfile: _userProfile,
        currentQuality: _songQuality,
        currentTheme: _themeMode,
        currentLanguage: _musicLanguage,
        sleepTimerEndTime: _sleepTimerEndTime,
        getSleepTimerRemaining: () => _sleepTimerRemaining,
        onSaveProfile: (name, age) async {
          final updated = UserProfile(
            name: name,
            age: age,
            language: _musicLanguage,
          );
          await UserStorage.saveProfile(
            name: name,
            age: age,
            language: _musicLanguage,
          );
          if (mounted) {
            setState(() => _userProfile = updated);
          }
        },
        onSetSleepTimer: (duration) {
          _setSleepTimer(duration);
        },
        onCancelSleepTimer: () {
          _cancelSleepTimer();
        },
        onThemeChanged: (theme) async {
          if (mounted) {
            setState(() => _themeMode = theme);
          }
          widget.onAppThemeChanged?.call(theme);
          await UserStorage.saveThemeMode(theme);
        },
        onQualityChanged: (quality) async {
          if (mounted) {
            setState(() => _songQuality = quality);
          }
          await UserStorage.saveSongQuality(quality);
        },
        onLanguageChanged: (lang) async {
          if (mounted) {
            setState(() => _musicLanguage = lang);
          }
          await UserStorage.saveLanguage(lang);
          if (_userProfile != null) {
            _userProfile = _userProfile!.copyWith(language: lang);
          }
        },
      ),
    );
  }

  void _showSongOptions(Song song, [List<Song>? contextQueue]) {
    final isLiked = _likedSongs.containsKey(song.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: BoxDecoration(
          color: _sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: _borderColor)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _isLight ? const Color(0x20000000) : Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _art(song.artwork, width: 56, height: 56),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: _textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: _subtextColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Divider(color: _dividerColor, height: 1),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _textColor,
                size: 24,
              ),
              title: Text(
                isLiked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isLiked ? Colors.redAccent : _textColor,
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleLike(song);
              },
            ),
            if (_openedPlaylist != null &&
                _openedPlaylist!.songs.any((s) => s.id == song.id))
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(
                  PhosphorIconsRegular.trash,
                  color: Colors.redAccent,
                  size: 24,
                ),
                title: const Text(
                  'Remove from Playlist',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.redAccent,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _openedPlaylist!.songs.removeWhere((s) => s.id == song.id);
                  });
                  _removeFromQueue(song);
                },
              ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                PhosphorIconsBold.play,
                color: _textColor,
                size: 24,
              ),
              title: Text(
                'Play Song',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _textColor,
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _playSongForSuggestionMode(song);
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                PhosphorIconsBold.downloadSimple,
                color: _textColor,
                size: 24,
              ),
              title: Text(
                'Download',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _textColor,
                ),
              ),
              subtitle: Text(
                'Get audio in $_songQuality',
                style: TextStyle(fontSize: 12, color: _subtextColor),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _download(song);
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                PhosphorIconsRegular.slidersHorizontal,
                color: _textColor,
                size: 24,
              ),
              title: Text(
                'Equalizer',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _textColor,
                ),
              ),
              subtitle: Text(
                _eqEnabled ? 'Active · $_eqPreset' : 'Off (Original Audio)',
                style: TextStyle(fontSize: 12, color: _subtextColor),
              ),
              trailing: Icon(
                PhosphorIconsRegular.caretRight,
                size: 18,
                color: _subtextColor,
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _openEqualizerSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  /* ---------------------------- LIKED SONGS VIEW -------------------------- */

  Widget _likedSongsHeader() => Container(
    padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
    decoration: BoxDecoration(
      color: _headerBg,
      border: Border(bottom: BorderSide(color: _borderColor)),
    ),
    child: Row(
      children: [
        IconButton(
          icon: Icon(PhosphorIconsRegular.arrowLeft, size: 22, color: _textColor),
          onPressed: () => setState(() => _viewingLikedSongs = false),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            'Liked Songs',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _textColor,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _likedSongsView() {
    final songs = _likedSongs.values.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  colors: [Color(0xffff416c), Color(0xffff4b2b)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xffff416c).withValues(alpha: .35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  PhosphorIconsFill.heart,
                  color: Colors.white,
                  size: 64,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Liked Songs',
                    style: GoogleFonts.manrope(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: _textColor,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _userProfile != null && _userProfile!.name.isNotEmpty
                        ? 'Curated by ${_userProfile!.name}'
                        : 'Your personal collection',
                    style: TextStyle(color: _subtextColor, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _subtextColor,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (songs.isNotEmpty)
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            _playPlaylist(songs);
                          },
                          icon: Icon(
                            PhosphorIconsBold.play,
                            size: 16,
                            color: _isLight ? Colors.white : Colors.black,
                          ),
                          label: Text(
                            'Play All',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _isLight ? Colors.white : Colors.black,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isLight ? const Color(0xff0f172a) : Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () {
                            final shuffled = [...songs]..shuffle();
                            _playPlaylist(shuffled);
                          },
                          icon: Icon(
                            PhosphorIconsRegular.shuffle,
                            size: 20,
                            color: _textColor,
                          ),
                          tooltip: 'Shuffle',
                          style: IconButton.styleFrom(
                            backgroundColor: _isLight
                                ? const Color(0xff0f172a).withValues(alpha: .07)
                                : Colors.white.withValues(alpha: .1),
                            shape: const CircleBorder(),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (songs.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Column(
              children: [
                Icon(
                  PhosphorIconsRegular.heart,
                  size: 56,
                  color: _isLight
                      ? const Color(0x30000000)
                      : Colors.white.withValues(alpha: .2),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Liked Songs Yet',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the heart icon on any song to save it here permanently.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _subtextColor, fontSize: 13),
                ),
              ],
            ),
          )
        else ...[
          Text(
            'Tracks',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _textColor,
            ),
          ),
          const SizedBox(height: 12),
          ...songs.asMap().entries.map(
            (entry) => _likedSongRow(entry.key, entry.value, songs),
          ),
        ],
      ],
    );
  }

  Widget _likedSongRow(int index, Song song, List<Song> likedList) {
    final isCurrent = _current?.id == song.id;
    final isLiked = _likedSongs.containsKey(song.id);
    return InkWell(
      onTap: () => _playSongForSuggestionMode(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 28,
              alignment: Alignment.centerLeft,
              child: isCurrent && _audio.playing
                  ? Icon(
                      PhosphorIconsFill.play,
                      size: 14,
                      color: _isLight
                          ? const Color(0xff0f172a)
                          : Colors.white,
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isCurrent ? _textColor : _subtextColor,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppConstants.songRowThumbnailRadius,
              ),
              child: _art(song.artwork, width: 48, height: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isCurrent
                          ? (_isLight ? const Color(0xff2563eb) : const Color(0xff60a5fa))
                          : _textColor.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _subtextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (song.duration > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  _time(Duration(seconds: song.duration)),
                  style: TextStyle(color: _subtextColor, fontSize: 11),
                ),
              ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _subtextColor,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, likedList),
              icon: Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
                color: _subtextColor,
              ),
              tooltip: 'More options',
            ),
          ],
        ),
      ),
    );
  }

  /* --------------------------- OFFLINE SONGS (DEVICE) ---------------------- */

  Future<void> _loadOfflineSongs() async {
    try {
      final rawList = await UserStorage.getOfflineSongsRaw();
      final loaded = <Song>[];
      for (final item in rawList) {
        final song = Song.fromJson(item);
        final stream = song.streamUrl;
        if (stream != null && stream.isNotEmpty) {
          final lower = stream.toLowerCase();
          // Exclude any WhatsApp voice notes or files
          if (lower.contains('whatsapp') ||
              lower.contains('com.whatsapp') ||
              lower.endsWith('.opus')) {
            continue;
          }
          final clean = stream.startsWith('file://') ? Uri.parse(stream).toFilePath() : stream;
          final file = File(clean);
          if (await file.exists()) {
            loaded.add(song);
          }
        }
      }
      if (mounted) {
        setState(() => _offlineSongs = loaded);
      }
      // If any WhatsApp audio was purged, save the cleaned list back to storage
      if (loaded.length != rawList.length) {
        unawaited(UserStorage.saveOfflineSongsRaw(loaded.map((s) => s.toJson()).toList()));
      }
    } catch (_) {}
  }

  Future<void> _saveOfflineSongs() async {
    try {
      final list = _offlineSongs.map((s) => s.toJson()).toList();
      await UserStorage.saveOfflineSongsRaw(list);
    } catch (_) {}
  }

  Song _fileToSong(File file) {
    final fileName = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'Unknown Audio';
    String cleanTitle = fileName;
    final dotIndex = cleanTitle.lastIndexOf('.');
    if (dotIndex > 0) {
      cleanTitle = cleanTitle.substring(0, dotIndex);
    }
    String artist = 'Device Audio';
    String title = cleanTitle;
    if (cleanTitle.contains(' - ')) {
      final parts = cleanTitle.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      }
    } else if (cleanTitle.contains('-')) {
      final parts = cleanTitle.split('-');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.sublist(1).join('-').trim();
      }
    }
    return Song(
      id: 'offline_${file.path}',
      title: title.isEmpty ? 'Unknown Track' : title,
      artist: artist.isEmpty ? 'Device Audio' : artist,
      album: 'Device Storage',
      artwork: '',
      streamUrl: file.path,
    );
  }

  Future<void> _scanDeviceForAudio({bool showFeedback = true}) async {
    if (_isScanningOffline) return;
    setState(() => _isScanningOffline = true);

    int newlyFound = 0;
    try {
      final currentPaths = _offlineSongs
          .map((s) => s.streamUrl)
          .whereType<String>()
          .toSet();
      final added = <Song>[];

      // 1. High-speed native Android MediaStore query (runs on native background worker thread)
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.song_player_mobile/offline_audio');
          await channel.invokeMethod<bool>('requestStoragePermission');
          final mediaFiles = await channel.invokeListMethod<Map>('getAudioFiles');
          if (mediaFiles != null) {
            for (final item in mediaFiles) {
              final path = item['path']?.toString();
              if (path != null && path.isNotEmpty) {
                final lower = path.toLowerCase();
                if (lower.contains('whatsapp') ||
                    lower.contains('com.whatsapp') ||
                    lower.endsWith('.opus')) {
                  continue;
                }
                if (!currentPaths.contains(path)) {
                  currentPaths.add(path);
                  final title = item['title']?.toString() ?? '';
                  final artist = item['artist']?.toString() ?? 'Device Audio';
                  final album = item['album']?.toString() ?? 'Device Storage';
                  final duration = (item['duration'] as num?)?.toInt() ?? 0;

                  added.add(
                    Song(
                      id: 'offline_$path',
                      title: title.isNotEmpty ? title : 'Audio Track',
                      artist: (artist.isNotEmpty && artist != '<unknown>') ? artist : 'Device Audio',
                      album: (album.isNotEmpty && album != '<unknown>') ? album : 'Device Storage',
                      duration: duration,
                      artwork: '',
                      streamUrl: path,
                    ),
                  );
                  newlyFound++;
                }
              }
            }
          }
        } catch (_) {}
      }

      // 2. Off-main-thread supplemental background scan of user music directories
      // Executed inside a dedicated background Isolate (zero UI thread freezing)
      try {
        final backgroundPaths = await compute(
          _scanMusicDirectoriesInBackground,
          currentPaths.toList(),
        );

        for (final path in backgroundPaths) {
          if (!currentPaths.contains(path)) {
            currentPaths.add(path);
            final file = File(path);
            added.add(_fileToSong(file));
            newlyFound++;
          }
        }
      } catch (_) {}

      if (added.isNotEmpty && mounted) {
        setState(() {
          _offlineSongs.addAll(added);
        });
        await _saveOfflineSongs();
      }
    } catch (_) {} finally {
      if (mounted) {
        setState(() => _isScanningOffline = false);
        if (showFeedback) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                newlyFound > 0
                    ? 'Found $newlyFound new device audio ${newlyFound == 1 ? 'track' : 'tracks'}.'
                    : (_offlineSongs.isEmpty
                        ? 'No audio files found. Try using "Import Files".'
                        : 'Device scan complete. ${_offlineSongs.length} total tracks available.'),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _importOfflineSongs() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.audio,
      );
      if (files.isEmpty) return;

      int addedCount = 0;
      final currentPaths = _offlineSongs.map((s) => s.streamUrl).whereType<String>().toSet();
      final added = <Song>[];

      for (final file in files) {
        final path = file.path;
        if (path != null && path.isNotEmpty) {
          final lower = path.toLowerCase();
          if (lower.contains('whatsapp') ||
              lower.contains('com.whatsapp') ||
              lower.endsWith('.opus')) {
            continue;
          }
          if (!currentPaths.contains(path)) {
            final f = File(path);
            if (f.existsSync()) {
              currentPaths.add(path);
              added.add(_fileToSong(f));
              addedCount++;
            }
          }
        }
      }

      if (!mounted) return;

      if (added.isNotEmpty) {
        setState(() {
          _offlineSongs.addAll(added);
        });
        await _saveOfflineSongs();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Imported $addedCount audio ${addedCount == 1 ? 'track' : 'tracks'} to Offline Songs.'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selected audio tracks are already in Offline Songs or excluded.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import audio: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _removeOfflineSong(Song song) {
    setState(() {
      _offlineSongs.removeWhere(
          (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == song.streamUrl));
      _removeFromQueue(song);
    });
    _saveOfflineSongs();
  }

  Future<void> _showStoragePermissionDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _sheetBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        actionsOverflowButtonSpacing: 8,
        title: Row(
          children: [
            const Icon(PhosphorIconsRegular.shieldCheck, color: Color(0xff3B82F6), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Storage Permission Required',
                style: GoogleFonts.manrope(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  color: _textColor,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Android requires "All files access" to delete or rename audio files directly on your device storage. Tap "Open Settings" and toggle "Allow access to manage all files" for Sonix.',
          style: TextStyle(fontSize: 13.5, color: _textColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: _subtextColor, fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (Platform.isAndroid) {
                const channel = MethodChannel('com.example.song_player_mobile/offline_audio');
                await channel.invokeMethod('requestAllFilesAccess');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xff3B82F6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Open Settings', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteOfflineSongFromStorage(Song song) async {
    final path = song.streamUrl;
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot locate song file on storage.')),
        );
      }
      return;
    }

    bool fileDeleted = false;

    // 1. Try Android native platform channel if on Android
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.example.song_player_mobile/offline_audio');
        final res = await channel.invokeMethod<bool>('deleteAudioFile', {'path': path});
        fileDeleted = res ?? false;
      } on PlatformException catch (e) {
        if (e.code == 'ALL_FILES_ACCESS_REQUIRED') {
          if (mounted) {
            await _showStoragePermissionDialog();
          }
          return;
        }
      } catch (_) {}
    }

    // 2. Direct Dart File.delete fallback
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        fileDeleted = true;
      }
    } catch (_) {}

    // Verify if file is gone
    try {
      final f = File(path);
      if (!await f.exists()) {
        fileDeleted = true;
      }
    } catch (_) {}

    if (!fileDeleted) {
      if (mounted) {
        if (Platform.isAndroid) {
          await _showStoragePermissionDialog();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not delete file from device storage. Please check storage permissions.'),
            ),
          );
        }
      }
      return;
    }

    // If currently playing, skip to next song or stop
    if (_current != null && (_current!.id == song.id || _current!.streamUrl == path)) {
      if (_playlistQueue.length > 1) {
        _next();
      } else {
        await _audio.stop();
        if (mounted) setState(() => _current = null);
      }
    }

    // Remove from in-memory offline songs and queue
    _removeOfflineSong(song);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted "${song.title}" from device storage.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _renameOfflineSongOnStorage(Song song, String newTitle) async {
    final cleanTitle = newTitle.trim();
    if (cleanTitle.isEmpty) return;

    final oldPath = song.streamUrl;
    if (oldPath == null || oldPath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot locate song file on storage.')),
        );
      }
      return;
    }

    final oldFile = File(oldPath);
    if (!await oldFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Original song file not found on storage.')),
        );
      }
      return;
    }

    String? newPath;

    // 1. Try Android native platform channel
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.example.song_player_mobile/offline_audio');
        newPath = await channel.invokeMethod<String>('renameAudioFile', {
          'path': oldPath,
          'newName': cleanTitle,
        });
      } on PlatformException catch (e) {
        if (e.code == 'ALL_FILES_ACCESS_REQUIRED') {
          if (mounted) {
            await _showStoragePermissionDialog();
          }
          return;
        }
      } catch (_) {}
    }

    // 2. Direct Dart File rename fallback
    if (newPath == null || newPath.isEmpty) {
      try {
        final parentDir = oldFile.parent.path;
        final oldFileName = oldFile.uri.pathSegments.last;
        final dotIdx = oldFileName.lastIndexOf('.');
        final ext = dotIdx != -1 ? oldFileName.substring(dotIdx) : '';
        final candidatePath = '$parentDir/$cleanTitle$ext';

        if (candidatePath != oldPath) {
          final candidateFile = File(candidatePath);
          if (await candidateFile.exists()) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('A file with that name already exists in this folder.')),
              );
            }
            return;
          }
          final renamed = await oldFile.rename(candidatePath);
          newPath = renamed.path;
        } else {
          newPath = oldPath;
        }
      } catch (e) {
        if (mounted) {
          if (Platform.isAndroid) {
            await _showStoragePermissionDialog();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to rename file: $e')),
            );
          }
        }
        return;
      }
    }

    if (newPath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to rename file on storage.')),
        );
      }
      return;
    }

    final updatedSong = Song(
      id: 'offline_$newPath',
      title: cleanTitle,
      artist: song.artist,
      album: song.album,
      artwork: song.artwork,
      duration: song.duration,
      streamUrl: newPath,
      downloadUrls: song.downloadUrls,
    );

    setState(() {
      final offIdx = _offlineSongs.indexWhere(
        (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == oldPath),
      );
      if (offIdx != -1) {
        _offlineSongs[offIdx] = updatedSong;
      }

      final qIdx = _playlistQueue.indexWhere(
        (s) => s.id == song.id || (s.streamUrl != null && s.streamUrl == oldPath),
      );
      if (qIdx != -1) {
        _playlistQueue[qIdx] = updatedSong;
      }

      if (_current != null && (_current!.id == song.id || _current!.streamUrl == oldPath)) {
        _current = updatedSong;
      }
    });

    await _saveOfflineSongs();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Renamed file to "$cleanTitle"'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showRenameSongDialog(Song song) {
    final textCtrl = TextEditingController(text: song.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _sheetBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        actionsOverflowButtonSpacing: 8,
        title: Text(
          'Rename Audio File',
          style: GoogleFonts.manrope(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: _textColor,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Changes the file name directly on your device storage:',
              style: TextStyle(fontSize: 12, color: _subtextColor),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textCtrl,
              autofocus: true,
              style: TextStyle(color: _textColor),
              decoration: InputDecoration(
                hintText: 'Enter new song title',
                hintStyle: TextStyle(color: _subtextColor),
                filled: true,
                fillColor: _isLight
                    ? const Color(0xfff1f5f9)
                    : Colors.white.withValues(alpha: .06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xff3B82F6), width: 1.5),
                ),
                suffixText: song.streamUrl != null && song.streamUrl!.contains('.')
                    ? '.${song.streamUrl!.split('.').last}'
                    : null,
                suffixStyle: TextStyle(
                  color: _subtextColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: _subtextColor, fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = textCtrl.text.trim();
              if (newName.isNotEmpty) {
                Navigator.pop(ctx);
                _renameOfflineSongOnStorage(song, newName);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xff3B82F6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Rename', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showDeleteFromStorageDialog(Song song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _sheetBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        actionsOverflowButtonSpacing: 8,
        title: Row(
          children: [
            const Icon(PhosphorIconsRegular.warning, color: Colors.redAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete from Storage',
                style: GoogleFonts.manrope(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: _textColor,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to permanently delete "${song.title}" from your device storage?',
              style: TextStyle(fontSize: 13.5, color: _textColor),
            ),
            const SizedBox(height: 8),
            const Text(
              'This will erase the audio file from your device and cannot be undone.',
              style: TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: _subtextColor, fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteOfflineSongFromStorage(song);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete Permanently', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _offlineSongsHeader() => Container(
    padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
    decoration: BoxDecoration(
      color: _headerBg,
      border: Border(bottom: BorderSide(color: _borderColor)),
    ),
    child: Row(
      children: [
        IconButton(
          icon: Icon(PhosphorIconsRegular.arrowLeft, size: 22, color: _textColor),
          onPressed: () => setState(() => _viewingOfflineSongs = false),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            'Offline Songs',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.manrope(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _textColor,
            ),
          ),
        ),
        IconButton(
          onPressed: _isScanningOffline ? null : () => _scanDeviceForAudio(showFeedback: true),
          icon: _isScanningOffline
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _textColor,
                  ),
                )
              : Icon(
                  PhosphorIconsRegular.arrowsClockwise,
                  size: 20,
                  color: _textColor,
                ),
          tooltip: 'Scan Device',
        ),
        IconButton(
          onPressed: _importOfflineSongs,
          icon: Icon(
            PhosphorIconsRegular.folderPlus,
            size: 20,
            color: _textColor,
          ),
          tooltip: 'Import Audio Files',
        ),
      ],
    ),
  );

  Widget _offlineSongsView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  colors: [Color(0xff2563eb), Color(0xff1d4ed8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xff2563eb).withValues(alpha: .35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  PhosphorIconsFill.musicNotes,
                  color: Colors.white,
                  size: 60,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Offline Songs',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Device audio playlist',
                    style: TextStyle(color: _subtextColor, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_offlineSongs.length} ${_offlineSongs.length == 1 ? 'song' : 'songs'}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _subtextColor,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_offlineSongs.isNotEmpty)
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            _playPlaylistSong(_offlineSongs, 0);
                          },
                          icon: Icon(
                            PhosphorIconsBold.play,
                            size: 16,
                            color: _isLight ? Colors.white : Colors.black,
                          ),
                          label: Text(
                            'Play All',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _isLight ? Colors.white : Colors.black,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isLight ? const Color(0xff0f172a) : Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () {
                            final shuffled = [..._offlineSongs]..shuffle();
                            _playPlaylist(shuffled);
                          },
                          icon: Icon(
                            PhosphorIconsRegular.shuffle,
                            size: 20,
                            color: _textColor,
                          ),
                          tooltip: 'Shuffle',
                          style: IconButton.styleFrom(
                            backgroundColor: _isLight
                                ? const Color(0xff0f172a).withValues(alpha: .07)
                                : Colors.white.withValues(alpha: .1),
                            shape: const CircleBorder(),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Action buttons row (Import & Scan)
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _importOfflineSongs,
                icon: Icon(PhosphorIconsRegular.folderPlus, size: 16, color: _textColor),
                label: Text(
                  'Import Files',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _textColor,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isScanningOffline ? null : () => _scanDeviceForAudio(showFeedback: true),
                icon: _isScanningOffline
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _textColor),
                      )
                    : Icon(PhosphorIconsRegular.arrowsClockwise, size: 16, color: _textColor),
                label: Text(
                  _isScanningOffline ? 'Scanning...' : 'Scan Storage',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _textColor,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_offlineSongs.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Column(
              children: [
                Icon(
                  PhosphorIconsRegular.musicNotes,
                  size: 56,
                  color: _isLight
                      ? const Color(0x30000000)
                      : Colors.white.withValues(alpha: .2),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Offline Songs Found',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Import audio files from your device to listen offline without internet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _subtextColor, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _importOfflineSongs,
                  icon: const Icon(PhosphorIconsRegular.folderPlus, size: 18),
                  label: const Text('Import Audio Files'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isLight ? const Color(0xff0f172a) : Colors.white,
                    foregroundColor: _isLight ? Colors.white : Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Tracks (${_offlineSongs.length})',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _textColor,
                ),
              ),
              Text(
                'Looping Playlist',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xff3b82f6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._offlineSongs.asMap().entries.map(
            (entry) => _offlineSongRow(entry.key, entry.value, _offlineSongs),
          ),
        ],
      ],
    );
  }

  Widget _offlineSongRow(int index, Song song, List<Song> offlineList) {
    final isCurrent = _current?.id == song.id;
    final extension = song.streamUrl != null && song.streamUrl!.contains('.')
        ? song.streamUrl!.split('.').last.toUpperCase()
        : 'AUDIO';
    return InkWell(
      onTap: () => _playPlaylistSong(offlineList, index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 28,
              alignment: Alignment.centerLeft,
              child: isCurrent && _audio.playing
                  ? Icon(
                      PhosphorIconsFill.play,
                      size: 14,
                      color: _isLight
                          ? const Color(0xff0f172a)
                          : Colors.white,
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isCurrent ? _textColor : _subtextColor,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppConstants.songRowThumbnailRadius,
              ),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _isLight
                      ? const Color(0xfff1f5f9)
                      : Colors.white.withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(
                    AppConstants.songRowThumbnailRadius,
                  ),
                  border: Border.all(color: _borderColor),
                ),
                child: Icon(
                  PhosphorIconsRegular.musicNote,
                  color: isCurrent
                      ? const Color(0xff3B82F6)
                      : _textColor.withValues(alpha: .7),
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: isCurrent
                          ? (_isLight ? const Color(0xff2563eb) : const Color(0xff60a5fa))
                          : _textColor.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: _isLight
                              ? const Color(0xffe2e8f0)
                              : Colors.white.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          extension,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .5,
                            color: _subtextColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _subtextColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: _sheetBg,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (ctx) => SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _isLight
                                    ? const Color(0xfff1f5f9)
                                    : Colors.white.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                PhosphorIconsRegular.play,
                                color: _textColor,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              'Play Now',
                              style: TextStyle(
                                color: _textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _playPlaylistSong(offlineList, index);
                            },
                          ),
                          ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _isLight
                                    ? const Color(0xfff1f5f9)
                                    : Colors.white.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                PhosphorIconsRegular.pencilSimple,
                                color: const Color(0xff3B82F6),
                                size: 20,
                              ),
                            ),
                            title: Text(
                              'Rename File',
                              style: TextStyle(
                                color: _textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'Rename this audio file on device storage',
                              style: TextStyle(
                                color: _subtextColor,
                                fontSize: 11,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _showRenameSongDialog(song);
                            },
                          ),
                          ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _isLight
                                    ? const Color(0xfff1f5f9)
                                    : Colors.white.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                PhosphorIconsRegular.minusCircle,
                                color: _textColor,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              'Remove from Offline Playlist',
                              style: TextStyle(
                                color: _textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'Keep file on storage, remove from app playlist',
                              style: TextStyle(
                                color: _subtextColor,
                                fontSize: 11,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _removeOfflineSong(song);
                            },
                          ),
                          ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                PhosphorIconsRegular.trash,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                            ),
                            title: const Text(
                              'Delete from Device Storage',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'Permanently erase file from user device storage',
                              style: TextStyle(
                                color: Colors.redAccent.withValues(alpha: .75),
                                fontSize: 11,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _showDeleteFromStorageDialog(song);
                            },
                          ),
                          if (song.streamUrl != null)
                            ListTile(
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: _isLight
                                      ? const Color(0xfff1f5f9)
                                      : Colors.white.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                PhosphorIconsRegular.info,
                                color: _textColor,
                                size: 20,
                              ),
                            ),
                              title: Text(
                                'File Location',
                                style: TextStyle(
                                  color: _textColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                song.streamUrl!,
                                style: TextStyle(
                                  color: _subtextColor,
                                  fontSize: 11,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              icon: Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
                color: _subtextColor,
              ),
              tooltip: 'More options',
            ),
          ],
        ),
      ),
    );
  }
}

/* --------------------------- AUTO-SCROLL LYRICS -------------------------- */

class _LyricsAutoScrollView extends StatefulWidget {
  const _LyricsAutoScrollView({
    required this.lyrics,
    required this.parsedLyrics,
    this.isLoading = false,
    required this.positionStream,
    this.initialPosition,
    required this.onSeek,
    this.controller,
  });

  final Map<String, dynamic>? lyrics;
  final List<LyricLine> parsedLyrics;
  final bool isLoading;
  final Stream<Duration> positionStream;
  final Duration? initialPosition;
  final ValueChanged<double> onSeek;
  final ScrollController? controller;

  @override
  State<_LyricsAutoScrollView> createState() => _LyricsAutoScrollViewState();
}

class _LyricsAutoScrollViewState extends State<_LyricsAutoScrollView> {
  late final ScrollController _internalController;
  final Map<int, GlobalKey> _itemKeys = {};
  int _lastActiveIndex = -1;
  bool _userInteracting = false;
  bool _hasInitialScrolled = false;
  Timer? _userResumeTimer;

  ScrollController get _effectiveController =>
      widget.controller ?? _internalController;

  GlobalKey _getKey(int index) =>
      _itemKeys.putIfAbsent(index, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _internalController = ScrollController();
    _computeInitialActiveIndex();
  }

  void _computeInitialActiveIndex() {
    final pos = widget.initialPosition;
    if (pos == null || widget.parsedLyrics.isEmpty) return;
    final time = pos.inMilliseconds;
    var active = -1;
    for (var i = 0; i < widget.parsedLyrics.length; i++) {
      if (time >= widget.parsedLyrics[i].time * 1000) {
        active = i;
      }
    }
    if (active >= 0) {
      _lastActiveIndex = active;
    }
  }

  @override
  void didUpdateWidget(covariant _LyricsAutoScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.parsedLyrics != oldWidget.parsedLyrics ||
        (oldWidget.isLoading && !widget.isLoading)) {
      _lastActiveIndex = -1;
      _userInteracting = false;
      _hasInitialScrolled = false;
      _userResumeTimer?.cancel();
      _itemKeys.clear();
      _computeInitialActiveIndex();
    }
  }

  @override
  void dispose() {
    _userResumeTimer?.cancel();
    _internalController.dispose();
    super.dispose();
  }

  void _scrollToIndex(
    int index, {
    Duration duration = const Duration(milliseconds: 350),
    Curve curve = Curves.easeOutCubic,
  }) {
    if (index < 0 || index >= widget.parsedLyrics.length) return;
    if (!mounted || !_effectiveController.hasClients) return;

    final key = _getKey(index);
    final itemContext = key.currentContext;

    if (itemContext != null && itemContext.mounted) {
      Scrollable.ensureVisible(
        itemContext,
        alignment: 0.5,
        duration: duration,
        curve: curve,
      );
    } else {
      // If layout has not finished yet, retry on next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _effectiveController.hasClients) {
          final retryContext = _getKey(index).currentContext;
          if (retryContext != null && retryContext.mounted) {
            Scrollable.ensureVisible(
              retryContext,
              alignment: 0.5,
              duration: duration,
              curve: curve,
            );
          }
        }
      });
    }
  }

  void _triggerInitialScroll(int active) {
    if (_hasInitialScrolled) return;
    _hasInitialScrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_userInteracting) {
        final targetIndex = active >= 0 ? active : _lastActiveIndex;
        if (targetIndex >= 0) {
          _scrollToIndex(
            targetIndex,
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  Widget _buildLyricItem(int i, bool isCurrent, bool isLight) {
    return InkWell(
      key: _getKey(i),
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        widget.onSeek(widget.parsedLyrics[i].time);
        _userResumeTimer?.cancel();
        setState(() => _userInteracting = false);
        _scrollToIndex(
          i,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 10,
          horizontal: 8,
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          style: TextStyle(
            fontSize: AppConstants.lyricsFontSize,
            fontWeight: AppConstants.lyricsFontWeight,
            color: isCurrent
                ? (isLight
                    ? const Color(0xff0f172a)
                    : Colors.white)
                : (isLight
                    ? const Color(0x660f172a)
                    : const Color(0x66ffffff)),
            height: AppConstants.lyricsLineHeight,
          ),
          child: Text(widget.parsedLyrics[i].text),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    if (widget.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: isLight ? const Color(0xff0f172a) : Colors.white,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading lyrics...',
              style: TextStyle(
                fontSize: 14,
                color: isLight ? const Color(0xff64748b) : _muted,
              ),
            ),
          ],
        ),
      );
    }

    final plain = widget.lyrics?['plainLyrics'] as String?;
    final hasPlain = plain != null && plain.trim().isNotEmpty;

    if (widget.parsedLyrics.isEmpty) {
      if (hasPlain) {
        return SingleChildScrollView(
          controller: _effectiveController,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Text(
            plain.trim(),
            style: TextStyle(
              fontSize: AppConstants.plainLyricsFontSize,
              fontWeight: AppConstants.plainLyricsFontWeight,
              height: 1.7,
              color: isLight ? const Color(0xff334155) : const Color(0xddffffff),
            ),
          ),
        );
      }

      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: isLight
                      ? Colors.black.withValues(alpha: 0.05)
                      : Colors.white.withValues(alpha: 0.07),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  PhosphorIconsRegular.textAa,
                  size: 28,
                  color: isLight ? const Color(0xff64748b) : _muted,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No lyrics found for this track',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isLight ? const Color(0xff1e293b) : Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Lyrics are not available for this song.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: isLight ? const Color(0xff64748b) : _muted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return StreamBuilder<Duration>(
      stream: widget.positionStream,
      initialData: widget.initialPosition,
      builder: (context, snapshot) {
        final time =
            (snapshot.data ?? widget.initialPosition)?.inMilliseconds ?? 0;
        var active = -1;
        for (var i = 0; i < widget.parsedLyrics.length; i++) {
          if (time >= widget.parsedLyrics[i].time * 1000) {
            active = i;
          }
        }

        if (active != _lastActiveIndex) {
          _lastActiveIndex = active;
          if (!_userInteracting && active >= 0 && _hasInitialScrolled) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollToIndex(active);
            });
          }
        }

        if (!_hasInitialScrolled && active >= 0) {
          _triggerInitialScroll(active);
        }

        return Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final halfViewport = constraints.maxHeight.isFinite
                    ? constraints.maxHeight / 2
                    : 300.0;
                final verticalPadding = math.max(0.0, halfViewport - 35.0);

                return NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (notification.direction != ScrollDirection.idle) {
                      _userResumeTimer?.cancel();
                      if (!_userInteracting) {
                        setState(() => _userInteracting = true);
                      }
                    } else {
                      _userResumeTimer?.cancel();
                      _userResumeTimer = Timer(
                        const Duration(milliseconds: 6000),
                        () {
                          if (mounted && _userInteracting) {
                            setState(() => _userInteracting = false);
                            if (_lastActiveIndex >= 0) {
                              _scrollToIndex(_lastActiveIndex);
                            }
                          }
                        },
                      );
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _effectiveController,
                    padding: EdgeInsets.fromLTRB(
                      22,
                      verticalPadding,
                      22,
                      verticalPadding + 40,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < widget.parsedLyrics.length; i++)
                          _buildLyricItem(i, i == active, isLight),
                      ],
                    ),
                  ),
                );
              },
            ),
            // Floating "Sync lyrics" pill when user scrolled away
            if (_userInteracting && active >= 0)
              Positioned(
                bottom:
                    24.0 + math.max(MediaQuery.paddingOf(context).bottom, 14.0),
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        _userResumeTimer?.cancel();
                        setState(() => _userInteracting = false);
                        _scrollToIndex(
                          active,
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isLight
                              ? Colors.white
                              : const Color(0xff222228),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isLight
                                ? const Color(0x28000000)
                                : Colors.white24,
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isLight
                                  ? Colors.black.withValues(alpha: .15)
                                  : Colors.black54,
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              PhosphorIconsBold.arrowsClockwise,
                              size: 16,
                              color: isLight
                                  ? const Color(0xff0f172a)
                                  : Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Sync lyrics',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isLight
                                    ? const Color(0xff0f172a)
                                    : Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GradientCircleBorderPainter extends CustomPainter {
  final Gradient gradient;
  final double strokeWidth;

  const _GradientCircleBorderPainter({
    required this.gradient,
    this.strokeWidth = 1.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _GradientCircleBorderPainter oldDelegate) =>
      oldDelegate.gradient != gradient || oldDelegate.strokeWidth != strokeWidth;
}

/* -------------------------------------------------------------------------- */
/*                           SETTINGS BOTTOM SHEET                            */
/* -------------------------------------------------------------------------- */

class _SettingsBottomSheet extends StatefulWidget {
  final UserProfile? userProfile;
  final String currentQuality;
  final String currentTheme;
  final String currentLanguage;
  final DateTime? sleepTimerEndTime;
  final Duration? Function() getSleepTimerRemaining;
  final Future<void> Function(String name, int age) onSaveProfile;
  final void Function(Duration duration) onSetSleepTimer;
  final VoidCallback onCancelSleepTimer;
  final Future<void> Function(String theme) onThemeChanged;
  final Future<void> Function(String quality) onQualityChanged;
  final Future<void> Function(String language) onLanguageChanged;

  const _SettingsBottomSheet({
    required this.userProfile,
    required this.currentQuality,
    required this.currentTheme,
    required this.currentLanguage,
    required this.sleepTimerEndTime,
    required this.getSleepTimerRemaining,
    required this.onSaveProfile,
    required this.onSetSleepTimer,
    required this.onCancelSleepTimer,
    required this.onThemeChanged,
    required this.onQualityChanged,
    required this.onLanguageChanged,
  });

  @override
  State<_SettingsBottomSheet> createState() => _SettingsBottomSheetState();
}

class _SettingsBottomSheetState extends State<_SettingsBottomSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ageCtrl;
  late final TextEditingController _hoursCtrl;
  late final TextEditingController _minutesCtrl;
  late String _selectedQuality;
  late String _selectedTheme;
  late String _selectedLanguage;
  bool _showCustomTimer = false;
  Timer? _liveTicker;
  DateTime? _sleepTimerEndTime;
  bool _isDisposing = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.userProfile?.name ?? '');
    _ageCtrl = TextEditingController(
      text: widget.userProfile?.age != null ? '${widget.userProfile!.age}' : '',
    );
    _hoursCtrl = TextEditingController(text: '0');
    _minutesCtrl = TextEditingController(text: '30');
    _selectedQuality = widget.currentQuality;
    _selectedTheme = widget.currentTheme;
    _selectedLanguage = widget.currentLanguage;
    _sleepTimerEndTime = widget.sleepTimerEndTime;

    _startLiveTicker();
  }

  void _startLiveTicker() {
    _liveTicker?.cancel();
    if (_sleepTimerEndTime != null) {
      _liveTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _isDisposing) {
          _liveTicker?.cancel();
          return;
        }
        if (_sleepTimerEndTime == null) {
          _liveTicker?.cancel();
          return;
        }
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _isDisposing = true;
    _liveTicker?.cancel();
    _liveTicker = null;
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _hoursCtrl.dispose();
    _minutesCtrl.dispose();
    super.dispose();
  }

  bool get _isLight => Theme.of(context).brightness == Brightness.light;
  Color get _sheetBg =>
      _isLight ? AppConstants.colorLightSurface : const Color(0xff16161b);
  Color get _textColor => _isLight ? const Color(0xff0f172a) : Colors.white;
  Color get _subtextColor => _isLight ? const Color(0xff64748b) : _muted;
  Color get _borderColor =>
      _isLight ? const Color(0x18000000) : Colors.white12;
  Color get _cardBg =>
      _isLight ? const Color(0xfff1f5f9) : Colors.white.withValues(alpha: .06);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _isDisposing = true;
          _liveTicker?.cancel();
          _liveTicker = null;
        }
      },
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: _sheetBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: _borderColor)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _isLight ? const Color(0x20000000) : Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Title & Close
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: _textColor,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(
                          PhosphorIconsRegular.x,
                          size: 20,
                          color: _subtextColor,
                        ),
                        onPressed: () {
                          _isDisposing = true;
                          _liveTicker?.cancel();
                          _liveTicker = null;
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  ),
                const SizedBox(height: 16),

                /* ---------------------------------------------------- */
                /* 1. EDIT PROFILE SECTION                              */
                /* ---------------------------------------------------- */
                Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.userCircle,
                      size: 18,
                      color: _isLight ? const Color(0xff334155) : Colors.white70,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'PROFILE',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: _subtextColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 48,
                        child: TextField(
                          controller: _nameCtrl,
                          inputFormatters: const [
                            UserNameTextInputFormatter(),
                          ],
                          style: TextStyle(
                            color: _textColor,
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Your name',
                            hintStyle: TextStyle(
                              color: _subtextColor,
                              fontSize: 13,
                            ),
                            prefixIcon: Icon(
                              PhosphorIconsRegular.user,
                              size: 18,
                              color: _subtextColor,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            filled: true,
                            fillColor: _cardBg,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 1,
                      child: SizedBox(
                        height: 48,
                        child: TextField(
                          controller: _ageCtrl,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _textColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Age',
                            hintStyle: TextStyle(
                              color: _subtextColor,
                              fontSize: 13,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 14,
                            ),
                            filled: true,
                            fillColor: _cardBg,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 120,
                    height: 40,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final name = _nameCtrl.text.trim();
                        final age = int.tryParse(_ageCtrl.text.trim());
                        if (name.isEmpty) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text(
                                  'Please enter your name',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }
                        if (name.length < 2) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text(
                                  'Name must be at least 2 characters',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }
                        final firstName = name.split(RegExp(r'\s+')).first;
                        if (firstName.length >
                            AppConstants.maxFirstNameLength) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'First name cannot exceed ${AppConstants.maxFirstNameLength} characters',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }
                        if (name.length > AppConstants.maxFullNameLength) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Name cannot exceed ${AppConstants.maxFullNameLength} characters',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }
                        if (age == null || age < 5 || age > 120) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text(
                                  'Please enter a valid age between 5 and 120',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }

                        await widget.onSaveProfile(name, age);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text(
                                'Profile saved successfully',
                              ),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      icon: const Icon(
                        PhosphorIconsBold.check,
                        size: 15,
                      ),
                      label: const Text(
                        'Save',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _isLight ? const Color(0xff0f172a) : Colors.white,
                        foregroundColor:
                            _isLight ? Colors.white : Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),

                /* ---------------------------------------------------- */
                /* 2. SLEEP TIMER SECTION (15m, 30m, 1h Presets)        */
                /* ---------------------------------------------------- */
                const SizedBox(height: 18),
                Divider(color: _borderColor, height: 1),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.moonStars,
                          size: 18,
                          color: _isLight ? const Color(0xff334155) : Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'SLEEP TIMER',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: _subtextColor,
                          ),
                        ),
                      ],
                    ),
                    if (_sleepTimerEndTime != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.indigoAccent.withValues(
                            alpha: .2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.indigoAccent.withValues(
                              alpha: .4,
                            ),
                          ),
                        ),
                        child: Text(
                          () {
                            final rem = widget.getSleepTimerRemaining() ??
                                Duration.zero;
                            final h = rem.inHours;
                            final m = rem.inMinutes % 60;
                            final s = rem.inSeconds % 60;
                            if (h > 0) return '${h}h ${m}m ${s}s left';
                            return '${m}m ${s}s left';
                          }(),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.indigoAccent,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_sleepTimerEndTime != null)
                  Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _cardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _borderColor),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          PhosphorIconsRegular.clockCountdown,
                          size: 18,
                          color: Colors.indigoAccent,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Timer running',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _textColor,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            widget.onCancelSleepTimer();
                            _liveTicker?.cancel();
                            _liveTicker = null;
                            setState(() => _sleepTimerEndTime = null);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text(
                                  'Sleep timer turned off',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(
                                alpha: .15,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.redAccent.withValues(
                                  alpha: .4,
                                ),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  PhosphorIconsRegular.xCircle,
                                  size: 14,
                                  color: Colors.redAccent,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Cancel',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      for (final p in [
                        {'label': '15m', 'sec': 15 * 60},
                        {'label': '30m', 'sec': 30 * 60},
                        {'label': '1h', 'sec': 60 * 60},
                      ])
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              final dur = Duration(seconds: p['sec'] as int);
                              widget.onSetSleepTimer(dur);
                              setState(() {
                                _sleepTimerEndTime = DateTime.now().add(dur);
                              });
                              _startLiveTicker();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Sleep timer set for ${p['label']}',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      10,
                                    ),
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            child: Container(
                              height: 44,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _cardBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _borderColor),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                p['label'] as String,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _textColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                      GestureDetector(
                        onTap: () {
                          setState(
                            () => _showCustomTimer = !_showCustomTimer,
                          );
                        },
                        child: Container(
                          height: 44,
                          margin: const EdgeInsets.only(left: 3),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                          ),
                          decoration: BoxDecoration(
                            color: _showCustomTimer
                                ? (_isLight
                                    ? const Color(0xffe2e8f0)
                                    : Colors.white.withValues(alpha: .18))
                                : _cardBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _showCustomTimer
                                  ? (_isLight
                                      ? const Color(0xff94a3b8)
                                      : Colors.white54)
                                  : _borderColor,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            PhosphorIconsRegular.sliders,
                            size: 18,
                            color: _isLight
                                ? const Color(0xff334155)
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_showCustomTimer) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: TextField(
                              controller: _hoursCtrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _textColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Hours',
                                hintStyle: TextStyle(
                                  color: _subtextColor,
                                  fontSize: 12,
                                ),
                                suffixText: 'h',
                                suffixStyle: TextStyle(
                                  color: _subtextColor,
                                  fontSize: 12,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                                filled: true,
                                fillColor: _cardBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: TextField(
                              controller: _minutesCtrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _textColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Mins',
                                hintStyle: TextStyle(
                                  color: _subtextColor,
                                  fontSize: 12,
                                ),
                                suffixText: 'm',
                                suffixStyle: TextStyle(
                                  color: _subtextColor,
                                  fontSize: 12,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                                filled: true,
                                fillColor: _cardBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            final h = int.tryParse(_hoursCtrl.text.trim()) ?? 0;
                            final m = int.tryParse(_minutesCtrl.text.trim()) ?? 0;
                            final total = (h * 3600) + (m * 60);
                            if (total > 0) {
                              final dur = Duration(seconds: total);
                              widget.onSetSleepTimer(dur);
                              setState(() {
                                _sleepTimerEndTime = DateTime.now().add(dur);
                                _showCustomTimer = false;
                              });
                              _startLiveTicker();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Sleep timer set for ${h > 0 ? '$h hr ' : ''}$m min',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      10,
                                    ),
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            decoration: BoxDecoration(
                              color: _isLight
                                  ? const Color(0xff0f172a)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Set',
                              style: TextStyle(
                                color: _isLight ? Colors.white : Colors.black,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],

                /* ---------------------------------------------------- */
                /* 3. MUSIC LANGUAGE PREFERENCE (English / Hindi)       */
                /* ---------------------------------------------------- */
                const SizedBox(height: 18),
                Divider(color: _borderColor, height: 1),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.translate,
                          size: 18,
                          color: _isLight ? const Color(0xff334155) : Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'MUSIC LANGUAGE',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: _subtextColor,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _selectedLanguage,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _isLight ? const Color(0xff334155) : Colors.white70,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final lang in ['English', 'Hindi'])
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            setState(() => _selectedLanguage = lang);
                            await widget.onLanguageChanged(lang);
                          },
                          child: Container(
                            height: 46,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: _selectedLanguage.toLowerCase() ==
                                      lang.toLowerCase()
                                  ? (_isLight
                                      ? const Color(0xff0f172a)
                                      : Colors.white)
                                  : _cardBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedLanguage.toLowerCase() ==
                                        lang.toLowerCase()
                                    ? (_isLight
                                        ? const Color(0xff0f172a)
                                        : Colors.white)
                                    : _borderColor,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  PhosphorIconsRegular.translate,
                                  size: 16,
                                  color: _selectedLanguage.toLowerCase() ==
                                          lang.toLowerCase()
                                      ? (_isLight
                                          ? Colors.white
                                          : Colors.black)
                                      : _subtextColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  lang,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _selectedLanguage.toLowerCase() ==
                                            lang.toLowerCase()
                                        ? (_isLight
                                            ? Colors.white
                                            : Colors.black)
                                        : _textColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                /* ---------------------------------------------------- */
                /* 4. THEME SECTION (System, Dark, Light 3-way Switch)  */
                /* ---------------------------------------------------- */
                const SizedBox(height: 18),
                Divider(color: _borderColor, height: 1),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.paintBrushBroad,
                      size: 18,
                      color: _isLight ? const Color(0xff334155) : Colors.white70,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'THEME',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: _subtextColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  height: 44,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _borderColor),
                  ),
                  child: Row(
                    children: [
                      for (final opt in [
                        {
                          'val': 'system',
                          'label': 'System',
                          'icon': PhosphorIconsRegular.deviceMobile,
                          'iconFill': PhosphorIconsFill.deviceMobile,
                        },
                        {
                          'val': 'dark',
                          'label': 'Dark',
                          'icon': PhosphorIconsRegular.moon,
                          'iconFill': PhosphorIconsFill.moon,
                        },
                        {
                          'val': 'light',
                          'label': 'Light',
                          'icon': PhosphorIconsRegular.sun,
                          'iconFill': PhosphorIconsFill.sun,
                        },
                      ])
                        Expanded(
                          child: GestureDetector(
                            onTap: () async {
                              final mode = opt['val'] as String;
                              setState(() => _selectedTheme = mode);
                              await widget.onThemeChanged(mode);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              decoration: BoxDecoration(
                                color: _selectedTheme == opt['val']
                                    ? (_isLight
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: .18))
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: _selectedTheme == opt['val'] && _isLight
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: .06),
                                          blurRadius: 4,
                                          offset: const Offset(0, 1),
                                        ),
                                      ]
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _selectedTheme == opt['val']
                                        ? (opt['iconFill'] as IconData)
                                        : (opt['icon'] as IconData),
                                    size: 16,
                                    color: _selectedTheme == opt['val']
                                        ? (_isLight
                                            ? const Color(0xff0f172a)
                                            : Colors.white)
                                        : _subtextColor,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    opt['label'] as String,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: _selectedTheme == opt['val']
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: _selectedTheme == opt['val']
                                          ? (_isLight
                                              ? const Color(0xff0f172a)
                                              : Colors.white)
                                          : _subtextColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                /* ---------------------------------------------------- */
                /* 5. AUDIO QUALITY SECTION                             */
                /* ---------------------------------------------------- */
                const SizedBox(height: 18),
                Divider(color: _borderColor, height: 1),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.waveform,
                          size: 18,
                          color: _isLight ? const Color(0xff334155) : Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'AUDIO QUALITY',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: _subtextColor,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _selectedQuality == '320kbps'
                          ? 'HD 320 kbps'
                          : _selectedQuality,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _isLight
                            ? const Color(0xff334155)
                            : Colors.white70,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final opt in [
                      {'val': '320kbps', 'label': '320k', 'sub': 'Best'},
                      {'val': '160kbps', 'label': '160k', 'sub': 'High'},
                      {'val': '96kbps', 'label': '96k', 'sub': 'Saver'},
                      {'val': '48kbps', 'label': '48k', 'sub': 'Low'},
                    ])
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            setState(() => _selectedQuality = opt['val']!);
                            await widget.onQualityChanged(opt['val']!);
                          },
                          child: Container(
                            height: 52,
                            margin: const EdgeInsets.symmetric(
                              horizontal: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _selectedQuality == opt['val']
                                  ? (_isLight
                                      ? const Color(0xff0f172a)
                                      : Colors.white)
                                  : _cardBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedQuality == opt['val']
                                    ? (_isLight
                                        ? const Color(0xff0f172a)
                                        : Colors.white)
                                    : _borderColor,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  opt['label']!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: _selectedQuality == opt['val']
                                        ? (_isLight
                                            ? Colors.white
                                            : Colors.black)
                                        : _textColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  opt['sub']!,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: _selectedQuality == opt['val']
                                        ? (_isLight
                                            ? Colors.white70
                                            : Colors.black87)
                                        : _subtextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                // Bottom spacing
                SizedBox(
                  height: math.max(
                        MediaQuery.paddingOf(context).bottom,
                        16.0,
                      ) +
                      8.0,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
}

/* -------------------------------------------------------------------------- */
/*                            EQUALIZER BOTTOM SHEET                          */
/* -------------------------------------------------------------------------- */

class _EqualizerBottomSheet extends StatefulWidget {
  final CrossfadePlayer audio;
  final bool initialEnabled;
  final String initialPreset;
  final List<double> initialBands;
  final double initialBassBoost;
  final void Function(
    bool enabled,
    String preset,
    List<double> bands,
    double bassBoost,
  ) onChanged;

  const _EqualizerBottomSheet({
    required this.audio,
    required this.initialEnabled,
    required this.initialPreset,
    required this.initialBands,
    required this.initialBassBoost,
    required this.onChanged,
  });

  @override
  State<_EqualizerBottomSheet> createState() => _EqualizerBottomSheetState();
}

class _EqualizerBottomSheetState extends State<_EqualizerBottomSheet> {
  // Theme-aware audio equalizer design tokens
  bool get _isLight => Theme.of(context).brightness == Brightness.light;

  Color get _sheetBg =>
      _isLight ? AppConstants.colorLightSurface : const Color(0xff121212);
  Color get _cardBg =>
      _isLight ? const Color(0xffF8FAFC) : const Color(0xff1A1A1A);
  Color get _elevatedBg =>
      _isLight ? const Color(0xffF1F5F9) : const Color(0xff222222);
  Color get _accent =>
      _isLight ? const Color(0xff0F172A) : const Color(0xffB0B0B0);
  Color get _accentSoft =>
      _isLight ? const Color(0xffF1F5F9) : const Color(0xff2E2E2E);
  Color get _textColor =>
      _isLight ? const Color(0xff0F172A) : const Color(0xffF2F2F2);
  Color get _secondaryText =>
      _isLight ? const Color(0xff64748B) : const Color(0xffA1A1A1);
  Color get _mutedText =>
      _isLight ? const Color(0xff94A3B8) : const Color(0xff6E6E6E);
  Color get _borderColor =>
      _isLight ? const Color(0xffE2E8F0) : const Color(0xff2A2A2A);
  Color get _sliderInactive =>
      _isLight ? const Color(0xffCBD5E1) : const Color(0xff3A3A3A);
  Color get _posEqColor =>
      _isLight ? const Color(0xff0F172A) : const Color(0xffD4D4D4);
  Color get _negEqColor =>
      _isLight ? const Color(0xff64748B) : const Color(0xff8A8A8A);
  static const _activeBlue = Color(0xff3B82F6);


  late bool _enabled;
  late String _preset;
  late List<double> _bands;
  late double _bassBoost;
  List<String> _frequencies = ['60Hz', '230Hz', '910Hz', '3.6kHz', '14kHz'];
  double _minDb = -10.0;
  double _maxDb = 10.0;

  static const Map<String, List<double>> _presets = {
    'Flat': [0.0, 0.0, 0.0, 0.0, 0.0],
    'Bass Boost': [6.0, 4.5, 1.0, 0.0, 0.0],
    'Rock': [4.5, 2.5, -1.0, 2.5, 4.0],
    'Pop': [-1.0, 1.5, 3.5, 2.0, -1.0],
    'Electronic': [5.0, 3.5, 0.0, 2.5, 4.0],
    'Hip Hop': [5.5, 3.0, 0.0, 1.5, 3.0],
    'Jazz': [3.0, 1.5, -1.5, 1.5, 3.0],
    'Classical': [4.0, 2.5, -2.0, 2.0, 3.5],
    'Vocal Boost': [-2.0, 0.0, 4.5, 3.5, 1.0],
    'Acoustic': [3.5, 2.0, 1.0, 2.5, 3.0],
    'Deep Bass': [7.0, 5.0, 1.5, -1.0, -2.0],
  };

  static const List<String> _presetNames = [
    'Flat',
    'Bass Boost',
    'Rock',
    'Pop',
    'Electronic',
    'Hip Hop',
    'Jazz',
    'Classical',
    'Vocal Boost',
    'Acoustic',
    'Deep Bass',
  ];

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialEnabled;
    _preset = widget.initialPreset;
    _bands = List<double>.from(widget.initialBands);
    while (_bands.length < 5) {
      _bands.add(0.0);
    }
    _bassBoost = widget.initialBassBoost;

    widget.audio.getEqualizerParameters().then((params) {
      if (mounted && params != null && params.bands.isNotEmpty) {
        setState(() {
          _minDb = params.minDecibels.clamp(-20.0, -6.0);
          _maxDb = params.maxDecibels.clamp(6.0, 20.0);
          _frequencies = params.bands.map((b) {
            final f = b.centerFrequency;
            if (f < 1000) return '${f.round()}Hz';
            if (f % 1000 == 0) return '${(f / 1000).round()}kHz';
            return '${(f / 1000).toStringAsFixed(1)}kHz';
          }).toList();
          while (_bands.length < params.bands.length) {
            _bands.add(0.0);
          }
        });
      }
    });
  }

  void _toggleEnabled(bool val) {
    setState(() => _enabled = val);
    widget.audio.setEqualizerEnabled(val);
    UserStorage.saveEqualizerEnabled(val);
    widget.onChanged(_enabled, _preset, _bands, _bassBoost);
  }

  void _selectPreset(String presetName) {
    final target = _presets[presetName];
    if (target != null) {
      setState(() {
        _preset = presetName;
        _bands = List<double>.from(target);
      });
      widget.audio.setAllEqualizerBands(_bands);
      UserStorage.saveEqualizerPreset(presetName);
      UserStorage.saveEqualizerBands(_bands);
      widget.onChanged(_enabled, _preset, _bands, _bassBoost);
    }
  }

  void _onBandChanged(int index, double gain) {
    setState(() {
      _bands[index] = gain;
      String matched = 'Custom';
      for (final entry in _presets.entries) {
        if (entry.value.length == _bands.length) {
          bool match = true;
          for (int i = 0; i < _bands.length; i++) {
            if ((_bands[i] - entry.value[i]).abs() > 0.1) {
              match = false;
              break;
            }
          }
          if (match) {
            matched = entry.key;
            break;
          }
        }
      }
      _preset = matched;
    });
    widget.audio.setEqualizerBandGain(index, gain);
    UserStorage.saveEqualizerPreset(_preset);
    UserStorage.saveEqualizerBands(_bands);
    widget.onChanged(_enabled, _preset, _bands, _bassBoost);
  }

  void _onBassBoostChanged(double val) {
    setState(() => _bassBoost = val);
    widget.audio.setBassBoost(val);
    UserStorage.saveEqualizerBassBoost(val);
    widget.onChanged(_enabled, _preset, _bands, _bassBoost);
  }

  void _reset() {
    setState(() {
      _preset = 'Flat';
      _bands = List.filled(_bands.length, 0.0);
      _bassBoost = 0.0;
    });
    widget.audio.setAllEqualizerBands(_bands);
    widget.audio.setBassBoost(0.0);
    UserStorage.saveEqualizerPreset('Flat');
    UserStorage.saveEqualizerBands(_bands);
    UserStorage.saveEqualizerBassBoost(0.0);
    widget.onChanged(_enabled, _preset, _bands, _bassBoost);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _sheetBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: _borderColor, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Drag handle
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _sliderInactive,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // 2. Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _accentSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _borderColor),
                      ),
                      child: Center(
                        child: Icon(
                          PhosphorIconsRegular.slidersHorizontal,
                          color: _accent,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Equalizer',
                            style: GoogleFonts.poppins(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: _textColor,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 140),
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: _enabled ? _activeBlue : _secondaryText,
                            ),
                            child: Text(
                              _enabled
                                  ? 'Active · $_preset'
                                  : 'Bypassed · $_preset',
                            ),
                          ),
                        ],
                      ),
                    ),
                    Transform.scale(
                      scale: 0.88,
                      child: Switch.adaptive(
                        value: _enabled,
                        activeTrackColor: _activeBlue,
                        activeThumbColor: Colors.white,
                        inactiveTrackColor: _borderColor,
                        inactiveThumbColor: _mutedText,
                        onChanged: _toggleEnabled,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 3. Preset Section Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'PRESETS',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                        color: _mutedText,
                      ),
                    ),
                    GestureDetector(
                      onTap: _reset,
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            PhosphorIconsRegular.arrowCounterClockwise,
                            size: 13,
                            color: _secondaryText,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Reset to Flat',
                            style: GoogleFonts.poppins(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: _secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 4. Horizontal Scrollable Presets (full bleed with 24px insets)
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: _presetNames.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final name = _presetNames[i];
                    final isSel = _preset == name;
                    return GestureDetector(
                      onTap: () => _selectPreset(name),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isSel ? _activeBlue : _elevatedBg,
                          borderRadius: BorderRadius.circular(20),
                          border: isSel
                              ? null
                              : Border.all(color: _borderColor, width: 1),
                        ),
                        child: Center(
                          child: Text(
                            name,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight:
                                  isSel ? FontWeight.w600 : FontWeight.w500,
                              color: isSel ? Colors.white : _secondaryText,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),

              // 5. Equalizer Graph (Card)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedOpacity(
                  opacity: _enabled ? 1.0 : 0.38,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                    decoration: BoxDecoration(
                      color: _cardBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _borderColor, width: 1),
                    ),
                    child: Column(
                      children: [
                        // dB range guideline text
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '+${_maxDb.round()} dB',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: _mutedText,
                              ),
                            ),
                            Text(
                              '0 dB',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: _mutedText,
                              ),
                            ),
                            Text(
                              '${_minDb.round()} dB',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: _mutedText,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // Sliders area
                        SizedBox(
                          height: 175,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: List.generate(_bands.length, (index) {
                              final gain = _bands[index];
                              final freqLabel = index < _frequencies.length
                                  ? _frequencies[index]
                                  : 'B${index + 1}';
                              final isPos = gain > 0.05;
                              final isNeg = gain < -0.05;
                              final color = isPos
                                  ? _posEqColor
                                  : (isNeg ? _negEqColor : _mutedText);
                              final text = isPos
                                  ? '+${gain.toStringAsFixed(1)}'
                                  : (isNeg
                                      ? gain.toStringAsFixed(1)
                                      : '0.0');

                              return Expanded(
                                child: Column(
                                  children: [
                                    // dB label above slider
                                    Text(
                                      text,
                                      style: GoogleFonts.poppins(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: color,
                                      ),
                                    ),
                                    const SizedBox(height: 6),

                                    // Vertical slider with 0dB baseline
                                    Expanded(
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Positioned(
                                            left: 2,
                                            right: 2,
                                            child: Container(
                                              height: 1,
                                              color: _borderColor,
                                            ),
                                          ),
                                          RotatedBox(
                                            quarterTurns: 3,
                                            child: SliderTheme(
                                              data: SliderTheme.of(context)
                                                  .copyWith(
                                                trackHeight: 2.8,
                                                thumbShape:
                                                    const RoundSliderThumbShape(
                                                  enabledThumbRadius: 5.5,
                                                  elevation: 1,
                                                  pressedElevation: 3,
                                                ),
                                                overlayShape:
                                                    const RoundSliderOverlayShape(
                                                  overlayRadius: 12,
                                                ),
                                                activeTrackColor: _activeBlue,
                                                inactiveTrackColor:
                                                    _sliderInactive,
                                                thumbColor: _activeBlue,
                                                overlayColor: _activeBlue
                                                    .withValues(alpha: 0.16),
                                              ),
                                              child: Slider(
                                                value: gain.clamp(
                                                  _minDb,
                                                  _maxDb,
                                                ),
                                                min: _minDb,
                                                max: _maxDb,
                                                onChanged: _enabled
                                                    ? (val) => _onBandChanged(
                                                          index,
                                                          val,
                                                        )
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 8),

                                    // Frequency label badge
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _elevatedBg,
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        border: Border.all(
                                          color: _borderColor,
                                          width: 1,
                                        ),
                                      ),
                                      child: Text(
                                        freqLabel,
                                        style: GoogleFonts.poppins(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500,
                                          color: _secondaryText,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 6. Bass Boost Card
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedOpacity(
                  opacity: _enabled ? 1.0 : 0.38,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _cardBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _borderColor, width: 1),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _accentSoft,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _borderColor),
                              ),
                              child: Center(
                                child: Icon(
                                  PhosphorIconsBold.speakerSimpleHigh,
                                  size: 18,
                                  color: _accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Bass Boost',
                                    style: GoogleFonts.poppins(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _textColor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Low-frequency depth & punch',
                                    style: GoogleFonts.poppins(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w400,
                                      color: _secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${(_bassBoost * 100).round()}%',
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _bassBoost > 0.001
                                    ? _activeBlue
                                    : _secondaryText,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.5,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7.0,
                              elevation: 1,
                              pressedElevation: 3,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 13,
                            ),
                            activeTrackColor: _activeBlue,
                            inactiveTrackColor: _sliderInactive,
                            thumbColor: _activeBlue,
                            overlayColor:
                                _activeBlue.withValues(alpha: 0.16),
                          ),
                          child: Slider(
                            value: _bassBoost.clamp(0.0, 1.0),
                            min: 0.0,
                            max: 1.0,
                            onChanged: _enabled ? _onBassBoostChanged : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Bottom safe-area spacing
              SizedBox(
                height: math.max(
                      MediaQuery.paddingOf(context).bottom,
                      16.0,
                    ) +
                    10.0,
              ),
            ],
          ),
        ),
      ),
    );
  }
} 



