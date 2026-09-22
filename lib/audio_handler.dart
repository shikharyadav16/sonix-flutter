import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'crossfade_player.dart';

/// Background audio handler integrating [CrossfadePlayer] with Android's MediaSession
/// and notification controls via [audio_service].
class SonixAudioHandler extends BaseAudioHandler with SeekHandler {
  SonixAudioHandler({CrossfadePlayer? player})
      : player = player ?? CrossfadePlayer() {
    _initStreams();
  }

  final CrossfadePlayer player;

  VoidCallback? onSkipNext;
  VoidCallback? onSkipPrevious;

  void _initStreams() {
    // Sync position updates to notification/lock screen
    player.positionStream.listen((pos) {
      _broadcastState();
    });

    // Sync play/pause state
    player.playingStream.listen((isPlaying) {
      _broadcastState();
    });

    // Sync processing state (buffering, ready, etc.)
    player.processingStateStream.listen((state) {
      _broadcastState();
    });

    // Sync duration updates
    player.durationStream.listen((dur) {
      if (mediaItem.value != null && dur != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: dur));
      }
    });
  }

  /// Updates the current track metadata in the system notification and lock screen.
  void setSongItem({
    required String id,
    required String title,
    required String artist,
    String album = '',
    String artwork = '',
    Duration? duration,
  }) {
    mediaItem.add(MediaItem(
      id: id,
      album: album.isNotEmpty ? album : 'Sonix',
      title: title,
      artist: artist,
      artUri: artwork.isNotEmpty ? Uri.tryParse(artwork) : null,
      duration: duration,
    ));
    _broadcastState();
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
    _broadcastState();
  }

  void _broadcastState() {
    final isPlaying = player.playing;
    final proc = player.processingState;

    AudioProcessingState audioProcState;
    switch (proc) {
      case ProcessingState.idle:
        audioProcState = AudioProcessingState.idle;
        break;
      case ProcessingState.loading:
        audioProcState = AudioProcessingState.loading;
        break;
      case ProcessingState.buffering:
        audioProcState = AudioProcessingState.buffering;
        break;
      case ProcessingState.ready:
        audioProcState = AudioProcessingState.ready;
        break;
      case ProcessingState.completed:
        audioProcState = AudioProcessingState.completed;
        break;
    }

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: audioProcState,
      playing: isPlaying,
      updatePosition: player.position,
      bufferedPosition: player.position,
      speed: 1.0,
    ));
  }

  @override
  Future<void> play() async => player.play();

  @override
  Future<void> pause() async => player.pause();

  @override
  Future<void> stop() async => player.stop();

  @override
  Future<void> seek(Duration position) async => player.seek(position);

  @override
  Future<void> skipToNext() async {
    onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onSkipPrevious?.call();
  }
}
