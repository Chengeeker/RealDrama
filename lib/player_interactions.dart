import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'playback_engine.dart';
import 'widgets.dart';

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.holdSpeed = 2,
    this.onHoldStart,
    this.onSeek,
    this.onBrightness,
  }) {
    player.addListener(_playerChanged);
  }

  final PlaybackEngine player;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final double holdSpeed;
  final VoidCallback? onHoldStart;
  final Future<void> Function(Duration)? onSeek;
  final Future<double> Function(double delta)? onBrightness;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  double? _swipeVolume;
  double _swipeHeight = 1, _swipeWidth = 1;
  bool? _brightnessGesture;
  bool _swipeEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  bool _speedFeedback = false;
  DateTime _ignoreTapUntil = DateTime(2000);

  String get feedback => _feedback;
  bool get speedFeedback => _speedFeedback;
  bool get boosting => _boosting;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;
  String get _holdSpeedHint => '${holdSpeed.toStringAsFixed(0)} 倍速 · 松开恢复';

  void _playerChanged() {
    if (!player.state.playing) cancel();
  }

  void hint(String message, {bool persistent = false, bool speed = false}) {
    if (_disposed) return;
    _hintTimer?.cancel();
    if (_feedback != message || _speedFeedback != speed) {
      _feedback = message;
      _speedFeedback = speed;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint(
          _boosting ? _holdSpeedHint : '',
          persistent: true,
          speed: _boosting,
        );
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      onHoldStart?.call();
      unawaited(_setRate(holdSpeed));
      hint(_holdSpeedHint, persistent: true, speed: true);
    });
  }

  void _endHold({bool tap = false, bool silent = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      if (!silent) hint('');
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel() {
    if (_disposed) return;
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _swipeVolume = null;
    _brightnessGesture = null;
    _endHold(silent: true);
    hint('');
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    required double height,
    required double width,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel();
      return;
    }
    if (!available() || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    _swipeVolume = null;
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _swipeHeight = math.max(1, height);
    _swipeWidth = math.max(1, width);
    _brightnessGesture = null;
    _moved = _held = false;
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final delta = event.localPosition - _origin!;
    if (delta.distance > 12) {
      _moved = true;
      // Before the hold activates, movement means this pointer is a swipe.
      // Once boosted, keep the speed until pointerUp so small finger drift
      // does not cancel the user's hold gesture.
      if (!_boosting) _endHold();
      if (_swipeEnabled &&
          delta.dy.abs() > delta.dx.abs() * 1.2 &&
          delta.dy.abs() >= 12) {
        _brightnessGesture ??= _origin!.dx < _swipeWidth / 2;
        if (_brightnessGesture!) {
          unawaited(_adjustBrightness(-event.delta.dy / _swipeHeight * 1.2));
        } else {
          _swipeVolume ??= player.state.volume;
          changeVolume(-event.delta.dy / _swipeHeight * 100);
        }
      }
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _endHold();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel();
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void seek(int seconds) {
    if (!available() || player.state.duration <= Duration.zero) return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('${seconds > 0 ? '快进至' : '后退至'} ${formatPosition(target / 1000)}');
  }

  Future<void> _adjustBrightness(double delta) async {
    final adjust = onBrightness;
    if (!available() || adjust == null) return;
    try {
      final brightness = await adjust(delta);
      hint('亮度 ${(brightness * 100).round()}%');
    } catch (_) {
      hint('当前设备不支持手势调节亮度');
    }
  }

  void changeVolume(double delta) {
    if (!available()) return;
    final current = _brightnessGesture == false
        ? _swipeVolume ?? player.state.volume
        : player.state.volume;
    final volume = (current + delta).clamp(0.0, 100.0);
    if (_brightnessGesture == false) _swipeVolume = volume;
    unawaited(player.setVolume(volume));
    if (volume > 0) _unmutedVolume = volume;
    hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
  }

  void toggleMute() {
    if (!available()) return;
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    unawaited(player.setVolume(target));
    hint(target == 0 ? '已静音' : '音量 ${target.round()}%');
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    player.removeListener(_playerChanged);
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _pointers.clear();
    super.dispose();
  }
}
