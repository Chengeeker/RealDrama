import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'playback_preferences.dart';
import 'video_output_size.dart' show videoDisplaySize;

@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.rate = 1,
    this.volume = 100,
    this.width = 0,
    this.height = 0,
  });

  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final bool completed;
  final double rate;
  final double volume;
  final double width;
  final double height;
}

abstract class PlaybackEngine extends ChangeNotifier {
  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  bool _closed = false;
  int _timelineRevision = 0;
  Duration _timelinePosition = Duration.zero;

  PlaybackSnapshot get state => _snapshot;
  int get timelineRevision => _timelineRevision;
  Duration get timelinePosition => _timelinePosition;

  @protected
  void resetTimeline(Duration position) {
    if (_closed) return;
    _timelinePosition = position;
    _timelineRevision++;
    notifyListeners();
  }

  Stream<String> get errors => _errors.stream;
  Player? get mediaKitPlayer => null;
  VideoController? get mediaKitVideo => null;

  Future<void> open(
    PlaybackPlan plan, {
    required Duration position,
    required bool play,
  });
  Future<void> stop();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Widget buildSurface({required BoxFit fit, required Widget controls});

  Future<void> playOrPause() => state.playing ? pause() : play();

  @protected
  void publish(PlaybackSnapshot value) {
    if (_closed) return;
    final previous = _snapshot;
    if (previous.position == value.position &&
        previous.duration == value.duration &&
        previous.buffer == value.buffer &&
        previous.playing == value.playing &&
        previous.buffering == value.buffering &&
        previous.completed == value.completed &&
        previous.rate == value.rate &&
        previous.volume == value.volume &&
        previous.width == value.width &&
        previous.height == value.height)
      return;
    _snapshot = value;
    notifyListeners();
  }

  @protected
  void publishError(String value) {
    final message = value.trim();
    if (!_closed && message.isNotEmpty && !_errors.isClosed) {
      _errors.add(message);
    }
  }

  @mustCallSuper
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _errors.close();
    super.dispose();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_errors.close());
    super.dispose();
  }
}

class MediaKitPlaybackEngine extends PlaybackEngine {
  MediaKitPlaybackEngine(this.player, this.video) {
    _subscriptions.add(player.stream.error.listen(publishError));
    for (final stream in [
      player.stream.position,
      player.stream.duration,
      player.stream.buffer,
      player.stream.playing,
      player.stream.buffering,
      player.stream.rate,
      player.stream.volume,
      player.stream.completed,
      player.stream.videoParams,
    ]) {
      _subscriptions.add(stream.listen((_) => _sync()));
    }
    _sync();
  }

  final Player player;
  final VideoController? video;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _closing = false;
  PlaybackPreferences _preferences = const PlaybackPreferences();
  Future<void> _configurationTail = Future<void>.value();
  (bool, HardwareDecoder, bool)? _appliedConfiguration;

  Future<void> configure(PlaybackPreferences preferences) {
    _preferences = preferences;
    final next = _configurationTail
        .then((_) async {
          if (_closing) return;
          final native = player.platform;
          if (native is! NativePlayer) return;
          await native.waitForPlayerInitialization;
          await native.waitForVideoControllerInitializationIfAttached;
          if (_closing) return;
          final current = _preferences;
          final configuration = (
            current.hardwareDecoding,
            current.hardwareDecoder,
            current.lowMemory,
          );
          if (configuration == _appliedConfiguration) return;
          final decoder = current.hardwareDecoder;
          final compatible = Platform.isAndroid
              ? decoder != HardwareDecoder.d3d11 &&
                    decoder != HardwareDecoder.d3d11Copy
              : Platform.isWindows
              ? decoder != HardwareDecoder.mediaCodec &&
                    decoder != HardwareDecoder.mediaCodecCopy
              : decoder == HardwareDecoder.automatic ||
                    decoder == HardwareDecoder.copy;
          final hwdec = !current.hardwareDecoding || Platform.isIOS
              ? 'no'
              : compatible
              ? decoder.mpvValue
              : 'auto-safe';
          try {
            await native.setProperty('hwdec', hwdec);
          } catch (_) {
            if (_closing) return;
            await native.setProperty('hwdec', 'no');
          }
          if (_closing) return;
          await native.setProperty(
            'demuxer-max-bytes',
            '${current.bufferBytes}',
          );
          if (_closing) return;
          await native.setProperty(
            'demuxer-max-back-bytes',
            '${current.lowMemory ? 0 : current.bufferBytes}',
          );
          _appliedConfiguration = configuration;
        })
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw const FormatException('播放器初始化超时，请重新打开播放页面');
          },
        );
    _configurationTail = next.catchError((Object _) {});
    return next;
  }

  @override
  Player get mediaKitPlayer => player;

  @override
  VideoController? get mediaKitVideo => video;

  void _sync() {
    final value = player.state;
    final dimensions = videoDisplaySize(value.videoParams);
    publish(
      PlaybackSnapshot(
        position: value.position,
        duration: value.duration,
        buffer: value.buffer,
        playing: value.playing,
        buffering: value.buffering,
        completed: value.completed,
        rate: value.rate,
        volume: value.volume,
        width: dimensions?.width ?? 0,
        height: dimensions?.height ?? 0,
      ),
    );
  }

  @override
  Future<void> open(
    PlaybackPlan plan, {
    required Duration position,
    required bool play,
  }) async {
    await configure(_preferences);
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
        'demuxer-lavf-o',
        [
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          plan.local
              ? 'protocol_whitelist=[file,crypto,data]'
              : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
          if (plan.decryptionKey.isNotEmpty)
            'decryption_key=${plan.decryptionKey}',
        ].join(','),
      );
      await platform.setProperty('network-timeout', '20');
    }
    await player.open(
      Media(
        plan.url,
        httpHeaders: plan.headers,
        start: position > Duration.zero ? position : null,
      ),
      play: plan.audioUrl.isEmpty ? play : false,
    );
    if (plan.audioUrl.isNotEmpty) {
      await player.setAudioTrack(AudioTrack.uri(plan.audioUrl));
      if (play) await player.play();
    }
    resetTimeline(position);
  }

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    resetTimeline(position);
  }

  @override
  Future<void> setRate(double rate) => player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Widget buildSurface({required BoxFit fit, required Widget controls}) =>
      video == null
      ? Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            controls,
          ],
        )
      : Video(
          controller: video!,
          fit: fit,
          alignment: Alignment.center,
          controls: (_) => controls,
        );

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _configurationTail;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    await super.close();
  }
}
