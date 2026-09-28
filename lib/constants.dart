import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ============================================================================
/// APP CONSTANTS & CENTRALIZED DESIGN SYSTEM
/// ============================================================================
/// Centralized file for all static values, tunable configurations, typography
/// definitions, theme colors, and the customizable Notice banner across Sonix.
/// Modify the values in this file to adjust playback behaviors, network endpoints,
/// typography, colors, and UI banner content.
abstract class AppConstants {
  // ---------------------------------------------------------------------------
  // 1. NOTICE BANNER CONFIGURATION & COLORS
  // ---------------------------------------------------------------------------

  /// The bold title displayed at the top of the home screen notice card.
  /// Example: 'Notice', 'Update', 'Maintenance', etc.
  // static const String noticeTitle = 'Notice';
  static const String noticeTitle = '';

  /// The message content displayed inside the home screen notice card.
  /// IMPORTANT: If set to an empty string (''), the notice card is completely
  /// hidden and removed from the layout.
  // static const String noticeContent =
  //     "We can't add new artists or songs here right now.";
  static const String noticeContent =
      "";

  /// Notice card background fill color in Light Mode (warm amber cream).
  static const Color noticeBgLight = Color(0xfffefce8);

  /// Notice card background fill color in Dark Mode (deep warm bronze).
  static const Color noticeBgDark = Color(0xff211c0b);

  /// Notice card outline border color in Light Mode (soft golden amber).
  static const Color noticeBorderLight = Color(0xfffef08a);

  /// Notice card outline border color in Dark Mode (muted bronze).
  static const Color noticeBorderDark = Color(0xff816b22);

  /// Notice info icon color in Light Mode.
  static const Color noticeIconLight = Color(0xffca8a04);

  /// Notice info icon color in Dark Mode.
  static const Color noticeIconDark = Color(0xffeab308);

  /// Notice header title text color in Light Mode.
  static const Color noticeTitleLight = Color(0xff854d0e);

  /// Notice header title text color in Dark Mode.
  static const Color noticeTitleDark = Color(0xffffd95c);

  /// Notice message body text color in Light Mode.
  static const Color noticeTextLight = Color(0xffa16207);

  /// Notice message body text color in Dark Mode.
  static const Color noticeTextDark = Color(0xffd8cfa5);

  /// Notice dismiss (close 'x') button color in Light Mode.
  static const Color noticeCloseIconLight = Color(0xff854d0e);

  /// Notice dismiss (close 'x') button color in Dark Mode.
  static const Color noticeCloseIconDark = Color(0xff92929b);

  // ---------------------------------------------------------------------------
  // 2. FONTS & TYPOGRAPHY SYSTEM
  // ---------------------------------------------------------------------------

  /// Primary application font family name (GoogleFonts.manrope).
  /// Modern geometric sans-serif typeface with excellent legibility and clean curves.
  // static const String fontPrimaryFamily = 'Manrope';
  static const String fontPrimaryFamily = 'Poppins';

  /// Secondary font family name (GoogleFonts.poppins).
  /// Used for Equalizer presets, sliders, and audio frequency labels.
  static const String fontSecondaryFamily = 'Poppins';

  // --- Font Weights ---

  /// Ultra-heavy weight (900) for the top navbar `Hello, <User>`, "Sonix" branding,
  /// and fullscreen hero titles.
  static const FontWeight fontWeightUltraBold = FontWeight.w900;

  /// Extra bold weight (800) for song titles, section headings, card titles,
  /// and primary modal headers.
  static const FontWeight fontWeightTitle = FontWeight.w900;

  /// Bold weight (700) for interactive buttons, tabs, speed dial titles, and dialog actions.
  static const FontWeight fontWeightBold = FontWeight.w700;

  /// Semi-bold weight (600) for artist names, badges, chip tags, and secondary action labels.
  static const FontWeight fontWeightSemiBold = FontWeight.w600;

  /// Medium weight (500) for playlist descriptions, album tags, and track timestamps.
  static const FontWeight fontWeightMedium = FontWeight.w500;

  /// Regular weight (400) for general body text, search hints, and settings explanations.
  static const FontWeight fontWeightRegular = FontWeight.w400;

  // --- Font Sizes ---

  /// Font size for the top navbar greeting (`Hello, <User>`).
  static const double fontSizeNavbarGreeting = 20.0;

  /// Font size for major section titles ("Trending Now", "Quick Picks", "Offline Songs").
  static const double fontSizeSectionHeader = 18.0;

