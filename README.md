# Sonix — Modern Music Player Mobile App

Sonix is a premium, feature-rich music player application built with Flutter. Inspired by modern streaming experiences, Sonix blends fluid animations, dynamic ambient gradient lighting extracted from album artwork, and real-time synchronized lyrics into an ultra-sleek audio experience with full background playback support.

---

## Key Features and Functionalities

### 1. High-Fidelity Audio Streaming and Quality Settings

- **Selectable Bitrates**: Choose your preferred streaming and download quality:
  - **Very High (320 kbps)** — Highest audio fidelity and rich bass.
  - **High (160 kbps)** — Balanced quality and data usage.
  - **Medium (96 kbps)** — Efficient streaming and data saver.
  - **Low (48 kbps)** — Minimal bandwidth usage for slow connections.
- **Permanent Setting Storage**: The selected audio quality is stored permanently on the user's device and automatically respected during playback and downloads.

### 2. Seamless Crossfade Playback

- **Equal-Power Crossfade**: Tracks blend into each other using a configurable crossfade window (default 8 seconds), with the outgoing track fading out on a cosine curve and the incoming track fading in on a sine curve.
- **Silent Pre-Buffering**: The next track is fetched and pre-buffered up to 13 seconds before the current track ends, guaranteeing a gapless transition.
- **Dual Audio Pipeline**: Two independent `just_audio` players run in parallel, allowing bitrate and metadata changes to be applied without interrupting the listening experience.
- **Graceful Manual Transitions**: Manual track switches apply a short 350 ms fade-out to prevent audio clicks and pops.

### 3. Sleep Timer (in Settings)

- **Custom Hours and Minutes Input**: Enter exact hours and minutes to automatically stop music.
- **Quick Preset Chips**: Fast one-tap options for `15 min`, `30 min`, and `1 hr`.
- **Live Countdown Badge**: Displays remaining time in real time.
- **Automatic Pause**: Music gracefully pauses when the timer expires.
- **Cancel Anytime**: A single tap cancels or resets the timer.

### 4. Permanent Liked Songs and Favorites

- **Offline Persistence**: Liked songs are permanently saved locally on the device using `shared_preferences`.
- **Instant Heart Toggle**: Tap the heart icon to instantly like or unlike a track.
- **Dedicated Liked Songs Library**:
  - Accessible via the top-right user menu.
  - Features a gradient artwork banner, track count, Play All, and Shuffle controls.
  - Full queue integration with playback loop.

### 5. Offline Songs Library

- **Automatic Device Scan**: Uses Android's MediaStore API through a native method channel to index audio files across internal and external storage.
- **Recursive Fallback Search**: A breadth-first traversal across `/storage/emulated/0`, `/sdcard`, and `/storage/self/primary` for devices where MediaStore does not cover all directories.
- **Manual Import**: Users can pick individual audio files through the system file picker.
- **Voice Note Exclusion**: WhatsApp voice notes and any `.opus` files are filtered out automatically.
- **Looping Offline Playlist**: The offline library plays as an infinitely looping playlist with the same queue and shuffle controls as online content.

### 6. Synchronized Real-Time Lyrics

- **Dual-Source Lyrics Resolution**:
  - LRCLIB is queried first for timestamped synced lyrics.
  - JioSaavn's `lyrics.getLyrics` endpoint serves as a plain-text fallback.
- **Auto-Scrolling Synced Lyrics**: Follows song progress line by line with smooth animations.
- **Interactive Lyric Seeking**: Tap any lyric line to jump playback directly to that timestamp.
- **Smart Scroll-Lock and Sync Pill**: Manual scrolling pauses auto-scroll; a floating "Sync lyrics" button snaps back to the current line in one tap.
- **Fullscreen and Sheet Modes**: Lyrics are available inside the floating bottom sheet or in full-screen mode.

### 7. Dynamic Album Art Color Theming and Fullscreen Player

- **Adaptive Ambient Glow**: Real-time palette extraction from song artwork (`palette_generator`) powers multi-blob animated radial gradients that shift subtly over time.
- **Fullscreen and Mini-Player**:
  - Fullscreen view with vinyl record artwork, time scrubber, and playback controls.
  - Compact persistent bottom player bar for effortless navigation while browsing.

### 8. Global Search and Queue Management

