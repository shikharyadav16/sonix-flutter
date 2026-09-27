import 'package:flutter/services.dart';

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
  static const int crossfadeDurationSeconds = 8;

  /// The lead time (in seconds) before the crossfade starts during which the
  /// next track is pre-fetched and pre-buffered silently into the inactive player.
  /// Example: If [crossfadeDurationSeconds] is 5 and [prefetchLeadSeconds] is 8,
  /// preloading triggers 13 seconds before the current song ends (5 + 8 = 13s).
  static const int prefetchLeadSeconds = 5;

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

  /// The official JioSaavn public API endpoint.
  /// Direct mobile frontend integration — no backend proxy server needed.
  static const String saavnApiBaseUrl = 'https://www.jiosaavn.com/api.php';

  /// Legacy alias for compatibility.
  static const String apiBaseUrl = saavnApiBaseUrl;

  /// Standard HTTP headers sent with JioSaavn API requests.
  static const Map<String, String> saavnHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://www.jiosaavn.com/',
    'Accept': 'application/json, text/plain, */*',
  };

  /// Legacy alias for compatibility.
  static const Map<String, String> apiHeaders = saavnHeaders;

  /// Default stream audio quality preference if not specified by user profile.
  /// Common options: '320kbps', '160kbps', '96kbps', '48kbps', '12kbps'.
  static const String defaultSongQuality = '320kbps';

  // ---------------------------------------------------------------------------
  // 4. UI ASSETS, ANIMATIONS & THEME COLORS
  // ---------------------------------------------------------------------------

  /// Default theme mode applied on startup if not customized by user.
  /// Options: 'system', 'dark', 'light'.
  static const String defaultTheme = 'dark';

  /// Alias for [defaultTheme] for consistency with theme mode terminology.
  static const String defaultThemeMode = defaultTheme;

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

  /// Clean light background color for light mode.
  static const Color colorLightBackground = Color(0xFFF6F7F9);

  /// Clean white surface color for light mode cards, sheets, and dialogs.
  static const Color colorLightSurface = Color(0xFFFFFFFF);

  /// Muted grey color for secondary text, subtitle metadata, and inactive icons.
  static const Color colorMuted = Color(0xff92929b);

  /// Horizontal gradient colors for the user's name in the top navigation bar (light blue to light purple).
  static const List<Color> userNameGradientColors = [
    Color(0xff7dd3fc),
    Color(0xffc4b5fd),
  ];

  /// Corner radius for song item thumbnail images in rows and search results.
  static const double songRowThumbnailRadius = 8.0;

  // ---------------------------------------------------------------------------
  // 5. USER PROFILE CONFIGURATION & LIMITS
  // ---------------------------------------------------------------------------

  /// Maximum permitted length for a user's first name (characters before first space).
  static const int maxFirstNameLength = 18;

  /// Maximum permitted length for a user's full name.
  static const int maxFullNameLength = 28;

  /// Convenience alias for [maxFullNameLength].
  static const int maxNameLength = maxFullNameLength;

  // ---------------------------------------------------------------------------
  // 6. LYRICS CONFIGURATION & TYPOGRAPHY
  // ---------------------------------------------------------------------------

  /// Font size for synced lyrics lines (uniform across active and inactive states).
  static const double lyricsFontSize = 24.0;

  /// Font weight for synced lyrics lines (uniform across active and inactive states).
  static const FontWeight lyricsFontWeight = FontWeight.w700;

  /// Line height multiplier for synced lyrics lines.
  static const double lyricsLineHeight = 1.45;

  /// Estimated line height in pixels used for smooth auto-scroll positioning.
  static const double lyricsEstimatedLineHeight = 56.0;

  /// Font size for unsynced plain lyrics fallback text.
  static const double plainLyricsFontSize = 20.0;

  /// Font weight for unsynced plain lyrics fallback text.
  static const FontWeight plainLyricsFontWeight = FontWeight.w600;

  // ---------------------------------------------------------------------------
  // 7. SPEED DIAL CONFIGURATION
  // ---------------------------------------------------------------------------

  /// Optional note / subtitle text displayed beneath the "Speed Dial" header.
  /// If set to an empty string, the note label is automatically hidden.
  static const String speedDialNoteText = '';
}

/// Text input formatter that enforces both first name (<= 18 chars) and
/// full name (<= 28 chars) constraints.
class UserNameTextInputFormatter extends TextInputFormatter {
  const UserNameTextInputFormatter({
    this.maxFirstName = AppConstants.maxFirstNameLength,
    this.maxTotal = AppConstants.maxFullNameLength,
  });

  final int maxFirstName;
  final int maxTotal;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.length > maxTotal) {
      return oldValue;
    }

    final trimmed = text.trimLeft();
    final firstSpaceIndex = trimmed.indexOf(' ');
    final firstName = firstSpaceIndex == -1
        ? trimmed
        : trimmed.substring(0, firstSpaceIndex);
    if (firstName.length > maxFirstName) {
      return oldValue;
    }

    return newValue;
  }
}
