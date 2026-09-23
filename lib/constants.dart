import 'package:flutter/material.dart';

/// ============================================================================
/// APP CONSTANTS & STATIC CONFIGURATION
/// ============================================================================
/// Centralized file for all static values and tunable configurations across Sonix.
/// Modify the values in this file to adjust playback behaviors, network endpoints,
/// queue sizes, audio transition timings, and core UI theme colors.
abstract class AppConstants {
  // ---------------------------------------------------------------------------
  // 1. AUDIO PLAYBACK & CROSSFADE CONFIGURATION
  // ---------------------------------------------------------------------------

  /// The duration of the audio crossfade transition in seconds.
  /// When crossfading starts, the outgoing song fades out (1.0 -> 0.0)
  /// and the incoming song fades in (0.0 -> 1.0) over this duration.
  /// Standard music streaming behavior: 5 seconds.
  static const int crossfadeDurationSeconds = 5;

  /// The lead time (in seconds) before the crossfade starts during which the
  /// next track is pre-fetched and pre-buffered silently into the inactive player.
  /// Example: If [crossfadeDurationSeconds] is 5 and [prefetchLeadSeconds] is 8,
  /// preloading triggers 13 seconds before the current song ends (5 + 8 = 13s).
  static const int prefetchLeadSeconds = 8;

  /// Minimum track duration (in seconds) required for crossfading to activate.
  /// Songs shorter than this will play out to completion without crossfading.
  static const int minCrossfadeSongDurationSeconds = 13;

  /// Update interval (in milliseconds) for the volume crossfade curve timer.
  /// 40ms equates to 25 volume updates per second for a smooth transition.
  static const int crossfadeTickIntervalMs = 40;

  /// Duration (in milliseconds) of the gentle fade-out applied to the currently
  /// playing song when the user manually taps a different song to avoid audio pops.
  static const int manualSwitchFadeOutMs = 350;

  // ---------------------------------------------------------------------------
  // 2. QUEUE & SUGGESTIONS CONFIGURATION
  // ---------------------------------------------------------------------------

  /// Number of suggested songs requested from the API when a track begins playing
  /// or when the suggestion queue becomes exhausted.
  static const int suggestionsBatchSize = 15;

  /// Maximum number of recently played songs kept in device storage and memory
  /// for the "Previous" song action and persistent History section.
  static const int historyLimit = 10;

  /// Minimum playback duration (in seconds) required before a song is
  /// eligible to be added to the persistent History list.
  static const int minPlayDurationForHistorySeconds = 10;

  /// Maximum number of songs fetched when loading a full playlist from the API.
  static const int playlistFetchLimit = 50;

  // ---------------------------------------------------------------------------
  // 3. API & NETWORK CONFIGURATION
  // ---------------------------------------------------------------------------

  /// The base URL of the Cloudflare worker API endpoint for music searches,
  /// song details, suggestions, lyrics, and playlists.
  static const String apiBaseUrl = 'https://music-api.albatross0071.workers.dev';

  /// Standard HTTP headers sent with API requests to identify and authenticate.
  static const Map<String, String> apiHeaders = {
    'origin': 'https://listenfree.in',
    'referer': 'https://listenfree.in/',
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36',
  };

  /// Default stream audio quality preference if not specified by user profile.
  /// Common options: '320kbps', '160kbps', '96kbps', '48kbps', '12kbps'.
  static const String defaultSongQuality = '320kbps';

  // ---------------------------------------------------------------------------
  // 4. UI ASSETS, ANIMATIONS & THEME COLORS
  // ---------------------------------------------------------------------------

  /// Fallback image URL displayed when a song or playlist does not supply artwork.
  static const String fallbackArtworkUrl =
      'https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRKzFIZo0IV9H2PER0gKrlsPHoB0NIxu_U_JSJySOR_3A&s=10';

  /// Duration in seconds for one full forward/reverse cycle of the player's
  /// background ambient gradient animation.
  static const int backgroundAnimationDurationSeconds = 14;

  /// Deep black canvas background color (the primary scaffold background).
  static const Color colorInk = Color(0xff080808);

  /// Elevated dark surface color used for cards, bottom sheets, dialogs, and tiles.
  static const Color colorSurface = Color(0xff151518);

  /// Muted grey color for secondary text, subtitle metadata, and inactive icons.
  static const Color colorMuted = Color(0xff92929b);

  /// Horizontal gradient colors for the user's name in the top navigation bar (light blue to light purple).
  static const List<Color> userNameGradientColors = [
    Color(0xff7dd3fc),
    Color(0xffc4b5fd),
  ];
}