- **Instant Search**: Search across millions of songs, albums, artists, and playlists through JioSaavn's public API.
- **Intelligent Suggestions Queue**: On playing a single song, a batch of 15 related tracks is fetched automatically (album siblings plus primary artist top tracks) so music continues without manual intervention.
- **Two Distinct Playback Modes**:
  - **Suggestions Mode**: Infinite radio-style playback seeded from a chosen track.
  - **Playlist Mode**: Loops through the full playlist, album, or artist discography.
- **Reorderable Up Next**: Drag to reorder upcoming tracks inside the Up Next bottom sheet.

### 9. Five-Band Equalizer with Bass Boost

- **System-Level Effects**: Powered by `AndroidEqualizer` and `AndroidLoudnessEnhancer` in both audio pipelines.
- **Eleven Presets**: Flat, Bass Boost, Rock, Pop, Electronic, Hip Hop, Jazz, Classical, Vocal Boost, Acoustic, and Deep Bass.
- **Per-Band Control**: Adjust each of the five bands independently, with automatic "Custom" preset detection.
- **Bass Boost Slider**: Adds up to 10 dB of low-frequency gain.
- **Full Persistence**: All settings — enabled state, preset, band gains, and bass boost level — are saved across sessions.

### 10. Song Options Menu

- **Available Exclusively on Songs**: Appears on song cards, search results, playlist tracks, and the player.
- **Options Included**:
  - Like or unlike a track.
  - Play the song with contextual queue.
  - Download audio (retrieves the direct high-quality audio URL up to 320 kbps).
  - Open the equalizer.
  - Remove from playlist (when applicable).

### 11. User Onboarding and Settings

- **First-Time Welcome Flow**: A clean onboarding screen captures the user's name, age, and preferred music language (English or Hindi).
- **Profile Management**: Name and age can be updated at any time from the Settings menu.
- **Music Language Preference**: Toggle between English and Hindi feeds with distinct curated content for each.
- **Clean Header Navigation**: A compact user avatar on the top right provides direct access to Liked Songs, Offline Songs, Equalizer, and Settings, with full Android navigation bar clearance.

### 12. Background Audio and System Integration

- **Media Notification**: Full integration with Android's MediaSession through `audio_service`, providing play, pause, skip next, and skip previous controls.
- **Lock Screen Controls**: Album artwork, title, and artist appear on the lock screen with full playback controls.
- **Persistent Buffering State**: The notification remains visible during track transitions rather than being dismissed by the OS.
- **Automatic Resume on Interruption End**: Playback gracefully resumes after calls and other system audio interruptions.

### 13. Theme Support

- **Three Theme Modes**: Dark, Light, and System-following.
- **Per-Track Palette Adaptation**: Every playing track generates a themed gradient based on its artwork, so the interface subtly shifts with the music.
- **Persistent Preference**: The selected theme is stored locally and applied on every launch.

---

## Technology Stack