  /// Font size for track titles in list rows and search results.
  static const double fontSizeTrackTitle = 14.0;

  /// Font size for secondary artist and album metadata in list rows.
  static const double fontSizeTrackSubtitle = 12.0;

  /// Font size for grid card titles (artists, playlists, albums).
  static const double fontSizeCardTitle = 14.5;

  /// Font size for compact badges, quality tags, and chip labels.
  static const double fontSizeBadge = 11.0;

  /// Font size for the persistent miniplayer song title.
  static const double fontSizeMiniplayerTitle = 13.5;

  /// Font size for the persistent miniplayer artist subtitle.
  static const double fontSizeMiniplayerArtist = 11.5;

  /// Font size for the fullscreen player track title.
  static const double fontSizePlayerTitle = 22.0;

  /// Font size for the fullscreen player artist subtitle.
  static const double fontSizePlayerArtist = 15.0;

  /// Font size for modal and alert dialog titles.
  static const double fontSizeDialogTitle = 17.5;

  // ---------------------------------------------------------------------------
  // 3. TEXT COLOR SYSTEM (DARK & LIGHT THEMES)
  // ---------------------------------------------------------------------------

  /// High-contrast primary text color for Dark Mode.
  // static const Color colorTextDark = Colors.white;
  static const Color colorTextDark = Color(0xffd9d9d9);

  /// High-contrast primary text color for Light Mode (Slate 900).
  static const Color colorTextLight = Color(0xff2b2b2b);

  /// Secondary muted text color for Dark Mode (artist names, track durations).
  static const Color colorSubtextDark = Color(0xff92929b);

  /// Secondary muted text color for Light Mode (artist names, track durations - Slate 500).
  static const Color colorSubtextLight = Color(0xff64748b);

  /// Inactive / hint text color for Dark Mode (search bar placeholders).
  static const Color colorHintDark = Color(0xff52525b);

  /// Inactive / hint text color for Light Mode (search bar placeholders - Slate 400).
  static const Color colorHintLight = Color(0xff94a3b8);

  // ---------------------------------------------------------------------------
  // 4. SURFACE, CONTAINER & BORDER COLORS
  // ---------------------------------------------------------------------------

  /// Deep obsidian canvas background color for Dark Mode (primary scaffold background).
  static const Color colorInk = Color(0xff080808);

  /// Elevated dark surface color used for cards, bottom sheets, dialogs, and tiles.
  static const Color colorSurface = Color(0xff151518);

  /// Background color for modal bottom sheets and dialog cards in Dark Mode.
  static const Color colorSheetDark = Color(0xff16161b);

  /// Background color for persistent top headers and navigation in Dark Mode.
  static const Color colorHeaderDark = Color(0xee080808);

  /// Subtle semi-transparent border color for Dark Mode containers and cards.
  static const Color colorBorderDark = Color(0x18ffffff);

  /// Subtle divider line color for Dark Mode lists.
  static const Color colorDividerDark = Colors.white12;

  /// Subtle input background fill color for Dark Mode search fields.
  static const Color colorInputFillDark = Color(0x0fffffff);

  /// Clean light background color for Light Mode scaffold.
  static const Color colorLightBackground = Color(0xFFF6F7F9);

  /// Clean white surface color for Light Mode cards, sheets, and dialogs.
  static const Color colorLightSurface = Color(0xFFFFFFFF);

  /// Background color for modal bottom sheets and dialog cards in Light Mode.
  static const Color colorSheetLight = Color(0xFFFFFFFF);

  /// Background color for persistent top headers and navigation in Light Mode.
  static const Color colorHeaderLight = Color(0xFFFFFFFF);

  /// Subtle semi-transparent border color for Light Mode containers and cards.
  static const Color colorBorderLight = Color(0x18000000);

  /// Subtle divider line color for Light Mode lists.
  static const Color colorDividerLight = Color(0x12000000);

  /// Soft grey input background fill color for Light Mode search fields.
  static const Color colorInputFillLight = Color(0xfff1f3f5);

  /// Legacy alias for [colorSubtextDark] to maintain backwards compatibility.
  static const Color colorMuted = colorSubtextDark;

  // ---------------------------------------------------------------------------
  // 5. BRAND ACCENTS & INTERACTIVE COLORS
  // ---------------------------------------------------------------------------

  /// Primary brand blue used for primary buttons, active toggles, and highlights.
  static const Color colorAccentBlue = Color(0xff3B82F6);

