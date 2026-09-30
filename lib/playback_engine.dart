import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
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

  PlaybackSnapshot get state => _snapshot;
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
      play: play,
    );
  }

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

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
      : Video(controller: video!, fit: fit, controls: (_) => controls);

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    await super.close();
  }
}
