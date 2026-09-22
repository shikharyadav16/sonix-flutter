import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const _apiRoot = AppConstants.apiBaseUrl;
const _fallbackArt = AppConstants.fallbackArtworkUrl;
const _ink = AppConstants.colorInk;
const _surface = AppConstants.colorSurface;
const _muted = AppConstants.colorMuted;

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
    final images = (json['image'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final image = images.firstWhere(
      (item) => item['quality'] == '500x500',
      orElse: () => images.isEmpty ? const {} : images.last,
    );

    final artists = json['artists'] is Map
        ? (json['artists']['primary'] as List? ?? const [])
        : const [];

    final primaryArtistsString = artists
        .whereType<Map>()
        .map((a) => a['name'])
        .where((name) => name != null && '$name'.trim().isNotEmpty)
        .join(', ');

    final artist =
        json['primaryArtists'] ??
        json['singers'] ??
        json['artist'] ??
        (primaryArtistsString.isNotEmpty
            ? primaryArtistsString
            : (artists.isNotEmpty ? artists.first['name'] : 'Unknown artist'));

    final urls = (json['downloadUrl'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    final highestAudio = urls.firstWhere(
      (u) => u['quality'] == '320kbps',
      orElse: () => urls.isNotEmpty ? urls.last : const {},
    );
    final audioUrl =
        json['audioUrl'] as String? ?? highestAudio['url'] as String?;

    return Song(
      id: '${json['id'] ?? json['title']}',
      title: '${json['title'] ?? json['name'] ?? 'Unknown title'}',
      artist: '$artist',
      album: json['album'] is Map
          ? '${json['album']['name'] ?? ''}'
          : '${json['album'] ?? ''}',
      artwork: '${image['url'] ?? ''}',
      duration: int.tryParse('${json['duration'] ?? 0}') ?? 0,
      streamUrl: audioUrl,
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
  });

  final String id;
  final String title;
  final String description;
  final String artwork;
  final String url;
  final String language;
  final int songCount;
  final List<Song> songs;

  Playlist copyWith({
    String? id,
    String? title,
    String? description,
    String? artwork,
    String? url,
    String? language,
    int? songCount,
    List<Song>? songs,
  }) => Playlist(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    artwork: artwork ?? this.artwork,
    url: url ?? this.url,
    language: language ?? this.language,
    songCount: songCount ?? this.songCount,
    songs: songs ?? this.songs,
  );

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final images = (json['image'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final image = images.firstWhere(
      (item) => item['quality'] == '500x500',
      orElse: () => images.isEmpty ? const {} : images.last,
    );

    final songsRaw = json['songs'];
    final songsList = (songsRaw is List ? songsRaw : const [])
        .whereType<Map>()
        .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    return Playlist(
      id: '${json['id'] ?? ''}',
      title: '${json['name'] ?? json['title'] ?? 'Playlist'}',
      description: '${json['description'] ?? ''}',
      artwork: '${image['url'] ?? ''}',
      url: '${json['url'] ?? ''}',
      language: '${json['language'] ?? ''}',
      songCount:
          int.tryParse('${json['songCount'] ?? songsList.length}') ??
          songsList.length,
      songs: songsList,
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                    API                                     */
/* -------------------------------------------------------------------------- */

const _apiHeaders = AppConstants.apiHeaders;

class Api {
  static Future<Map<String, dynamic>> search(String query) async {
    final response = await http.get(
      Uri.parse(
        '$_apiRoot/api/search?query=${Uri.encodeQueryComponent(query)}',
      ),
      headers: _apiHeaders,
    );
    if (response.statusCode >= 400) throw Exception('Search failed');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> details(String id) async {
    final response = await http.get(
      Uri.parse('$_apiRoot/api/songs/${Uri.encodeComponent(id)}'),
      headers: _apiHeaders,
    );
    if (response.statusCode >= 400) return null;
    final data = jsonDecode(response.body)['data'];
    return data is List && data.isNotEmpty
        ? Map<String, dynamic>.from(data.first)
        : null;
  }

  static Future<List<Song>> suggestions(String id,
      {int limit = AppConstants.suggestionsBatchSize}) async {
    final response = await http.get(
      Uri.parse(
        '$_apiRoot/api/songs/${Uri.encodeComponent(id)}/suggestions'
        '?id=${Uri.encodeComponent(id)}&limit=$limit',
      ),
      headers: _apiHeaders,
    );
    if (response.statusCode >= 400) return [];
    final data = jsonDecode(response.body)['data'];
    return data is List
        ? data
              .whereType<Map>()
              .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
              .toList()
        : [];
  }

  static Future<Playlist?> playlist(String id,
      {int limit = AppConstants.playlistFetchLimit}) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$_apiRoot/api/playlists?id=${Uri.encodeComponent(id)}&limit=$limit',
        ),
        headers: _apiHeaders,
      );
      if (response.statusCode >= 400) return null;
      final json = jsonDecode(response.body);
      if (json is Map && json['success'] == true && json['data'] is Map) {
        return Playlist.fromJson(Map<String, dynamic>.from(json['data']));
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> lyrics(Song song) async {
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
    final response = await http.get(uri);
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

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final done = await UserStorage.isOnboardingComplete();
    UserProfile? profile;
    if (done) {
      profile = await UserStorage.getProfile();
    }
    if (mounted) {
      setState(() {
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

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Sonix',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.white,
        brightness: Brightness.dark,
      ),
      textTheme: GoogleFonts.interTextTheme(
        ThemeData(brightness: Brightness.dark).textTheme,
      ),
      fontFamily: GoogleFonts.inter().fontFamily,
    ),
    home: !_checkedOnboarding
        ? const Scaffold(
            backgroundColor: _ink,
            body: Center(child: CircularProgressIndicator(color: Colors.white)),
          )
        : (_isOnboarded
              ? SonixHome(userProfile: _userProfile)
              : OnboardingScreen(onComplete: _onComplete)),
  );
}

/* -------------------------------------------------------------------------- */
/*                                    HOME                                    */
/* -------------------------------------------------------------------------- */

class SonixHome extends StatefulWidget {
  const SonixHome({super.key, this.userProfile});

  final UserProfile? userProfile;

  @override
  State<SonixHome> createState() => _SonixHomeState();
}

class _SonixHomeState extends State<SonixHome> with TickerProviderStateMixin {
  UserProfile? _userProfile;
  final _search = TextEditingController();
  late final CrossfadePlayer _audio;
  late final AnimationController _gradientAnim;

  List<Song> _results = [];
  List<Playlist> _playlistResults = [];
  List<Song> _history = [];

  // ---- Queue / playback mode state ----
  PlaybackMode _playbackMode = PlaybackMode.suggestions;
  List<Song> _suggestionQueue = [];   // holds 15 suggestions at a time
  List<Song> _playlistQueue = [];     // all songs for playlist repeat
  int _playlistQueueIndex = -1;       // current index inside _playlistQueue
  bool _isFetchingSuggestions = false; // guard concurrent fetches
  Song? _preparedSong;
  String? _preparedStreamUrl;

  Map<String, Song> _likedSongs = {};
  bool _viewingLikedSongs = false;
  String _songQuality = '320kbps';
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;

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
  int _playRequest = 0;

  Map<String, dynamic>? _lyrics;
  List<LyricLine> _parsedLyrics = [];

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<ProcessingState>? _processingStateSub;
  final Map<String, Future<List<Color>>> _paletteFutures = {};

  @override
  void initState() {
    super.initState();
    _audio = audioHandler.player;
    audioHandler.onSkipNext = _next;
    audioHandler.onSkipPrevious = _previous;
    _audio.onPrepareNextTrack = _onPrepareNextTrack;
    _audio.onAutoCrossfadeTriggered = _onCrossfadeTriggered;

    _userProfile = widget.userProfile;
    if (_userProfile == null) {
      UserStorage.getProfile().then((p) {
        if (mounted && p != null) setState(() => _userProfile = p);
      });
    }
    _loadLikedSongs();
    UserStorage.getSongQuality().then((q) {
      if (mounted) setState(() => _songQuality = q);
    });
    _gradientAnim = AnimationController(
      vsync: this,
      duration: const Duration(
          seconds: AppConstants.backgroundAnimationDurationSeconds),
    )..repeat(reverse: true);
    _search.addListener(_onSearchChanged);
    _playingSub = _audio.playingStream.listen((_) {
      if (mounted) setState(() {});
    });
    // Detect song completion to auto-advance and update UI on state changes.
    _processingStateSub = _audio.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onSongCompleted();
      }
      if (mounted) setState(() {});
    });
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _gradientAnim.dispose();
    _search.removeListener(_onSearchChanged);
    _playingSub?.cancel();
    _processingStateSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  /* ------------------------------- SEARCH -------------------------------- */

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _homeMode = true;
        _playlistResults = [];
      });
      return;
    }
    setState(() {
      _searching = true;
      _homeMode = false;
      _openedPlaylist = null;
      _viewingLikedSongs = false;
    });
    try {
      final data = await Api.search(query);
      final groups = data['data'] as Map? ?? const {};
      final songs = (groups['songs']?['results'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      final playlists = (groups['playlists']?['results'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      if (!mounted) return;
      setState(() {
        _results = songs;
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

  Future<void> _openPlaylist(Playlist playlist) async {
    setState(() {
      _openedPlaylist = playlist;
      _viewingLikedSongs = false;
      _loadingPlaylist = playlist.songs.isEmpty;
    });

    if (playlist.songs.isEmpty) {
      try {
        final full = await Api.playlist(playlist.id);
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

  AudioSource _sourceForSong(Song song, String stream) =>
      AudioSource.uri(Uri.parse(stream), tag: song.id);


  /// Resolve a song's stream URL and full metadata via the API.
  Future<(Song, String?)?> _resolveSong(Song song) async {
    final details = await Api.details(song.id);
    final resolved = details == null ? song : Song.fromJson(details);
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
  Future<void> _play(Song song) async {
    final request = ++_playRequest;
    _preparedSong = null;
    _preparedStreamUrl = null;

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

    // Stop previous track immediately so old audio doesn't play while new song is being fetched
    unawaited(_audio.stop());

    setState(() {
      _current = song;
      _isLoadingTrack = true;
      _lyrics = null;
      _parsedLyrics = [];
      _lyricsOpen = false;
      _history = [
        song,
        ..._history.where((item) => item.id != song.id),
      ].take(AppConstants.historyLimit).toList();
    });

    try {
      if (!mounted || request != _playRequest) return;

      final result = await _resolveSong(song);
      if (!mounted || request != _playRequest) return;

      if (result == null) {
        setState(() => _isLoadingTrack = false);
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
        await _audio.playDirect(source, fadeCurrentOut: false);
        if (!mounted || request != _playRequest) return;
        setState(() => _isLoadingTrack = false);
      } else if (mounted && request == _playRequest) {
        setState(() => _isLoadingTrack = false);
      }

      // Fetch lyrics in background.
      final lyricData = await Api.lyrics(resolved);
      if (!mounted || request != _playRequest) return;
      setState(() {
        _lyrics = lyricData;
        _parsedLyrics = parseLyrics(lyricData?['syncedLyrics'] as String?);
      });
    } catch (_) {
      if (mounted && request == _playRequest) {
        setState(() => _isLoadingTrack = false);
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
  Future<void> _playPlaylist(List<Song> songs) async {
    if (songs.isEmpty) return;

    setState(() {
      _playbackMode = PlaybackMode.playlist;
      _suggestionQueue = [];
      _playlistQueue = [...songs];
      _playlistQueueIndex = 0;
    });

    await _play(songs.first);
  }

  /* -------------------- Song completion / auto-advance ------------------- */

  /// Called when the active player reaches ProcessingState.completed.
  void _onSongCompleted() {
    if (_isLoadingTrack || _current == null) return;
    // If an active crossfade is currently transitioning, skip auto-advance.
    if (_audio.isCrossfading) return;
    _advanceToNextSong();
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
    _playlistQueueIndex = (_playlistQueueIndex + 1) % _playlistQueue.length;
    _play(_playlistQueue[_playlistQueueIndex]);
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
            _history = [
              resolved,
              ..._history.where((item) => item.id != resolved.id),
            ].take(AppConstants.historyLimit).toList();
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
            if (mounted) {
              setState(() {
                _lyrics = lyricData;
                _parsedLyrics = parseLyrics(lyricData?['syncedLyrics'] as String?);
              });
            }
          }).catchError((_) {});
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
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isEmpty) return null;
      final nextIdx = (_playlistQueueIndex + 1) % _playlistQueue.length;
      return _playlistQueue[nextIdx];
    } else {
      return _suggestionQueue.isNotEmpty ? _suggestionQueue.first : null;
    }
  }

  /// Consume (advance past) the next song in the queue.
  void _consumeNextSong([Song? justPlayed]) {
    if (_playbackMode == PlaybackMode.playlist) {
      if (_playlistQueue.isEmpty) return;
      _playlistQueueIndex = (_playlistQueueIndex + 1) % _playlistQueue.length;
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
    _advanceToNextSong();
  }

  void _previous() {
    if (_history.length > 1) {
      // Play the previous song from history.
      final index = _history.indexWhere((song) => song.id == _current?.id);
      if (index > 0) {
        _play(_history[index]);
      } else if (_history.length > 1) {
        _play(_history[1]);
      }
    } else if (_playbackMode == PlaybackMode.playlist && _playlistQueue.isNotEmpty) {
      _playlistQueueIndex = (_playlistQueueIndex - 1 + _playlistQueue.length) % _playlistQueue.length;
      _play(_playlistQueue[_playlistQueueIndex]);
    }
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
  }) {
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
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      isPlaying
                          ? PhosphorIconsRegular.pauseCircle
                          : PhosphorIconsRegular.playCircle,
                      size: iconSize,
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
        final palette = await PaletteGenerator.fromImageProvider(
          NetworkImage(key),
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
      canPop: !_fullScreen && _openedPlaylist == null && !_viewingLikedSongs,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_fullScreen) {
            setState(() => _fullScreen = false);
          } else if (_openedPlaylist != null) {
            setState(() => _openedPlaylist = null);
          } else if (_viewingLikedSongs) {
            setState(() => _viewingLikedSongs = false);
          }
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  if (_openedPlaylist != null)
                    _playlistHeader()
                  else if (_viewingLikedSongs)
                    _likedSongsHeader()
                  else
                    _header(),
                  Expanded(
                    child: _openedPlaylist != null
                        ? _playlistView()
                        : (_viewingLikedSongs
                              ? _likedSongsView()
                              : (_homeMode ? _home() : _searchResults())),
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
    setState(() {
      _fullScreenLyrics = false;
      _fullScreen = true;
    });
  }

  /* -------------------------------- HEADER ------------------------------- */

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
    decoration: const BoxDecoration(
      color: Color(0xee080808),
      border: Border(bottom: BorderSide(color: Color(0x18ffffff))),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            _search.clear();
            setState(() {
              _homeMode = true;
              _openedPlaylist = null;
              _viewingLikedSongs = false;
              _playlistResults = [];
            });
          },
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(PhosphorIconsRegular.musicNote),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _userProfile != null && _userProfile!.name.isNotEmpty
                        ? 'Hello, ${_userProfile!.name.split(' ').first}'
                        : 'Sonix',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFamily: GoogleFonts.inter().fontFamily,
                    ),
                  ),
                  Text(
                    _userProfile != null && _userProfile!.name.isNotEmpty
                        ? 'ENJOY YOUR MUSIC'
                        : 'SONG PLAYER',
                    style: TextStyle(
                      fontSize: 9,
                      color: _muted,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                      fontFamily: GoogleFonts.inter().fontFamily,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: _openUserMenu,
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .12),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1.2),
                  ),
                  child: const Icon(
                    PhosphorIconsBold.user,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: _runSearch,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'Search songs, artists, albums...',
            hintStyle: const TextStyle(
              color: _muted,
              fontWeight: FontWeight.w400,
            ),
            prefixIcon: const Icon(
              PhosphorIconsRegular.magnifyingGlass,
              size: 19,
            ),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(PhosphorIconsRegular.x, size: 17),
                    onPressed: () {
                      _search.clear();
                      setState(() {
                        _homeMode = true;
                        _openedPlaylist = null;
                        _viewingLikedSongs = false;
                        _playlistResults = [];
                      });
                    },
                  ),
            filled: true,
            fillColor: Colors.white.withValues(alpha: .06),
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
      if (_noticeVisible) _notice(),
      _section('Trending', _trendingSongs, horizontal: true),
      _section('Suggested for You', _suggestedSongs),
      _section('Most Played', _mostPlayedSongs, horizontal: true),
      _section('Top Hits', _topHitsSongs, horizontal: true),
      _featuredPlaylistsSection(),
      const SizedBox(height: 16),
      const Center(
        child: Text(
          'Next-generation music streaming experience',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ),
      const SizedBox(height: 6),
      const Center(
        child: Text(
          '© 2026 Sonix Music Streaming Inc.',
          style: TextStyle(color: Color(0xff57575d), fontSize: 11),
        ),
      ),
    ],
  );

  Widget _notice() => Container(
    margin: const EdgeInsets.only(bottom: 22),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xff211c0b),
      border: Border.all(color: const Color(0xff816b22)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const Icon(PhosphorIconsRegular.info, color: Color(0xffeab308)),
        const SizedBox(width: 11),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Notice',
                style: TextStyle(
                  color: Color(0xffffd95c),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                "We can't add new artists or songs here right now.",
                style: TextStyle(fontSize: 12, color: Color(0xffd8cfa5)),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => setState(() => _noticeVisible = false),
          icon: const Icon(PhosphorIconsRegular.x, size: 17, color: _muted),
        ),
      ],
    ),
  );

  Widget _section(String title, List<Song> songs, {bool horizontal = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
              style: const TextStyle(
                color: _muted,
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
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featuredPlaylistsSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Icon(PhosphorIconsRegular.playlist, size: 22, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'Featured Playlists',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 240,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _featuredPlaylists.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, i) => _playlistCard(_featuredPlaylists[i]),
        ),
      ),
      const SizedBox(height: 26),
    ],
  );

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
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          if (playlist.description.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              playlist.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _muted,
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
          color: isCurrent ? Colors.white.withValues(alpha: .1) : _surface,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            _art(song.artwork, width: 55, height: 55),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _muted,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, contextQueue),
              icon: const Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
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
        errorBuilder: (_, _, _) => Container(
          width: width,
          height: height,
          color: _surface,
          child: const Icon(PhosphorIconsRegular.musicNote, color: _muted),
        ),
      ),
    );
  }

  /* ----------------------------- SEARCH RESULT ---------------------------- */

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
    if (_results.isEmpty && _playlistResults.isEmpty) {
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
        if (_playlistResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                const Icon(
                  PhosphorIconsRegular.playlist,
                  size: 20,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  'Playlists (${_playlistResults.length})',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
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
          const SizedBox(height: 24),
        ],
        if (_results.isNotEmpty) ...[
          const Text(
            'Songs',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ..._results.asMap().entries.map(
            (entry) => _searchRow(entry.key, entry.value),
          ),
        ],
      ],
    );
  }

  /* ------------------------------ PLAYLIST VIEW --------------------------- */

  Widget _playlistHeader() => Container(
    padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
    decoration: const BoxDecoration(
      color: Color(0xee080808),
      border: Border(bottom: BorderSide(color: Color(0x18ffffff))),
    ),
    child: Row(
      children: [
        IconButton(
          icon: const Icon(PhosphorIconsRegular.arrowLeft, size: 22),
          onPressed: () => setState(() => _openedPlaylist = null),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            _openedPlaylist?.title ?? 'Playlist',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                      color: Colors.white.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Text(
                      'PLAYLIST',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    playlist.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  if (playlist.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      playlist.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${playlist.songs.isNotEmpty ? playlist.songs.length : (playlist.songCount > 0 ? playlist.songCount : 0)} Songs',
                    style: const TextStyle(
                      color: _muted,
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
                icon: const Icon(
                  PhosphorIconsFill.play,
                  size: 18,
                  color: Colors.black,
                ),
                label: const Text(
                  'Play All',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
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
                icon: const Icon(
                  PhosphorIconsRegular.shuffle,
                  size: 18,
                  color: Colors.white,
                ),
                label: const Text(
                  'Shuffle',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24),
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
          const Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text(
                  'Loading playlist songs...',
                  style: TextStyle(color: _muted),
                ),
              ],
            ),
          ),
        ] else if (playlist.songs.isEmpty) ...[
          const SizedBox(height: 40),
          const Center(
            child: Text(
              'No songs available in this playlist',
              style: TextStyle(color: _muted),
            ),
          ),
        ] else ...[
          Text(
            'Tracks (${playlist.songs.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
            SizedBox(
              width: 28,
              child: Text(
                isCurrent && _audio.playing ? '▶' : '${index + 1}',
                style: TextStyle(
                  color: isCurrent ? Colors.white : _muted,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
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
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: isCurrent
                          ? Colors.white
                          : Colors.white.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
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
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _muted,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, playlist.songs),
              icon: const Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
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
            SizedBox(
              width: 28,
              child: Text(
                isCurrent && _audio.playing ? '▶' : '${index + 1}',
                style: const TextStyle(color: _muted),
              ),
            ),
            _art(song.artwork, width: 53, height: 53),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
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
                color: isLiked ? Colors.redAccent : _muted,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, _results),
              icon: const Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
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
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: Color(0x22ffffff))),
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
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _muted,
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
                          : _muted,
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
                      color: _lyricsOpen ? Colors.white : _muted,
                    ),
                    tooltip: 'Lyrics',
                  ),
                  IconButton(
                    onPressed: _previous,
                    icon: const Icon(PhosphorIconsRegular.skipBack, size: 20),
                  ),
                  _buildPlayPauseButton(
                    iconSize: 34,
                    spinnerSize: 24,
                    strokeWidth: 2.4,
                  ),
                  IconButton(
                    onPressed: _next,
                    icon: const Icon(
                      PhosphorIconsRegular.skipForward,
                      size: 20,
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
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          );
        },
      );
    },
  );

  /* -------------------------------- LYRICS -------------------------------- */

  Widget _lyricsSheet() => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .78,
    maxChildSize: .94,
    minChildSize: .45,
    builder: (context, controller) => Container(
      decoration: const BoxDecoration(
        color: Color(0xff18181d),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
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
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              title: const Text(
                'Lyrics',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              trailing: IconButton(
                onPressed: () => setState(() => _lyricsOpen = false),
                icon: const Icon(PhosphorIconsRegular.x),
              ),
            ),
            Expanded(child: _lyricsBody(controller)),
          ],
        ),
      ),
    ),
  );

  Widget _lyricsBody([ScrollController? controller]) {
    return _LyricsAutoScrollView(
      lyrics: _lyrics,
      parsedLyrics: _parsedLyrics,
      positionStream: _audio.positionStream,
      onSeek: _seek,
      controller: controller,
    );
  }

  /* ------------------------------ FULL SCREEN ----------------------------- */

  Widget _fullScreenView() {
    final track = _current!;
    return FutureBuilder<List<Color>>(
      future: _paletteFor(track),
      builder: (context, paletteSnapshot) {
        final colors = _paletteOrDefault(paletteSnapshot);
        final artworkColor = colors.first;
        final secondaryColor = colors.length > 1 ? colors[1] : artworkColor;
        final tertiaryColor = colors.length > 2 ? colors[2] : secondaryColor;
        return Material(
          color: _ink,
          child: Stack(
            children: [
              Container(color: const ui.Color(0xff080808)),
              // Animated multi-blob gradient background.
              AnimatedBuilder(
                animation: _gradientAnim,
                builder: (context, child) {
                  final ease = Curves.easeInOutCubic.transform(
                    _gradientAnim.value,
                  );
                  final breath = math.sin(ease * math.pi);
                  final shift = ease * 2.0 - 1.0;
                  return ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 100, sigmaY: 100),
                    child: Stack(
                      children: [
                        // Primary orb — top area (anchored behind album artwork & title).
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(
                                  -0.05 + shift * 0.08,
                                  -0.42 + breath * 0.07,
                                ),
                                radius: 1.05 + breath * 0.18,
                                colors: [
                                  artworkColor.withValues(alpha: 0.6),
                                  artworkColor.withValues(alpha: 0.6),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.42, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Secondary orb — right side (anchored mid-right).
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(
                                  0.50 - breath * 0.09,
                                  0.05 + shift * 0.10,
                                ),
                                radius: 0.92 + (1.0 - breath) * 0.16,
                                colors: [
                                  secondaryColor.withValues(alpha: 0.92),
                                  secondaryColor.withValues(alpha: 0.45),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.38, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Tertiary orb — bottom (anchored around playback controls).
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(
                                  -0.32 + shift * 0.08,
                                  0.62 - breath * 0.08,
                                ),
                                radius: 0.98 + breath * 0.16,
                                colors: [
                                  tertiaryColor.withValues(alpha: 0.28),
                                  tertiaryColor.withValues(alpha: 0.38),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.4, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              // Subtle darkening overlay for readability.
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      ui.Color(0x10000000),
                      ui.Color(0x30000000),
                      ui.Color(0x70000000),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 12, 6),
                      child: Row(
                        children: [
                          const Icon(PhosphorIconsRegular.musicNote, size: 19),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Now Playing',
                              style: TextStyle(fontWeight: FontWeight.w700),
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
                                  : Colors.white,
                              size: 22,
                            ),
                            tooltip: _likedSongs.containsKey(track.id)
                                ? 'Unlike'
                                : 'Like',
                          ),
                          IconButton(
                            onPressed: () => _showSongOptions(track),
                            icon: const Icon(
                              PhosphorIconsRegular.dotsThreeVertical,
                              size: 22,
                            ),
                            tooltip: 'Options',
                          ),
                          IconButton(
                            onPressed: () =>
                                setState(() => _fullScreen = false),
                            icon: const Icon(PhosphorIconsRegular.caretDown),
                            tooltip: 'Minimize player',
                          ),
                        ],
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _fullScreenTab(
                              icon: PhosphorIconsRegular.disc,
                              label: 'Player',
                              active: !_fullScreenLyrics,
                              onTap: () =>
                                  setState(() => _fullScreenLyrics = false),
                            ),
                          ),
                          Expanded(
                            child: _fullScreenTab(
                              icon: PhosphorIconsRegular.textAa,
                              label: 'Lyrics',
                              active: _fullScreenLyrics,
                              onTap: () =>
                                  setState(() => _fullScreenLyrics = true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _fullScreenLyrics
                          ? _lyricsBody()
                          : SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 24),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: _art(
                                      track.artwork,
                                      width: 280,
                                      height: 280,
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    child: Text(
                                      track.title,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    child: Text(
                                      track.artist,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _muted,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                ],
                              ),
                            ),
                    ),
                    _fullScreenSlider(),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: _previous,
                          icon: const Icon(
                            PhosphorIconsRegular.skipBack,
                            size: 32,
                          ),
                        ),
                        const SizedBox(width: 12),
                        _buildPlayPauseButton(
                          iconSize: 64,
                          spinnerSize: 52,
                          strokeWidth: 3.0,
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: _next,
                          icon: const Icon(
                            PhosphorIconsRegular.skipForward,
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
                Slider(
                  value: value,
                  max: maxMs <= 0 ? 1 : maxMs,
                  onChanged: maxMs <= 0
                      ? null
                      : (v) => _audio.seek(Duration(milliseconds: v.round())),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_time(position)), Text(_time(duration!))],
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
        color: active ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 17, color: active ? _ink : Colors.white),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: active ? _ink : Colors.white,
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

  Future<void> _toggleLike(Song song) async {
    final currentlyLiked = _likedSongs.containsKey(song.id);
    final updated = Map<String, Song>.from(_likedSongs);
    if (currentlyLiked) {
      updated.remove(song.id);
    } else {
      updated[song.id] = song;
    }
    setState(() => _likedSongs = updated);

    final rawList = updated.values.map((s) => s.toJson()).toList();
    await UserStorage.saveLikedSongsRaw(rawList);
  }

  void _openUserMenu() {
    showModalBottomSheet(
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
          decoration: const BoxDecoration(
            color: Color(0xff16161b),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
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
                    gradient: const LinearGradient(
                      colors: [Color(0xffff416c), Color(0xffff4b2b)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xffff416c).withValues(alpha: .3),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(
                    PhosphorIconsFill.heart,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Liked Songs',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                subtitle: Text(
                  '${_likedSongs.length} ${_likedSongs.length == 1 ? 'track' : 'tracks'}',
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                trailing: const Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _muted,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _viewingLikedSongs = true;
                    _openedPlaylist = null;
                    _homeMode = false;
                  });
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
                    color: Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Icon(
                    PhosphorIconsRegular.gearSix,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                subtitle: const Text(
                  'Audio quality & profile preferences',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                trailing: const Icon(
                  PhosphorIconsRegular.caretRight,
                  color: _muted,
                  size: 20,
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openSettings();
                },
              ),
            ],
          ),
        ),
      ),
    );
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
    final nameCtrl = TextEditingController(text: _userProfile?.name ?? '');
    final ageCtrl = TextEditingController(
      text: _userProfile?.age != null ? '${_userProfile!.age}' : '',
    );
    final hoursCtrl = TextEditingController(text: '0');
    final minutesCtrl = TextEditingController(text: '30');
    String selectedQuality = _songQuality;
    Timer? liveTicker;

    final qualityOptions = [
      {
        'value': '320kbps',
        'label': 'Very High (320 kbps)',
        'desc': 'Best sound quality, higher data usage',
      },
      {
        'value': '160kbps',
        'label': 'High (160 kbps)',
        'desc': 'Great sound, balanced data usage',
      },
      {
        'value': '96kbps',
        'label': 'Medium (96 kbps)',
        'desc': 'Good quality, data saver',
      },
      {
        'value': '48kbps',
        'label': 'Low (48 kbps)',
        'desc': 'Minimal data, best for slow networks',
      },
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setModalState) {
          liveTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
            if (_sleepTimerEndTime != null && ctx.mounted) {
              setModalState(() {});
            }
          });
          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.85,
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                decoration: const BoxDecoration(
                  color: Color(0xff16161b),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: Colors.white12)),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Settings',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              PhosphorIconsRegular.x,
                              size: 20,
                              color: _muted,
                            ),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Song Audio Quality',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _muted,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ...qualityOptions.map((opt) {
                        final isSelected = selectedQuality == opt['value'];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white.withValues(alpha: .1)
                                : Colors.white.withValues(alpha: .04),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.white70
                                  : Colors.white10,
                              width: isSelected ? 1.2 : 1,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              setModalState(
                                () => selectedQuality = opt['value']!,
                              );
                              setState(() => _songQuality = opt['value']!);
                              await UserStorage.saveSongQuality(opt['value']!);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isSelected
                                        ? PhosphorIconsFill.checkCircle
                                        : PhosphorIconsRegular.circle,
                                    color: isSelected ? Colors.white : _muted,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          opt['label']!,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: isSelected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          opt['desc']!,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: _muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 20),
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                PhosphorIconsRegular.moonStars,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Sleep Timer',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _muted,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          if (_sleepTimerEndTime != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.indigoAccent.withValues(
                                  alpha: .2,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.indigoAccent.withValues(
                                    alpha: .4,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: Colors.indigoAccent,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    () {
                                      final rem =
                                          _sleepTimerRemaining ?? Duration.zero;
                                      final h = rem.inHours;
                                      final m = rem.inMinutes % 60;
                                      final s = rem.inSeconds % 60;
                                      if (h > 0) {
                                        return '${h}h ${m}m ${s}s left';
                                      }
                                      return '${m}m ${s}s left';
                                    }(),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_sleepTimerEndTime != null) ...[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.indigoAccent.withValues(
                                        alpha: .2,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      PhosphorIconsRegular.clockCountdown,
                                      color: Colors.indigoAccent,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Sleep Timer is Active',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(height: 2),
                                        Text(
                                          'Playback will stop automatically',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    _cancelSleepTimer();
                                    setModalState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Text(
                                          'Sleep timer turned off',
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
                                  icon: const Icon(
                                    PhosphorIconsRegular.xCircle,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                  label: const Text(
                                    'Turn Off Sleep Timer',
                                    style: TextStyle(
                                      color: Colors.redAccent,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: BorderSide(
                                      color: Colors.redAccent.withValues(
                                        alpha: .5,
                                      ),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Hours',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _muted,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  TextField(
                                    controller: hoursCtrl,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    textAlign: TextAlign.center,
                                    decoration: InputDecoration(
                                      hintText: '0',
                                      hintStyle: const TextStyle(color: _muted),
                                      filled: true,
                                      fillColor: Colors.white.withValues(
                                        alpha: .06,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Minutes',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _muted,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  TextField(
                                    controller: minutesCtrl,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    textAlign: TextAlign.center,
                                    decoration: InputDecoration(
                                      hintText: '30',
                                      hintStyle: const TextStyle(color: _muted),
                                      filled: true,
                                      fillColor: Colors.white.withValues(
                                        alpha: .06,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in [
                              {'label': '15 min', 'h': '0', 'm': '15'},
                              {'label': '30 min', 'h': '0', 'm': '30'},
                              {'label': '45 min', 'h': '0', 'm': '45'},
                              {'label': '1 hr', 'h': '1', 'm': '0'},
                              {'label': '2 hrs', 'h': '2', 'm': '0'},
                            ])
                              GestureDetector(
                                onTap: () {
                                  setModalState(() {
                                    hoursCtrl.text = preset['h']!;
                                    minutesCtrl.text = preset['m']!;
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .07),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Text(
                                    preset['label']!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          height: 42,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              final h =
                                  int.tryParse(hoursCtrl.text.trim()) ?? 0;
                              final m =
                                  int.tryParse(minutesCtrl.text.trim()) ?? 0;
                              final totalSeconds = (h * 3600) + (m * 60);
                              if (totalSeconds <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: const Text(
                                      'Please enter a duration greater than 0 minutes',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }
                              _setSleepTimer(Duration(seconds: totalSeconds));
                              setModalState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    h > 0
                                        ? 'Sleep timer set for $h hour${h > 1 ? 's' : ''} $m minute${m != 1 ? 's' : ''}'
                                        : 'Sleep timer set for $m minute${m != 1 ? 's' : ''}',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            icon: const Icon(
                              PhosphorIconsRegular.timer,
                              size: 18,
                            ),
                            label: const Text(
                              'Start Sleep Timer',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: .15,
                              ),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 18),
                      const Text(
                        'Edit Profile',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _muted,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: nameCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Your Name',
                          labelStyle: const TextStyle(color: _muted),
                          prefixIcon: const Icon(
                            PhosphorIconsRegular.user,
                            color: _muted,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: ageCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Your Age',
                          labelStyle: const TextStyle(color: _muted),
                          prefixIcon: const Icon(
                            PhosphorIconsRegular.calendar,
                            color: _muted,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: () async {
                            final name = nameCtrl.text.trim();
                            final age = int.tryParse(ageCtrl.text.trim());
                            if (name.isNotEmpty && age != null && age > 0) {
                              final updated = UserProfile(name: name, age: age);
                              await UserStorage.saveProfile(
                                name: name,
                                age: age,
                              );
                              if (mounted) {
                                setState(() => _userProfile = updated);
                              }
                              if (ctx.mounted) {
                                Navigator.of(ctx).pop();
                              }
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: const Text(
                                      'Profile updated successfully',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Save Changes',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height:
                            math.max(MediaQuery.paddingOf(ctx).bottom, 24.0) +
                            16.0,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ).whenComplete(() => liveTicker?.cancel());
  }

  void _showSongOptions(Song song, [List<Song>? contextQueue]) {
    final isLiked = _likedSongs.containsKey(song.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: Color(0xff16161b),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: _muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : Colors.white,
                size: 24,
              ),
              title: Text(
                isLiked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isLiked ? Colors.redAccent : Colors.white,
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleLike(song);
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(
                PhosphorIconsBold.play,
                color: Colors.white,
                size: 24,
              ),
              title: const Text(
                'Play Song',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _playSongForSuggestionMode(song);
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(
                PhosphorIconsBold.downloadSimple,
                color: Colors.white,
                size: 24,
              ),
              title: const Text(
                'Download',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              subtitle: Text(
                'Get audio in $_songQuality',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _download(song);
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
    decoration: const BoxDecoration(
      color: Color(0xee080808),
      border: Border(bottom: BorderSide(color: Color(0x18ffffff))),
    ),
    child: Row(
      children: [
        IconButton(
          icon: const Icon(PhosphorIconsRegular.arrowLeft, size: 22),
          onPressed: () => setState(() => _viewingLikedSongs = false),
        ),
        const SizedBox(width: 4),
        const Expanded(
          child: Text(
            'Liked Songs',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                  const Text(
                    'Liked Songs',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _userProfile != null && _userProfile!.name.isNotEmpty
                        ? 'Curated by ${_userProfile!.name}'
                        : 'Your personal collection',
                    style: const TextStyle(color: _muted, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
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
                          icon: const Icon(
                            PhosphorIconsBold.play,
                            size: 16,
                            color: Colors.black,
                          ),
                          label: const Text(
                            'Play All',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
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
                          icon: const Icon(
                            PhosphorIconsRegular.shuffle,
                            size: 20,
                            color: Colors.white,
                          ),
                          tooltip: 'Shuffle',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: .1),
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
                  color: Colors.white.withValues(alpha: .2),
                ),
                const SizedBox(height: 16),
                const Text(
                  'No Liked Songs Yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tap the heart icon on any song to save it here permanently.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 13),
                ),
              ],
            ),
          )
        else ...[
          const Text(
            'Tracks',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
            SizedBox(
              width: 28,
              child: Text(
                isCurrent && _audio.playing ? '▶' : '${index + 1}',
                style: TextStyle(
                  color: isCurrent ? Colors.white : _muted,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
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
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: isCurrent
                          ? Colors.white
                          : Colors.white.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
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
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
            IconButton(
              onPressed: () => _toggleLike(song),
              icon: Icon(
                isLiked ? PhosphorIconsFill.heart : PhosphorIconsRegular.heart,
                color: isLiked ? Colors.redAccent : _muted,
                size: 20,
              ),
              tooltip: isLiked ? 'Unlike' : 'Like',
            ),
            IconButton(
              onPressed: () => _showSongOptions(song, likedList),
              icon: const Icon(
                PhosphorIconsRegular.dotsThreeVertical,
                size: 20,
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
    required this.positionStream,
    required this.onSeek,
    this.controller,
  });

  final Map<String, dynamic>? lyrics;
  final List<LyricLine> parsedLyrics;
  final Stream<Duration> positionStream;
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
  Timer? _userResumeTimer;

  ScrollController get _effectiveController =>
      widget.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    _internalController = ScrollController();
  }

  @override
  void didUpdateWidget(covariant _LyricsAutoScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.parsedLyrics != oldWidget.parsedLyrics) {
      _itemKeys.clear();
      _lastActiveIndex = -1;
      _userInteracting = false;
      _userResumeTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _userResumeTimer?.cancel();
    _internalController.dispose();
    super.dispose();
  }

  GlobalKey _keyForIndex(int index) =>
      _itemKeys.putIfAbsent(index, () => GlobalKey());

  void _scrollToIndex(int index) {
    if (index < 0 || index >= widget.parsedLyrics.length) return;
    final targetContext = _itemKeys[index]?.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.35,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    } else if (_effectiveController.hasClients) {
      final maxScroll = _effectiveController.position.maxScrollExtent;
      final estimatedOffset = (index * 56.0).clamp(0.0, maxScroll);
      _effectiveController
          .animateTo(
            estimatedOffset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _itemKeys[index]?.currentContext;
              if (ctx != null && mounted) {
                Scrollable.ensureVisible(
                  ctx,
                  alignment: 0.35,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                );
              }
            });
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lyrics == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final plain = widget.lyrics!['plainLyrics'] as String?;

    if (widget.parsedLyrics.isEmpty) {
      return SingleChildScrollView(
        controller: _effectiveController,
        padding: const EdgeInsets.all(24),
        child: Text(
          plain ?? 'No lyrics found for this track.',
          style: const TextStyle(fontSize: 18, height: 1.7, color: _muted),
        ),
      );
    }

    return StreamBuilder<Duration>(
      stream: widget.positionStream,
      builder: (context, snapshot) {
        final time = snapshot.data?.inMilliseconds ?? 0;
        var active = -1;
        for (var i = 0; i < widget.parsedLyrics.length; i++) {
          if (time >= widget.parsedLyrics[i].time * 1000) {
            active = i;
          }
        }

        if (active != _lastActiveIndex) {
          _lastActiveIndex = active;
          if (!_userInteracting && active >= 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollToIndex(active);
            });
          }
        }

        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is UserScrollNotification) {
                  if (notification.direction != ScrollDirection.idle) {
                    _userResumeTimer?.cancel();
                    if (!_userInteracting) {
                      setState(() => _userInteracting = true);
                    }
                  } else {
                    _userResumeTimer?.cancel();
                    _userResumeTimer = Timer(
                      const Duration(milliseconds: 3500),
                      () {
                        if (mounted) {
                          setState(() => _userInteracting = false);
                          if (_lastActiveIndex >= 0) {
                            _scrollToIndex(_lastActiveIndex);
                          }
                        }
                      },
                    );
                  }
                }
                return false;
              },
              child: ListView.builder(
                controller: _effectiveController,
                padding: const EdgeInsets.fromLTRB(22, 100, 22, 220),
                itemCount: widget.parsedLyrics.length,
                itemBuilder: (context, i) {
                  final isCurrent = i == active;
                  return InkWell(
                    key: _keyForIndex(i),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      widget.onSeek(widget.parsedLyrics[i].time);
                      _userResumeTimer?.cancel();
                      setState(() => _userInteracting = false);
                      _scrollToIndex(i);
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
                          fontSize: isCurrent ? 24 : 18,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isCurrent
                              ? Colors.white
                              : const Color(0x66ffffff),
                          height: 1.45,
                        ),
                        child: Text(widget.parsedLyrics[i].text),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Floating "Sync lyrics" pill when user scrolled away
            if (_userInteracting && active >= 0)
              Positioned(
                bottom:
                    24.0 + math.max(MediaQuery.paddingOf(context).bottom, 14.0),
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      _userResumeTimer?.cancel();
                      setState(() => _userInteracting = false);
                      _scrollToIndex(active);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xdd222228),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white24),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            PhosphorIconsRegular.arrowsClockwise,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Sync lyrics',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
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
