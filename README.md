# Sonix — Modern Music Player Mobile App

Sonix is a premium, feature-rich music player application built with Flutter. Inspired by modern streaming experiences like Apple Music and Spotify, Sonix blends fluid animations, dynamic ambient gradient lighting extracted from album artwork, and real-time synchronized lyrics into an ultra-sleek, dark-themed audio experience.

---

## Key Features & Functionalities

### 1. High-Fidelity Audio Streaming & Quality Settings
- **Selectable Bitrates**: Choose your preferred streaming and download quality:
  - **Very High (320 kbps)** — Highest audio fidelity and rich bass.
  - **High (160 kbps)** — Balanced quality and data usage.
  - **Medium (96 kbps)** — Efficient streaming / Data saver.
  - **Low (48 kbps)** — Minimal bandwidth usage for slow connections.
- **Permanent Setting Storage**: Selected audio quality is stored permanently on the user's device and automatically respected during playback and downloads.

### 2. Sleep Timer (in Settings)
- **Custom Hours & Minutes Input**: Enter exact hours and minutes to automatically stop music.
- **Quick Preset Chips**: Fast 1-tap options for `15 min`, `30 min`, `45 min`, `1 hr`, and `2 hrs`.
- **Live Countdown Badge**: Displays remaining time (`Xh Ym Zs left`) in real time.
- **Automatic Pause**: Music gracefully pauses when time expires.
- **Cancel Anytime**: Easy 1-tap option to cancel or reset the timer.

### 3. Permanent Liked Songs & Favorites
- **Offline Persistence**: Liked songs are permanently saved locally on the device using `shared_preferences`.
- **Instant Heart Toggle**: Tap the heart icon to instantly like (filled red heart) or unlike (unfilled heart) with zero disruptive notifications.
- **Dedicated Liked Songs Library**:
  - Accessible via the top-right user menu.
  - Features gradient artwork banner, track count, **"Play All"**, and **"Shuffle"** controls.
  - Full queue integration for playback.

### 4. Synchronized Real-Time Lyrics
- **Auto-Scrolling Synced Lyrics**: Follows song progress line-by-line with smooth animations.
- **Interactive Lyric Seeking**: Tap any lyric line to jump playback directly to that timestamp.
- **Smart Scroll-Lock & Sync Pill**: When you manually scroll through lyrics, auto-scrolling pauses. A floating **"Sync lyrics"** button allows 1-tap snapping back to current line.
- **Fullscreen & Sheet Modes**: View lyrics inside the floating bottom sheet or in full-screen mode.

### 5. Dynamic Album Art Color Theming & Fullscreen Player
- **Adaptive Ambient Glow**: Real-time palette extraction from song artwork (`palette_generator`) powering multi-blob animated radial gradients.
- **Fullscreen & Mini-Player**:
  - Fullscreen view with vinyl record artwork, time scrubber, and playback controls.
  - Compact persistent bottom player bar for effortless navigation while browsing.

### 6. Global Search & Queue Management
- **Instant Search**: Search across millions of songs, albums, and playlists via the ListenFree API.
- **Smart Continuous Queue**: Reaching the last song in the queue automatically fetches recommendations to keep the music playing continuously.

### 7. Song Options Menu (3-Dots)
- **Available Exclusively on Songs**: Appears on song cards, search results, playlist tracks, and the player (strictly excluded from playlists).
- **Options Included**:
  - **Like / Unlike** track toggle.
  - **Play Song** with contextual playlist/search queue.
  - **Download Audio** (retrieves direct high-quality audio URL up to 320kbps).

### 8. User Onboarding & Settings
- **First-Time Welcome Flow**: Clean onboarding screen to capture user Name and Age.
- **Profile Management**: Update your name and age at any time from the Settings menu.
- **Clean Header Navigation**: Compact user avatar on top right opens direct access to Liked Songs and Settings with full Android navigation bar clearance.

---

## Technology Stack

- **Framework**: [Flutter](https://flutter.dev/) (Dart SDK `^3.12.0`)
- **Audio Engine**: [`just_audio`](https://pub.dev/packages/just_audio)
- **Palette Extraction**: [`palette_generator`](https://pub.dev/packages/palette_generator)
- **Icons**: [`phosphor_icons`](https://pub.dev/packages/phosphor_icons)
- **Local Persistence**: [`shared_preferences`](https://pub.dev/packages/shared_preferences)
- **Typography**: [`google_fonts`](https://pub.dev/packages/google_fonts) (Inter)
- **URL & Download Launching**: [`url_launcher`](https://pub.dev/packages/url_launcher)
- **Networking**: [`http`](https://pub.dev/packages/http)

---

## Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) installed (version >= 3.12.0)
- An Android or iOS device / emulator configured

### Installation & Running

1. **Clone the repository:**
   ```bash
   git clone https://github.com/shikharyadav16/sonix-flutter.git
   cd sonix-flutter/song_player_mobile
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run on connected device:**
   ```bash
   flutter run
   ```

---

## Project Structure

```
song_player_mobile/
├── lib/
│   ├── main.dart              # Main entrypoint, audio engine, views & settings
│   ├── onboarding_screen.dart # First-time user setup screen
│   └── user_storage.dart      # Local persistence (Profile, Likes, Audio Quality)
├── pubspec.yaml               # Project configuration and dependencies
└── README.md                  # Documentation
```