- **Framework**: [Flutter](https://flutter.dev/) (Dart SDK `^3.12.0`)
- **Audio Engine**: [`just_audio`](https://pub.dev/packages/just_audio)
- **Background Audio**: [`audio_service`](https://pub.dev/packages/audio_service)
- **Media URL Decryption**: [`dart_des`](https://pub.dev/packages/dart_des)
- **Palette Extraction**: [`palette_generator`](https://pub.dev/packages/palette_generator)
- **Icons**: [`phosphor_icons`](https://pub.dev/packages/phosphor_icons)
- **Local Persistence**: [`shared_preferences`](https://pub.dev/packages/shared_preferences)
- **Typography**: [`google_fonts`](https://pub.dev/packages/google_fonts) (Manrope)
- **URL and Download Launching**: [`url_launcher`](https://pub.dev/packages/url_launcher)
- **File Picker**: [`file_picker`](https://pub.dev/packages/file_picker)
- **Networking**: [`http`](https://pub.dev/packages/http)

---

## Architecture Overview

### API and Media URL Decryption

Sonix communicates directly with JioSaavn's public API. No backend server is required.

- **Base endpoint**: `https://www.jiosaavn.com/api.php`
- **Context string**: `ctx=web6dot0&api_version=4&_format=json&_marker=0`

Encrypted media URLs are decrypted on the client using Triple-DES in ECB mode with the key `38346591` and PKCS7 padding. Bitrate variants are produced by replacing the `_NN.mp4` suffix in the decrypted URL.

| Quality | Suffix |
| --- | --- |
| 320 kbps | `_320.mp4` |
| 160 kbps | `_160.mp4` |
| 96 kbps | `_96.mp4` |
| 48 kbps | `_48.mp4` |

### Crossfade Engine

The crossfade engine is implemented in `CrossfadePlayer` using two parallel `AudioPlayer` instances:

- Preload begins 13 seconds before the current track ends (5 seconds crossfade plus 8 seconds prefetch lead).
- At exactly 5 seconds before end of file, an equal-power fade begins.
- Volume is updated every 40 milliseconds (25 updates per second).
- On completion, the active player role is transferred to the incoming player without interruption.

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) installed (version 3.12.0 or newer)
- An Android or iOS device or emulator configured

### Installation and Running

1. **Clone the repository:**
   ```bash
   git clone https://github.com/shikharyadav16/sonix-flutter.git
   cd sonix-flutter
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run on a connected device:**
   ```bash
   flutter run
   ```

### Android Permissions

Add the following permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
                 android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
```

Register the audio service and media button receiver inside the `<application>` element:

```xml
<service
    android:name="com.ryanheise.audioservice.AudioService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService"/>
    </intent-filter>
</service>

<receiver
    android:name="com.ryanheise.audioservice.MediaButtonReceiver"
    android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON"/>
    </intent-filter>
</receiver>
```

Set `android:launchMode="singleTop"` on the `MainActivity` declaration.

---

## Project Structure

```
sonix-flutter/
├── lib/
│   ├── main.dart              # Main entrypoint, UI, state, and playback logic
│   ├── onboarding_screen.dart # First-time user setup screen
│   ├── audio_handler.dart     # audio_service background handler
│   ├── crossfade_player.dart  # Dual AudioPlayer crossfade engine
│   ├── constants.dart         # App constants and input formatters
│   └── user_storage.dart      # Local persistence (profile, likes, history, EQ)
├── pubspec.yaml               # Project configuration and dependencies
└── README.md                  # Documentation
```

---

## Configuration

All tunable values are defined in `constants.dart`.

| Constant | Default | Purpose |
| --- | --- | --- |
| `crossfadeDurationSeconds` | 8 | Length of the crossfade |
| `prefetchLeadSeconds` | 5 | Additional lead time before crossfade begins |
| `minCrossfadeSongDurationSeconds` | 13 | Tracks shorter than this do not crossfade |
| `crossfadeTickIntervalMs` | 40 | Volume curve update interval |
| `manualSwitchFadeOutMs` | 350 | Fade-out duration on manual track switch |
| `suggestionsBatchSize` | 15 | Size of the automatically generated queue |
| `historyLimit` | 10 | Recently played entries retained |
| `minPlayDurationForHistorySeconds` | 10 | Threshold before a track is added to history |
| `defaultSongQuality` | `320kbps` | Initial stream quality |
| `defaultTheme` | `dark` | Startup theme mode |

---

## Troubleshooting

| Issue | Resolution |
| --- | --- |
| Notification does not appear | Confirm that `FOREGROUND_SERVICE_MEDIA_PLAYBACK` is declared and the audio service is registered in the manifest. |
| No audio in release builds | Verify the `INTERNET` permission and confirm cleartext traffic is permitted for legacy JioSaavn CDN hosts. |
| Offline scan returns no results | Grant `READ_MEDIA_AUDIO` on Android 13 or newer, or `READ_EXTERNAL_STORAGE` on older versions, then run Scan Storage. |
| Crossfade is choppy | Increase `prefetchLeadSeconds` in `constants.dart`. |
| Lyrics are not synced | Verify that the device can reach `lrclib.net`. |

---

## Roadmap

- iOS support and CarPlay integration
- Playlist creation and cloud synchronisation
- Gapless playback toggle
- ReplayGain and loudness normalisation
- Chromecast and AirPlay support
- Home screen widget and Wear OS tile

---

## Legal

Sonix is an educational demonstration project and is not affiliated with JioSaavn. It streams from JioSaavn's publicly reachable API endpoints. Users are responsible for complying with their local copyright laws and must not redistribute content obtained through this application.

---

## License

MIT License. See the `LICENSE` file for details.

---

## Acknowledgements

Built using the following open-source projects:

- `just_audio`
- `audio_service`
- `palette_generator`
- `dart_des`
- `phosphor_icons`
- `google_fonts`
- `file_picker`
- `url_launcher`
- LRCLIB
- JioSaavn