  /// Green accent used for "Now Playing" indicators and success messages.
  static const Color colorAccentGreen = Color(0xff22c55e);

  /// Red accent used for destructive actions (e.g. "Delete Permanently" from storage).
  static const Color colorAccentRed = Color(0xffef4444);

  /// Golden yellow accent used for warnings, star ratings, and notice badges.
  static const Color colorAccentYellow = Color(0xffeab308);

  /// Horizontal gradient colors for the user's name in the top navigation bar (light blue to light purple).
  // static const List<Color> userNameGradientColors = [
  //   Color(0xff7dd3fc),
  //   Color(0xffc4b5fd),
  // ];
static const List<Color> userNameGradientColors = [
  Color(0xFF60A5FA), // Blue 400
  Color(0xFFA78BFA), // Purple 400
];
  /// Corner radius for song item thumbnail images in rows and search results.
  static const double songRowThumbnailRadius = 8.0;

  // ---------------------------------------------------------------------------
  // 6. AUDIO PLAYBACK & CROSSFADE CONFIGURATION
  // ---------------------------------------------------------------------------

  /// The duration of the audio crossfade transition in seconds.
  /// When crossfading starts, the outgoing song fades out (1.0 -> 0.0)
  /// and the incoming song fades in (0.0 -> 1.0) over this duration.
  static const int crossfadeDurationSeconds = 8;

  /// The lead time (in seconds) before the crossfade starts during which the
  /// next track is pre-fetched and pre-buffered silently into the inactive player.
  static const int prefetchLeadSeconds = 5;

  /// Minimum track duration (in seconds) required for crossfading to activate.
  static const int minCrossfadeSongDurationSeconds = 13;

  /// Update interval (in milliseconds) for the volume crossfade curve timer.
  static const int crossfadeTickIntervalMs = 40;

  /// Duration (in milliseconds) of the gentle fade-out applied to the currently
  /// playing song when the user manually taps a different song to avoid audio pops.
  static const int manualSwitchFadeOutMs = 350;

  // ---------------------------------------------------------------------------
  // 7. QUEUE & SUGGESTIONS CONFIGURATION
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
  // 8. API & NETWORK CONFIGURATION
  // ---------------------------------------------------------------------------

  /// The official JioSaavn public API endpoint.
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
  static const String defaultSongQuality = '320kbps';

  // ---------------------------------------------------------------------------
  // 9. THEME & VISUAL ASSETS
  // ---------------------------------------------------------------------------

  /// Default theme mode applied on startup if not customized by user ('dark', 'light', 'system').
  static const String defaultTheme = 'dark';

  /// Alias for [defaultTheme].
  static const String defaultThemeMode = defaultTheme;

  /// Fallback image URL displayed when a song or playlist does not supply artwork.
  static const String fallbackArtworkUrl =
      'https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRKzFIZo0IV9H2PER0gKrlsPHoB0NIxu_U_JSJySOR_3A&s=10';

  /// Duration in seconds for one full forward/reverse cycle of the player's background ambient gradient.
  static const int backgroundAnimationDurationSeconds = 14;

  // ---------------------------------------------------------------------------
  // 10. USER PROFILE CONFIGURATION & LIMITS
  // ---------------------------------------------------------------------------

  /// Maximum permitted length for a user's first name.
  static const int maxFirstNameLength = 18;

  /// Maximum permitted length for a user's full name.
  static const int maxFullNameLength = 28;

  /// Convenience alias for [maxFullNameLength].
  static const int maxNameLength = maxFullNameLength;

  // ---------------------------------------------------------------------------
  // 11. LYRICS CONFIGURATION & TYPOGRAPHY
  // ---------------------------------------------------------------------------

  /// Font size for synced lyrics lines.
  static const double lyricsFontSize = 24.0;

  /// Font weight for synced lyrics lines.
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
  // 12. SPEED DIAL CONFIGURATION
  // ---------------------------------------------------------------------------

  /// Optional note / subtitle text displayed beneath the "Speed Dial" header.
  /// If set to an empty string, the note label is automatically hidden.
  static const String speedDialNoteText = '';

  /// Space in pixels between individual song items (both horizontally and vertically)
  /// in the Speed Dial 3x3 grid.
  static const double speedDialItemSpacing = 10.0;

  /// Gap in pixels between consecutive carousel slides when swiping left and right.
  static const double speedDialSlideGap = 12.0;
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
