import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'constants.dart';

/// Manages seamless crossfading between audio tracks using dual [AudioPlayer] instances.
class CrossfadePlayer {
  CrossfadePlayer(
      {this.crossfadeSeconds = AppConstants.crossfadeDurationSeconds}) {
    _activePlayer = _playerA;
    _initPlayerListeners(_playerA);
    _initPlayerListeners(_playerB);
  }

  final AudioPlayer _playerA = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );
  final AudioPlayer _playerB = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );
  late AudioPlayer _activePlayer;
  AudioPlayer? _fadingInPlayer;

  /// Configurable crossfade duration in seconds (0 = disabled, e.g. 3, 4, 5).
  int crossfadeSeconds;

  /// Callback to resolve and pre-buffer the upcoming track.
  VoidCallback? onPrepareNextTrack;

  /// Callback when the current track enters its final crossfade window.
  VoidCallback? onAutoCrossfadeTriggered;

  bool _isCrossfading = false;
  bool _preparedNext = false;
  AudioSource? _preparedSource;
  String? _preparedUri;
  bool _crossfadeTriggeredForCurrent = false;
  Timer? _fadeTimer;
  Stopwatch? _fadeStopwatch;
  VoidCallback? _onCrossfadeCompletedCallback;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();

  final List<StreamSubscription> _subscriptions = [];

  AudioPlayer get activePlayer => _activePlayer;
  AudioPlayer get _inactivePlayer =>
      _activePlayer == _playerA ? _playerB : _playerA;

  bool get isCrossfading => _isCrossfading;
  bool get playing =>
      _activePlayer.playing || (_fadingInPlayer?.playing ?? false);
  Duration get position => _activePlayer.position;
  Duration? get duration => _activePlayer.duration;
  ProcessingState get processingState => _activePlayer.processingState;

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<ProcessingState> get processingStateStream =>
      _processingStateController.stream;

  void _initPlayerListeners(AudioPlayer player) {
    _subscriptions.add(
      player.positionStream.listen((pos) {
        if (_activePlayer == player) {
          _positionController.add(pos);
          _checkCrossfadeTriggers(pos, player.duration);
        }
      }),
    );

    _subscriptions.add(
      player.durationStream.listen((dur) {
        if (_activePlayer == player) {
          _durationController.add(dur);
        }
      }),
    );

    _subscriptions.add(
      player.playingStream.listen((isPlaying) {
        if (_activePlayer == player) {
          _playingController.add(isPlaying);
        }
      }),
    );

    _subscriptions.add(
      player.processingStateStream.listen((state) {
        if (_activePlayer == player) {
          if (_isCrossfading && state == ProcessingState.completed) {
            // Outgoing track reached EOF before timer completed.
            // Finish crossfade handover immediately.
            _completeCrossfadeNow();
            return;
          }
          _processingStateController.add(state);
        }
      }),
    );
  }

  void _checkCrossfadeTriggers(Duration pos, Duration? dur) {
    if (dur == null ||
        dur.inSeconds <= AppConstants.minCrossfadeSongDurationSeconds) {
      return;
    }
    if (!_activePlayer.playing) return;

    final remainingMs = dur.inMilliseconds - pos.inMilliseconds;
    if (remainingMs <= 0) {
      if (!_isCrossfading && _fadingInPlayer == null) {
        _processingStateController.add(ProcessingState.completed);
      }
      return;
    }

    if (crossfadeSeconds > 0) {
      // 1. Preload trigger: prefetchLeadSeconds before crossfade threshold (e.g. 13s before song end)
      final prefetchWindowMs =
          (crossfadeSeconds + AppConstants.prefetchLeadSeconds) * 1000;
      if (remainingMs <= prefetchWindowMs && !_preparedNext) {
        _preparedNext = true;
        onPrepareNextTrack?.call();
      }

      // 2. Crossfade trigger: exactly crossfadeSeconds before track end (5s before song end)
      // Fades over crossfadeSeconds: outgoing 1.0 -> 0.0, incoming 0.0 -> 1.0.
      final crossfadeWindowMs = crossfadeSeconds * 1000;
      if (remainingMs <= crossfadeWindowMs && !_crossfadeTriggeredForCurrent) {
        _crossfadeTriggeredForCurrent = true;
        onAutoCrossfadeTriggered?.call();
      }
    }
  }

  /// Pre-buffers the next track on the inactive player at 0 volume so it can play instantly.
  Future<void> prepareNext(AudioSource source, {String? uri}) async {
    if (_isCrossfading) return;
    try {
      _preparedUri = uri;
      _preparedSource = source;
      await _inactivePlayer.setVolume(0.0);
      await _inactivePlayer.setAudioSource(source, preload: true);
    } catch (_) {
      _preparedSource = null;
      _preparedUri = null;
    }
  }

  /// Starts an equal-power crossfade transition into the next track.
  /// Both tracks overlap while outgoing fades out (1.0 -> 0.0)
  /// and incoming fades in (0.0 -> 1.0).
  ///
  /// Note: The outgoing player remains [_activePlayer] during the transition
  /// so that the UI continues displaying the current track's progress until completion.
  Future<void> startCrossfade({
    required AudioSource nextSource,
    String? nextUri,
    Duration? customDuration,
    VoidCallback? onCompleted,
  }) async {
    _cancelFadeTimer();

    final fadeMs = (customDuration ??
            Duration(seconds: crossfadeSeconds > 0 ? crossfadeSeconds : 5))
        .inMilliseconds;
    final incoming = _inactivePlayer;
    final outgoing = _activePlayer;
    _onCrossfadeCompletedCallback = onCompleted;

    try {
      await incoming.setVolume(0.0);
      // Use pre-buffered source if it matches, avoiding redundant re-buffering
      final isAlreadyPrepared =
          (_preparedUri != null && nextUri != null && _preparedUri == nextUri) ||
          (_preparedSource == nextSource);
      if (!isAlreadyPrepared) {
        _preparedSource = nextSource;
        _preparedUri = nextUri;
        await incoming.setAudioSource(nextSource, preload: true);
      }

      // If outgoing stopped/paused while loading:
      if (!outgoing.playing) {
        _fadingInPlayer = incoming;
        _isCrossfading = true;
        _preparedNext = false;
        _crossfadeTriggeredForCurrent = false;
        await incoming.pause();
        _playingController.add(false);
        return;
      }

      // Start incoming track non-blocking
      unawaited(incoming.play());

      _fadingInPlayer = incoming;
      _isCrossfading = true;
      _preparedNext = false;
      _crossfadeTriggeredForCurrent = false;

      _fadeStopwatch = Stopwatch()..start();
      const tickDuration =
          Duration(milliseconds: AppConstants.crossfadeTickIntervalMs);

      _fadeTimer = Timer.periodic(tickDuration, (timer) {
        if (_fadeStopwatch == null || !_fadeStopwatch!.isRunning) return;
        final elapsed = _fadeStopwatch!.elapsedMilliseconds;
        final t = (elapsed / fadeMs).clamp(0.0, 1.0);

        // Equal-power crossfade curve: cos(t * pi/2) for out, sin(t * pi/2) for in
        final volOut = math.cos(t * math.pi / 2).clamp(0.0, 1.0);
        final volIn = math.sin(t * math.pi / 2).clamp(0.0, 1.0);

        outgoing.setVolume(volOut);
        incoming.setVolume(volIn);

        if (t >= 1.0) {
          _completeCrossfadeNow();
        }
      });
    } catch (_) {
      _cancelFadeTimer();
      // On failure, restore current song volume and keep playing
      outgoing.setVolume(1.0);
      try {
        incoming.stop();
        incoming.setVolume(1.0);
      } catch (_) {}
      _fadingInPlayer = null;
      _isCrossfading = false;
      _onCrossfadeCompletedCallback = null;
    }
  }

  void _completeCrossfadeNow() {
    _cancelFadeTimer();
    final outgoing = _activePlayer;
    final incoming = _fadingInPlayer;
    if (incoming == null) return;

    outgoing.stop();
    outgoing.setVolume(1.0);
    incoming.setVolume(1.0);

    // Hand over active player role to the incoming player
    _activePlayer = incoming;
    _fadingInPlayer = null;
    _isCrossfading = false;
    _preparedNext = false;
    _crossfadeTriggeredForCurrent = false;
    _preparedSource = null;
    _preparedUri = null;

    // Broadcast the new active track's state
    _positionController.add(incoming.position);
    _durationController.add(incoming.duration);
    _playingController.add(incoming.playing);
    _processingStateController.add(incoming.processingState);

    final cb = _onCrossfadeCompletedCallback;
    _onCrossfadeCompletedCallback = null;
    cb?.call();
  }

  /// Directly plays a track without overlap, or with a brief graceful fade-out of the current track.
  Future<void> playDirect(AudioSource source,
      {bool fadeCurrentOut = false}) async {
    _cancelFadeTimer();
    await Future.wait([
      _playerA.stop(),
      _playerB.stop(),
    ]);
    await Future.wait([
      _playerA.setVolume(1.0),
      _playerB.setVolume(1.0),
    ]);
    _fadingInPlayer = null;
    _isCrossfading = false;
    _preparedNext = false;
    _crossfadeTriggeredForCurrent = false;
    _preparedSource = null;
    _preparedUri = null;
    _onCrossfadeCompletedCallback = null;

    if (fadeCurrentOut && _activePlayer.playing) {
      // Quick graceful fade-out so manual jumps don't create harsh audio clicks
      try {
        final startMs = DateTime.now().millisecondsSinceEpoch;
        const fadeMs = AppConstants.manualSwitchFadeOutMs;
        final outgoing = _activePlayer;
        while (DateTime.now().millisecondsSinceEpoch - startMs < fadeMs) {
          final t = (DateTime.now().millisecondsSinceEpoch - startMs) / fadeMs;
          outgoing.setVolume((1.0 - t).clamp(0.0, 1.0));
          await Future.delayed(const Duration(milliseconds: 30));
        }
      } catch (_) {}
    }

    await _activePlayer.stop();
    await _activePlayer.setVolume(1.0);
    await _activePlayer.setAudioSource(source);
    unawaited(_activePlayer.play());

    _positionController.add(_activePlayer.position);
    _durationController.add(_activePlayer.duration);
    _playingController.add(true);
    _processingStateController.add(_activePlayer.processingState);
  }

  Future<void> setAudioSource(AudioSource source) async {
    _cancelFadeTimer();
    await Future.wait([
      _playerA.stop(),
      _playerB.stop(),
    ]);
    await Future.wait([
      _playerA.setVolume(1.0),
      _playerB.setVolume(1.0),
    ]);
    _fadingInPlayer = null;
    _isCrossfading = false;
    _preparedNext = false;
    _crossfadeTriggeredForCurrent = false;
    _preparedSource = null;
    _preparedUri = null;
    _onCrossfadeCompletedCallback = null;
    await _activePlayer.setVolume(1.0);
    await _activePlayer.setAudioSource(source);
  }

  Future<void> play() async {
    if (_fadingInPlayer != null && _isCrossfading) {
      _fadeStopwatch?.start();
      unawaited(_fadingInPlayer!.play());
    }
    unawaited(_activePlayer.play());
    _playingController.add(true);
  }

  /// Pauses BOTH players and stops the crossfade stopwatch.
  /// Guarantees that no audio will play from either internal player instance.
  Future<void> pause() async {
    _fadeStopwatch?.stop();
    await Future.wait([
      _playerA.pause(),
      _playerB.pause(),
    ]);
    _playingController.add(false);
  }

  Future<void> stop() async {
    _cancelFadeTimer();
    await Future.wait([
      _playerA.stop(),
      _playerB.stop(),
    ]);
    await Future.wait([
      _playerA.setVolume(1.0),
      _playerB.setVolume(1.0),
    ]);
    _fadingInPlayer = null;
    _isCrossfading = false;
    _preparedNext = false;
    _crossfadeTriggeredForCurrent = false;
    _preparedSource = null;
    _preparedUri = null;
    _onCrossfadeCompletedCallback = null;
    _playingController.add(false);
    _positionController.add(Duration.zero);
    _processingStateController.add(ProcessingState.idle);
  }

  Future<void> seek(Duration position) async {
    if (_isCrossfading && _fadingInPlayer != null) {
      // Seek cancels crossfade immediately to avoid audio confusion
      _cancelFadeTimer();
      _fadingInPlayer!.stop();
      _fadingInPlayer!.setVolume(1.0);
      _fadingInPlayer = null;
      _isCrossfading = false;
      _onCrossfadeCompletedCallback = null;
      await _activePlayer.setVolume(1.0);
    }
    final dur = _activePlayer.duration;
    final crossfadeWindowMs = crossfadeSeconds * 1000;
    if (dur != null &&
        (dur.inMilliseconds - position.inMilliseconds) <= crossfadeWindowMs) {
      // User sought directly into the final crossfade window.
      // Play out normally to real track completion rather than triggering crossfade.
      _crossfadeTriggeredForCurrent = true;
    } else {
      _crossfadeTriggeredForCurrent = false;
    }
    _preparedNext = false;
    await _activePlayer.seek(position);
  }

  void _cancelFadeTimer() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeStopwatch?.stop();
    _fadeStopwatch = null;
  }

  Future<void> dispose() async {
    _cancelFadeTimer();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _processingStateController.close();
    await _playerA.dispose();
    await _playerB.dispose();
  }
}
