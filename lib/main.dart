import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:phosphor_icons/phosphor_icons.dart';
import 'package:url_launcher/url_launcher.dart';

const _apiRoot = 'https://music-api.albatross0071.workers.dev';
const _fallbackArt =
    'https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRKzFIZo0IV9H2PER0gKrlsPHoB0NIxu_U_JSJySOR_3A&s=10';
const _ink = Color(0xff080808);
const _surface = Color(0xff151518);
const _muted = Color(0xff92929b);

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
    final images = (json['image'] as List? ?? const []).whereType<Map>().toList();
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
      songCount: int.tryParse('${json['songCount'] ?? songsList.length}') ??
          songsList.length,
      songs: songsList,
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                    API                                     */
/* -------------------------------------------------------------------------- */

const _apiHeaders = {
  'origin': 'https://listenfree.in',
  'referer': 'https://listenfree.in/',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36',
};

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

  static Future<List<Song>> suggestions(String id, {int limit = 15}) async {
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

  static Future<Playlist?> playlist(String id, {int limit = 50}) async {
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

final _homeSongs = <Song>[
  Song(
    id: 'UWD1fvFV',
    title: 'Love Me Not',
    artist: 'Ravyn Lenae',
    album: 'Love Me Not / Love Is Blind',
    artwork:
        'https://c.saavncdn.com/546/Love-Me-Not-Love-Is-Blind-English-2024-20240807224721-500x500.jpg',
  ),
  Song(
    id: 'VaNhRJHr',
    title: 'Die With A Smile',
    artist: 'Lady Gaga, Bruno Mars',
    album: 'Die With A Smile',
    artwork:
        'https://c.saavncdn.com/060/Die-With-A-Smile-English-2024-20240816103634-500x500.jpg',
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
    id: 'TcDP-KUl',
    title: 'Starboy',
    artist: 'The Weeknd',
    album: 'The Highlights',
    artwork:
        'https://c.saavncdn.com/396/The-Highlights-English-2021-20240207045714-500x500.jpg',
  ),
  Song(
    id: 'wwSCc15h',
    title: 'Shape of You',
    artist: 'Ed Sheeran',
    album: '÷',
    artwork:
        'https://c.saavncdn.com/286/WMG_190295851286-English-2017-500x500.jpg',
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
    id: 'H0IRhlNT',
    title: 'Baby',
    artist: 'Justin Bieber',
    album: 'My World 2.0',
    artwork:
        'https://c.saavncdn.com/728/My-World-2-0-English-2010-20250315014144-500x500.jpg',
  ),
  Song(
    id: 'd9GD5TGF',
    title: 'Eastside',
    artist: 'Benny Blanco, Halsey, Khalid',
    album: 'FRIENDS KEEP SECRETS 2',
    artwork:
        'https://c.saavncdn.com/070/FRIENDS-KEEP-SECRETS-2-English-2021-20210326053554-500x500.jpg',
  ),
];

final _featuredPlaylists = <Playlist>[
  Playlist(
    id: '1214368402',
    title: 'Badshah - Party Songs - Hindi',
    description: 'Hindi party songs of Badshah.',
    artwork:
        'https://c.saavncdn.com/editorial/BadshahPartySongsHindi_20240307110923.jpg?bch=1788764581',
    songCount: 24,
  ),
  Playlist(
    id: '47599074',
    title: 'Now Trending - Hindi',
    description: 'The hottest trending tracks right now.',
    artwork:
        'https://c.saavncdn.com/editorial/NowTrendingHindi_20240410072044.jpg',
    songCount: 30,
  ),
  Playlist(
    id: '79653434',
    title: 'Non-Stop Party',
    description: 'High energy dance and party anthems.',
    artwork:
        'https://c.saavncdn.com/editorial/NonStopParty_20240214064512.jpg',
    songCount: 25,
  ),
  Playlist(
    id: '1302033575',
    title: 'Romantic Hits 2026',
    description: 'Soulful melodies and timeless romantic hits.',
    artwork:
        'https://c.saavncdn.com/editorial/RomanticHitsHindi_20240214064512.jpg',
    songCount: 25,
  ),
  Playlist(
    id: '1261305331',
    title: 'Trending Songs India',
    description: 'Viral songs topping the charts across India.',
    artwork:
        'https://c.saavncdn.com/editorial/TrendingSongsIndia_20240307110923.jpg',
    songCount: 28,
  ),
];

void main() => runApp(const SonixApp());

class SonixApp extends StatelessWidget {
  const SonixApp({super.key});

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
    home: const SonixHome(),
  );
}

/* -------------------------------------------------------------------------- */
/*                                    HOME                                    */
/* -------------------------------------------------------------------------- */

class SonixHome extends StatefulWidget {
  const SonixHome({super.key});

  @override
  State<SonixHome> createState() => _SonixHomeState();
}

class _SonixHomeState extends State<SonixHome>
    with TickerProviderStateMixin {
  final _search = TextEditingController();
  final _audio = AudioPlayer();
  late final AnimationController _gradientAnim;

  List<Song> _results = [];
  List<Playlist> _playlistResults = [];
  List<Song> _queue = [..._homeSongs];
  List<Song> _history = [];
  bool _isFetchingMoreSuggestions = false;

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
  StreamSubscription<ProcessingState>? _processingSub;
  final Map<String, Future<List<Color>>> _paletteFutures = {};

  @override
  void initState() {
    super.initState();
    _gradientAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat(reverse: true);
    _search.addListener(_onSearchChanged);
    _playingSub = _audio.playingStream.listen((_) {
      if (mounted) setState(() {});
    });
    _processingSub = _audio.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && mounted) {
        _playNext();
      }
    });
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _gradientAnim.dispose();
    _search.removeListener(_onSearchChanged);
    _playingSub?.cancel();
    _processingSub?.cancel();
    _audio.dispose();
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
        _queue = songs;
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

  Future<void> _play(Song song) async {
    final request = ++_playRequest;
    // Same track -> just toggle.
    if (_current?.id == song.id && !_isLoadingTrack) {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        unawaited(_audio.play());
      }
      if (mounted) setState(() {});
      return;
    }

    setState(() {
      _current = song;
      _isLoadingTrack = true;
      _lyrics = null;
      _parsedLyrics = [];
      _lyricsOpen = false;
      _history = [
        song,
        ..._history.where((item) => item.id != song.id),
      ].take(5).toList();
    });

    try {
      await _audio.stop();
      if (!mounted || request != _playRequest) return;

      final details = await Api.details(song.id);
      if (!mounted || request != _playRequest) return;

      final resolved = details == null ? song : Song.fromJson(details);
      final urls = resolved.downloadUrls;
      final match = urls.where((item) => item['quality'] == '320kbps').toList();
      final stream =
          (match.isNotEmpty
                  ? match.first
                  : (urls.isEmpty ? null : urls.last))?['url']
              as String?;

      setState(() => _current = resolved.copyWith(streamUrl: stream));

      if (stream != null) {
        await _audio.setUrl(stream);
        if (!mounted || request != _playRequest) return;
        setState(() => _isLoadingTrack = false);
        unawaited(_audio.play());
      } else if (mounted && request == _playRequest) {
        setState(() => _isLoadingTrack = false);
      }

      // Only fetch suggestions if this song is the last song of the queue
      final currentIndex = _queue.indexWhere((s) => s.id == resolved.id);
      if (currentIndex >= 0 && currentIndex == _queue.length - 1) {
        unawaited(_fetchMoreSuggestionsForQueue(resolved.id));
      }

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

  void _playNext() async {
    if (_isLoadingTrack || _current == null || _queue.isEmpty) return;
    final index = _queue.indexWhere(
      (song) => song.id == _current!.id,
    );
    if (index < 0) return;

    // If current song is the last in the queue, fetch more first.
    if (index + 1 >= _queue.length) {
      await _fetchMoreSuggestionsForQueue(_current!.id);
      if (!mounted) return;
      // After fetching, check if there's a next song now.
      if (index + 1 < _queue.length) {
        unawaited(_play(_queue[index + 1]));
      }
      return;
    }

    unawaited(_play(_queue[index + 1]));

    // If the next song is now the last song in the queue, prefetch more suggestions.
    if (index + 1 == _queue.length - 1) {
      unawaited(_fetchMoreSuggestionsForQueue(_queue[index + 1].id));
    }
  }

  /// When the current song is the last in the queue,
  /// fetch the next 15 recommendations based on it and append to the queue.
  Future<void> _fetchMoreSuggestionsForQueue(String songId) async {
    if (_isFetchingMoreSuggestions || _queue.isEmpty) return;

    _isFetchingMoreSuggestions = true;
    try {
      final newSuggestions = await Api.suggestions(songId, limit: 15);
      if (!mounted || newSuggestions.isEmpty) return;
      // Filter out songs already in the queue to avoid duplicates.
      final existingIds = _queue.map((s) => s.id).toSet();
      final unique =
          newSuggestions.where((s) => !existingIds.contains(s.id)).toList();
      if (unique.isNotEmpty && mounted) {
        setState(() => _queue = [..._queue, ...unique]);
      }
    } catch (_) {
      // Silently ignore
    } finally {
      _isFetchingMoreSuggestions = false;
    }
  }

  void _next() {
    _playNext();
  }

  void _previous() {
    final list = _history.length > 1 ? _history : _queue;
    if (list.isEmpty) return;
    final index = list.indexWhere((song) => song.id == _current?.id);
    _play(list[index <= 0 ? list.length - 1 : index - 1]);
  }

  void _togglePlayPause() {
    if (_current == null) return;
    if (_audio.playing) {
      unawaited(_audio.pause());
    } else {
      unawaited(_audio.play());
    }
  }

  void _seek(double seconds) =>
      _audio.seek(Duration(milliseconds: (seconds * 1000).round()));

  Future<void> _download(Song song) async {
    final url =
        song.streamUrl ??
        (song.downloadUrls.isEmpty
            ? null
            : song.downloadUrls.last['url'] as String?);
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /* ------------------------------- PALETTE ------------------------------- */

  Future<List<Color>> _paletteFor(Song song) {
    final key = song.artwork.trim().isEmpty ? _fallbackArt : song.artwork.trim();
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
      canPop: !_fullScreen && _openedPlaylist == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_fullScreen) {
            setState(() => _fullScreen = false);
          } else if (_openedPlaylist != null) {
            setState(() => _openedPlaylist = null);
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
                  else
                    _header(),
                  Expanded(
                    child: _openedPlaylist != null
                        ? _playlistView()
                        : (_homeMode ? _home() : _searchResults()),
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
                    'Sonix',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFamily: GoogleFonts.inter().fontFamily,
                    ),
                  ),
                  Text(
                    'SONG PLAYER',
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
            hintStyle: const TextStyle(color: _muted, fontWeight: FontWeight.w400),
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
      _section('Trending', _homeSongs.take(5).toList(), horizontal: true),
      _section('Suggested for You', _homeSongs.skip(2).take(6).toList()),
      _section('Most Played', _homeSongs.skip(3).toList(), horizontal: true),
      _section(
        'Top Hits',
        _homeSongs.reversed.take(6).toList(),
        horizontal: true,
      ),
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
      onTap: () {
        if (contextQueue != null && _queue != contextQueue) {
          setState(() => _queue = [...contextQueue]);
        }
        _play(song);
      },
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
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(PhosphorIconsRegular.musicNotes, size: 11, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text(
                        '${playlist.songCount > 0 ? playlist.songCount : 20} songs',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white70),
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
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.25),
          ),
          if (playlist.description.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              playlist.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _row(Song song, [List<Song>? contextQueue]) {
    final isCurrent = _current?.id == song.id;
    return InkWell(
      onTap: () {
        if (contextQueue != null && _queue != contextQueue) {
          setState(() => _queue = [...contextQueue]);
        }
        _play(song);
      },
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
                    style: const TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w500),
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
              onPressed: () {
                if (contextQueue != null && _queue != contextQueue) {
                  setState(() => _queue = [...contextQueue]);
                }
                _play(song);
              },
              icon: Icon(
                isCurrent && _audio.playing
                    ? PhosphorIconsRegular.pause
                    : PhosphorIconsRegular.play,
              ),
            ),
            IconButton(
              onPressed: () => _download(song),
              icon: const Icon(PhosphorIconsRegular.downloadSimple, size: 19),
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
                const Icon(PhosphorIconsRegular.playlist, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Playlists (${_playlistResults.length})',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
                    style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w600),
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
                    : () {
                        setState(() {
                          _queue = [...playlist.songs];
                        });
                        _play(playlist.songs.first);
                      },
                icon: const Icon(PhosphorIconsFill.play, size: 18, color: Colors.black),
                label: const Text(
                  'Play All',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                        setState(() {
                          _queue = shuffled;
                        });
                        _play(shuffled.first);
                      },
                icon: const Icon(PhosphorIconsRegular.shuffle, size: 18, color: Colors.white),
                label: const Text(
                  'Shuffle',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                Text('Loading playlist songs...', style: TextStyle(color: _muted)),
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
    return InkWell(
      onTap: () {
        if (_queue != playlist.songs) {
          setState(() => _queue = [...playlist.songs]);
        }
        _play(song);
      },
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
                      color: isCurrent ? Colors.white : Colors.white.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w500),
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
              onPressed: () {
                if (_queue != playlist.songs) {
                  setState(() => _queue = [...playlist.songs]);
                }
                _play(song);
              },
              icon: Icon(
                isCurrent && _audio.playing
                    ? PhosphorIconsRegular.pause
                    : PhosphorIconsRegular.play,
                size: 20,
              ),
            ),
            IconButton(
              onPressed: () => _download(song),
              icon: const Icon(PhosphorIconsRegular.downloadSimple, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchRow(int index, Song song) {
    final isCurrent = _current?.id == song.id;
    return InkWell(
      onTap: () {
        if (_queue != _results) {
          setState(() => _queue = [..._results]);
        }
        _play(song);
      },
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
                    style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () {
                if (_queue != _results) {
                  setState(() => _queue = [..._results]);
                }
                _play(song);
              },
              icon: const Icon(PhosphorIconsRegular.play),
            ),
            IconButton(
              onPressed: () => _download(song),
              icon: const Icon(PhosphorIconsRegular.downloadSimple, size: 19),
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
                    onPressed: () =>
                        setState(() => _lyricsOpen = !_lyricsOpen),
                    icon: Icon(
                      PhosphorIconsRegular.textAa,
                      size: 20,
                      color: _lyricsOpen ? Colors.white : _muted,
                    ),
                    tooltip: 'Lyrics',
                  ),
                  IconButton(
                    onPressed: _previous,
                    icon: const Icon(
                      PhosphorIconsRegular.skipBack,
                      size: 20,
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: _audio.playingStream,
                    builder: (_, snapshot) => IconButton(
                      onPressed: _isLoadingTrack ? null : _togglePlayPause,
                      icon: _isLoadingTrack
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            )
                          : Icon(
                              snapshot.data == true
                                  ? PhosphorIconsRegular.pauseCircle
                                  : PhosphorIconsRegular.playCircle,
                              size: 34,
                            ),
                    ),
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

  Widget _progressBar({double minHeight = 3}) => StreamBuilder<Duration?>(
    stream: _audio.durationStream,
    builder: (_, durationSnapshot) {
      final duration = durationSnapshot.data;
      return StreamBuilder<Duration>(
        stream: _audio.positionStream,
        builder: (_, positionSnapshot) {
          final position = positionSnapshot.data ?? Duration.zero;
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
                  final ease = Curves.easeInOutCubic.transform(_gradientAnim.value);
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
                        StreamBuilder<bool>(
                          stream: _audio.playingStream,
                          builder: (_, snapshot) => IconButton(
                            onPressed: _isLoadingTrack
                                ? null
                                : _togglePlayPause,
                            icon: _isLoadingTrack
                                ? const SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                    ),
                                  )
                                : Icon(
                                    snapshot.data == true
                                        ? PhosphorIconsRegular.pauseCircle
                                        : PhosphorIconsRegular.playCircle,
                                    size: 64,
                                  ),
                          ),
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
    builder: (_, durationSnapshot) {
      final duration = durationSnapshot.data ?? Duration.zero;
      final maxMs = duration.inMilliseconds.toDouble();
      return StreamBuilder<Duration>(
        stream: _audio.positionStream,
        builder: (_, positionSnapshot) {
          final position = positionSnapshot.data ?? Duration.zero;
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
                  children: [Text(_time(position)), Text(_time(duration))],
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
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
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
                bottom: 24.0 + math.max(MediaQuery.paddingOf(context).bottom, 14.0),
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

