import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:url_launcher/url_launcher.dart';

const _apiRoot = 'https://music-api.albatross0071.workers.dev';
const _fallbackArt =
    'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=700&q=80';
const _ink = Color(0xff080808);
const _surface = Color(0xff151518);
const _muted = Color(0xff92929b);

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
    final images = (json['image'] as List? ?? []).cast<Map>();
    final image = images.firstWhere(
      (item) => item['quality'] == '500x500',
      orElse: () => images.isEmpty ? {} : images.last,
    );
    final artists = json['artists'] is Map
        ? (json['artists']['primary'] as List? ?? [])
        : [];
    final artist =
        json['primaryArtists'] ??
        json['singers'] ??
        json['artist'] ??
        (artists.isNotEmpty ? artists.first['name'] : 'Unknown artist');
    final urls = (json['downloadUrl'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    return Song(
      id: '${json['id'] ?? json['title']}',
      title: json['title'] ?? json['name'] ?? 'Unknown title',
      artist: '$artist',
      album: json['album'] is Map
          ? '${json['album']['name'] ?? ''}'
          : '${json['album'] ?? ''}',
      artwork: '${image['url'] ?? ''}',
      duration: int.tryParse('${json['duration'] ?? 0}') ?? 0,
      streamUrl: json['audioUrl'],
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

class Api {
  static Future<Map<String, dynamic>> search(String query) async {
    final response = await http.get(
      Uri.parse(
        '$_apiRoot/api/search?query=${Uri.encodeQueryComponent(query)}',
      ),
    );
    if (response.statusCode >= 400) throw Exception('Search failed');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> details(String id) async {
    final response = await http.get(
      Uri.parse('$_apiRoot/api/songs/${Uri.encodeComponent(id)}'),
    );
    if (response.statusCode >= 400) return null;
    final data = jsonDecode(response.body)['data'];
    return data is List && data.isNotEmpty
        ? Map<String, dynamic>.from(data.first)
        : null;
  }

  static Future<List<Song>> suggestions(String id) async {
    final response = await http.get(
      Uri.parse(
        '$_apiRoot/api/songs/${Uri.encodeComponent(id)}/suggestions?id=${Uri.encodeComponent(id)}&limit=5',
      ),
    );
    if (response.statusCode >= 400) return [];
    final data = jsonDecode(response.body)['data'];
    return data is List
        ? data
              .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
              .toList()
        : [];
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
        ? 0
        : double.parse('0.${match.group(3)}');
    final text = raw.replaceAll(pattern, '').trim();
    result.add(
      LyricLine(
        (int.parse(match.group(1)!) * 60 +
                int.parse(match.group(2)!) +
                fraction)
            .toDouble(),
        text.isEmpty ? '♪' : text,
      ),
    );
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

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
      fontFamily: 'Arial',
    ),
    home: const SonixHome(),
  );
}

class SonixHome extends StatefulWidget {
  const SonixHome({super.key});
  @override
  State<SonixHome> createState() => _SonixHomeState();
}

class _SonixHomeState extends State<SonixHome> {
  final _search = TextEditingController();
  final _audio = AudioPlayer();
  List<Song> _results = [],
      _queue = [..._homeSongs],
      _history = [],
      _suggestions = [];
  Song? _current;
  bool _searching = false,
      _homeMode = true,
      _noticeVisible = true,
      _fullScreen = false,
      _lyricsOpen = false;
  Map<String, dynamic>? _lyrics;
  List<LyricLine> _parsedLyrics = [];
  StreamSubscription? _positionSubscription;
  final Map<String, Future<List<Color>>> _paletteFutures = {};

  @override
  void initState() {
    super.initState();
    _positionSubscription = _audio.positionStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _audio.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String value) async {
    if (value.trim().isEmpty) {
      setState(() => _homeMode = true);
      return;
    }
    setState(() {
      _searching = true;
      _homeMode = false;
    });
    try {
      final data = await Api.search(value.trim());
      final groups = data['data'] as Map? ?? {};
      final songs = (groups['songs']?['results'] as List? ?? [])
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      setState(() {
        _results = songs;
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

  Future<void> _play(Song song) async {
    if (_current?.id == song.id) {
      _audio.playing ? _audio.pause() : _audio.play();
      setState(() {});
      return;
    }
    setState(() {
      _current = song;
      _lyrics = null;
      _parsedLyrics = [];
      _lyricsOpen = false;
      _history = [
        song,
        ..._history.where((item) => item.id != song.id),
      ].take(5).toList();
    });
    try {
      final details = await Api.details(song.id);
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
        await _audio.play();
      }
      final suggestion = await Api.suggestions(resolved.id);
      if (mounted) setState(() => _suggestions = [resolved, ...suggestion]);
      final lyricData = await Api.lyrics(resolved);
      if (mounted) {
        setState(() {
          _lyrics = lyricData;
          _parsedLyrics = parseLyrics(lyricData?['syncedLyrics'] as String?);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This track could not be loaded.')),
        );
      }
    }
  }

  void _next() {
    final list = _suggestions.isNotEmpty ? _suggestions : _queue;
    if (list.isEmpty) return;
    final index = list.indexWhere((song) => song.id == _current?.id);
    _play(list[(index + 1) % list.length]);
  }

  void _previous() {
    final list = _history.length > 1 ? _history : _queue;
    if (list.isEmpty) return;
    final index = list.indexWhere((song) => song.id == _current?.id);
    _play(list[index <= 0 ? list.length - 1 : index - 1]);
  }

  Future<List<Color>> _paletteFor(Song song) {
    final key = song.artwork.isEmpty ? _fallbackArt : song.artwork;
    return _paletteFutures.putIfAbsent(key, () async {
      try {
        final palette = await PaletteGenerator.fromImageProvider(
          NetworkImage(key),
          maximumColorCount: 12,
        );
        final colors = <Color>[];
        if (palette.dominantColor != null) {
          colors.add(palette.dominantColor!.color);
        }
        colors.addAll(palette.colors);
        return colors.isEmpty
            ? const [Color(0xff25213f), Color(0xff0b0b12)]
            : colors.take(3).toList();
      } catch (_) {
        return const [Color(0xff25213f), Color(0xff0b0b12)];
      }
    });
  }

  List<Color> _paletteOrDefault(AsyncSnapshot<List<Color>> snapshot) =>
      snapshot.data ?? const [Color(0xff25213f), Color(0xff0b0b12)];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          _header(),
          Expanded(child: _homeMode ? _home() : _searchResults()),
          if (_current != null) _playerBar(),
        ],
      ),
    ),
    bottomSheet: _lyricsOpen && _current != null ? _lyricsSheet() : null,
  );

  void _openFullScreen() {
    if (_current == null) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => _fullScreenView()));
  }

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
    decoration: const BoxDecoration(
      color: Color(0xee080808),
      border: Border(bottom: BorderSide(color: Color(0x18ffffff))),
    ),
    child: Row(
      children: [
        GestureDetector(
          onTap: () {
            _search.clear();
            setState(() => _homeMode = true);
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
                child: const Icon(Icons.music_note_rounded),
              ),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sonix',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'SONG PLAYER',
                    style: TextStyle(
                      fontSize: 9,
                      color: _muted,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: _search,
            onSubmitted: _runSearch,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search songs, artists, albums etc...',
              hintStyle: const TextStyle(color: _muted),
              prefixIcon: const Icon(Icons.search, size: 19),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 17),
                      onPressed: () {
                        _search.clear();
                        setState(() => _homeMode = true);
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
        ),
      ],
    ),
  );

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
        const Icon(Icons.info_outline, color: Color(0xffeab308)),
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
          icon: const Icon(Icons.close, size: 17, color: _muted),
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
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          if (horizontal)
            SizedBox(
              height: 245,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: songs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, i) => _card(songs[i]),
              ),
            )
          else
            Column(children: songs.map(_row).toList()),
          const SizedBox(height: 26),
        ],
      );
  Widget _card(Song song) => GestureDetector(
    onTap: () => _play(song),
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
                    _current?.id == song.id && _audio.playing
                        ? Icons.pause
                        : Icons.play_arrow,
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
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
  Widget _row(Song song) => InkWell(
    onTap: () => _play(song),
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: _current?.id == song.id
            ? Colors.white.withValues(alpha: .1)
            : _surface,
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
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _play(song),
            icon: Icon(
              _current?.id == song.id && _audio.playing
                  ? Icons.pause
                  : Icons.play_arrow,
            ),
          ),
          IconButton(
            onPressed: () => _download(song),
            icon: const Icon(Icons.download_outlined, size: 19),
          ),
        ],
      ),
    ),
  );
  Widget _art(String url, {required double width, required double height}) =>
      Image.network(
        url.isEmpty ? _fallbackArt : url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Image.network(
          _fallbackArt,
          width: width,
          height: height,
          fit: BoxFit.cover,
        ),
      );

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
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'Discover any song, artist, or album',
          style: TextStyle(color: _muted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 22, 14, 120),
      children: [
        const Text(
          'Songs',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ..._results.asMap().entries.map(
          (entry) => _searchRow(entry.key, entry.value),
        ),
      ],
    );
  }

  Widget _searchRow(int index, Song song) => InkWell(
    onTap: () => _play(song),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              _current?.id == song.id && _audio.playing ? '▶' : '${index + 1}',
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
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _play(song),
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            onPressed: () => _download(song),
            icon: const Icon(Icons.download_outlined, size: 19),
          ),
        ],
      ),
    ),
  );

  Widget _playerBar() {
    final track = _current!;
    return FutureBuilder<List<Color>>(
      future: _paletteFor(track),
      builder: (context, paletteSnapshot) {
        final colors = _paletteOrDefault(paletteSnapshot);
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colors.first.withValues(alpha: .52),
                Color.alphaBlend(colors.last.withValues(alpha: .42), _ink),
              ],
            ),
            border: const Border(top: BorderSide(color: Color(0x30ffffff))),
          ),
          child: Column(
            children: [
              LinearProgressIndicator(
                value: _audio.duration == null
                    ? 0
                    : _audio.position.inMilliseconds /
                          _audio.duration!.inMilliseconds,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _openFullScreen,
                      child: Row(
                        children: [
                          _art(track.artwork, width: 44, height: 44),
                          const SizedBox(width: 9),
                          SizedBox(
                            width: 105,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _previous,
                      icon: const Icon(Icons.skip_previous, size: 20),
                    ),
                    StreamBuilder<bool>(
                      stream: _audio.playingStream,
                      builder: (_, snapshot) => IconButton(
                        onPressed: () =>
                            _audio.playing ? _audio.pause() : _audio.play(),
                        icon: Icon(
                          snapshot.data == true
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 34,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _next,
                      icon: const Icon(Icons.skip_next, size: 20),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _download(Song song) async {
    final url =
        song.streamUrl ??
        (song.downloadUrls.isEmpty
            ? null
            : song.downloadUrls.last['url'] as String?);
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  void _seek(double seconds) =>
      _audio.seek(Duration(milliseconds: (seconds * 1000).round()));

  Widget _lyricsSheet() => DraggableScrollableSheet(
    initialChildSize: .78,
    maxChildSize: .94,
    minChildSize: .45,
    builder: (_, controller) => Container(
      decoration: const BoxDecoration(
        color: Color(0xff18181d),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        children: [
          ListTile(
            title: const Text(
              'Lyrics',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            trailing: IconButton(
              onPressed: () => setState(() => _lyricsOpen = false),
              icon: const Icon(Icons.close),
            ),
          ),
          Expanded(child: _lyricsBody(controller)),
        ],
      ),
    ),
  );
  Widget _lyricsBody(ScrollController controller) {
    if (_lyrics == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final plain = _lyrics!['plainLyrics'] as String?;
    if (_parsedLyrics.isEmpty) {
      return SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.all(22),
        child: Text(
          plain ?? 'No lyrics found for this track.',
          style: const TextStyle(fontSize: 18, height: 1.7, color: _muted),
        ),
      );
    }
    return StreamBuilder<Duration>(
      stream: _audio.positionStream,
      builder: (_, snapshot) {
        final time = snapshot.data?.inMilliseconds ?? 0;
        var active = -1;
        for (var i = 0; i < _parsedLyrics.length; i++) {
          if (time >= _parsedLyrics[i].time * 1000) {
            active = i;
          }
        }
        return ListView.builder(
          controller: controller,
          padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 22),
          itemCount: _parsedLyrics.length,
          itemBuilder: (_, i) => InkWell(
            onTap: () => _seek(_parsedLyrics[i].time),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _parsedLyrics[i].text,
                style: TextStyle(
                  fontSize: i == active ? 23 : 18,
                  fontWeight: i == active ? FontWeight.w700 : FontWeight.w400,
                  color: i == active ? Colors.white : const Color(0xff66666d),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _fullScreenView() {
    final track = _current!;
    var showLyrics = false;
    return FutureBuilder<List<Color>>(
      future: _paletteFor(track),
      builder: (context, paletteSnapshot) {
        final colors = _paletteOrDefault(paletteSnapshot);
        return StatefulBuilder(
          builder: (context, setPageState) => Material(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-.75, -.8),
                  radius: 1.25,
                  colors: [
                    colors.first.withValues(alpha: .72),
                    Color.alphaBlend(colors.last.withValues(alpha: .55), _ink),
                    _ink,
                  ],
                  stops: const [0, .48, 1],
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 12, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                const Icon(Icons.music_note_rounded, size: 19),
                                const SizedBox(width: 8),
                                const Text(
                                  'Now Playing',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.keyboard_arrow_down),
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
                              icon: Icons.album_outlined,
                              label: 'Player',
                              active: !showLyrics,
                              onTap: () =>
                                  setPageState(() => showLyrics = false),
                            ),
                          ),
                          Expanded(
                            child: _fullScreenTab(
                              icon: Icons.lyrics_outlined,
                              label: 'Lyrics',
                              active: showLyrics,
                              onTap: () =>
                                  setPageState(() => showLyrics = true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: showLyrics
                          ? _lyricsBody(ScrollController())
                          : Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _art(track.artwork, width: 280, height: 280),
                                  const SizedBox(height: 28),
                                  Text(
                                    track.title,
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    track.artist,
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    StreamBuilder<Duration>(
                      stream: _audio.positionStream,
                      builder: (_, snapshot) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          children: [
                            Slider(
                              value: (_audio.duration?.inMilliseconds ?? 1) == 0
                                  ? 0
                                  : (snapshot.data?.inMilliseconds ?? 0)
                                        .clamp(
                                          0,
                                          _audio.duration?.inMilliseconds ?? 1,
                                        )
                                        .toDouble(),
                              max: (_audio.duration?.inMilliseconds ?? 1)
                                  .toDouble(),
                              onChanged: (value) => _audio.seek(
                                Duration(milliseconds: value.round()),
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_time(snapshot.data ?? Duration.zero)),
                                Text(_time(_audio.duration ?? Duration.zero)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: _previous,
                          icon: const Icon(Icons.skip_previous, size: 32),
                        ),
                        StreamBuilder<bool>(
                          stream: _audio.playingStream,
                          builder: (_, snapshot) => IconButton(
                            onPressed: () =>
                                _audio.playing ? _audio.pause() : _audio.play(),
                            icon: Icon(
                              snapshot.data == true
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              size: 64,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _next,
                          icon: const Icon(Icons.skip_next, size: 32),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

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
