import 'video_danmaku.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_diagnostics.dart';
import 'app_haptics.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'core_bridge.dart';
import 'download_picker.dart';
import 'downloads_screen.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_engine.dart';
import 'playback_loader.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_preferences.dart';
import 'player_controls.dart';
import 'player_interactions.dart';
import 'player_menu.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'lan_controller.dart';
import 'douyin_creator_screen.dart';
import 'playback_launch_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.initialPlaybackPlan,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
    this.immersiveFeed = false,
    this.feedEpisode,
    this.feedActive,
    this.feedPageActive,
    this.hideFeedOverlays = false,
    this.onFeedBack,
    this.onFeedDoubleTap,
    this.onFeedPlaybackStarted,
    this.onFeedPlaybackFailed,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final PlaybackPlan? initialPlaybackPlan;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  final bool immersiveFeed;
  final ValueNotifier<int>? feedEpisode;
  final ValueListenable<bool>? feedActive;
  final ValueListenable<bool>? feedPageActive;
  final bool hideFeedOverlays;
  final VoidCallback? onFeedBack;
  final VoidCallback? onFeedDoubleTap;
  final VoidCallback? onFeedPlaybackStarted;
  final VoidCallback? onFeedPlaybackFailed;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final PlaybackEngine _playback;
  late PlaybackPreferences _enginePreferences;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool _creatorWorkOpening = false;
  bool _autoAdvance = true;
  bool? _systemUiImmersive;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _showControlsOnPlaybackReady = true;
  bool _pendingError = false;
  bool _lastCompleted = false;
  bool _feedMediaStarted = false;
  bool _feedFailureReported = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _lastVideoWidth = 0;
  double _lastVideoHeight = 0;
  double _resumePosition = 0;
  bool _changingFullscreen = false;
  bool _television = false;
  AppOrientationController? _orientationController;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  PlaybackPreferences get _preferences =>
      widget.store.playbackPreferences.copyWith(
        speed: _speed,
        quality: _requestedQuality,
        homeQuality: widget.store.playbackPreferences.homeQuality,
        autoAdvance: _autoAdvance,
        preload: _preloadEnabled,
      );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? '自动'
      : '${_requestedQuality}P';
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _playback.state.position.inMilliseconds > 0
      ? _playback.state.position.inMilliseconds / 1000
      : _resumePosition;
  bool get _feedPageIsActive =>
      (widget.feedActive?.value ?? true) &&
      (widget.feedPageActive?.value ?? true);
  bool? _lastFeedCanPop;
  static const _deviceChannel = MethodChannel('duanju/device');

  void _syncFeedBackScope() {
    if (!widget.immersiveFeed) return;
    final canPop = !_feedPageIsActive;
    if (_lastFeedCanPop == canPop) return;
    _lastFeedCanPop = canPop;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VideoDanmaku.enabled.addListener(_danmakuChanged);
    _index = widget.initialIndex;
    if ({'bilibili', 'bilibili-live'}.contains(widget.detail.drama.source)) {
      _aspectRatio = 16 / 9;
    }
    if (widget.immersiveFeed) _lastFeedCanPop = !_feedPageIsActive;
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = widget.immersiveFeed
        ? preferences.homeQuality
        : preferences.quality;
    _autoAdvance = true;
    _preloadEnabled = !widget.immersiveFeed;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    widget.store.addListener(_accessChanged);
    widget.feedEpisode?.addListener(_feedEpisodeChanged);
    widget.feedActive?.addListener(_feedVisibilityChanged);
    widget.feedPageActive?.addListener(_feedVisibilityChanged);
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _foreground =
        _lifecycleState == AppLifecycleState.resumed &&
        (!widget.immersiveFeed || widget.feedActive?.value != false) &&
        (!widget.immersiveFeed || widget.feedPageActive?.value != false);
    final injectedPlayer = widget.playerFactory?.call();
    if (injectedPlayer != null) {
      _playback = MediaKitPlaybackEngine(
        injectedPlayer,
        widget.videoBuilder == null
            ? VideoController(
                injectedPlayer,
                configuration: VideoControllerConfiguration(
                  enableHardwareAcceleration:
                      preferences.hardwareDecoding && !Platform.isIOS,
                  hwdec: preferences.hardwareDecoding && !Platform.isIOS
                      ? null
                      : 'no',
                ),
              )
            : null,
      );
    } else {
      if (defaultTargetPlatform == TargetPlatform.android) {
        MediaKit.ensureInitialized();
      }
      final player = Player(
        configuration: PlayerConfiguration(
          bufferSize: preferences.bufferBytes,
          logLevel: MPVLogLevel.error,
        ),
      );
      _playback = MediaKitPlaybackEngine(
        player,
        widget.videoBuilder == null
            ? VideoController(
                player,
                configuration: VideoControllerConfiguration(
                  enableHardwareAcceleration:
                      preferences.hardwareDecoding && !Platform.isIOS,
                  hwdec: preferences.hardwareDecoding && !Platform.isIOS
                      ? null
                      : 'no',
                ),
              )
            : null,
      );
    }
    _enginePreferences = preferences;
    unawaited(
      (_playback as MediaKitPlaybackEngine).configure(preferences).catchError((
        Object _,
      ) {
        if (!_closed && mounted) _notice('解码或缓存设置未能应用，请重新打开播放器');
      }),
    );
    _interactions = PlayerInteractions(
      player: _playback,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onBrightness: (delta) async =>
          await _deviceChannel.invokeMethod<double>('adjustScreenBrightness', {
            'delta': delta,
          }) ??
          .5,
      onFullscreen: _toggleFullscreen,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
      holdSpeed:
          SourceSite.byId(widget.detail.drama.source).kind == 'live' ||
              widget.detail.drama.source == 'douyin-live'
          ? 1
          : 2,
      onHoldStart: widget.immersiveFeed ? AppHaptics.light : null,
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _playback.addListener(_playbackChanged);
    _subscriptions.add(
      _playback.errors.listen((error) {
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          AppDiagnostics.record('playback_error', {
            'source': widget.detail.drama.source,
            'code': AppDiagnostics.playbackCode(error),
            'stage': widget.immersiveFeed ? 'feed' : 'detail',
          });
          _queueRecovery();
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _playback.state.position,
            playing: _playIntent && _openedIndex == _index,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null) {
        unawaited(widget.repository.release(handoff.plan.session));
      } else if (widget.initialPlaybackPlan != null) {
        unawaited(
          widget.repository.release(widget.initialPlaybackPlan!.session),
        );
      }
      _loading = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan ?? widget.initialPlaybackPlan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        _scheduleSystemUi();
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
  }

  void _feedEpisodeChanged() {
    final index = widget.feedEpisode?.value;
    if (widget.immersiveFeed &&
        index != null &&
        index != _index &&
        index >= 0 &&
        index < widget.detail.episodes.length) {
      unawaited(_play(index));
    }
  }

  void _playbackChanged() {
    if (_closed) return;
    final state = _playback.state;
    if (_openedIndex == _index && state.position > Duration.zero) {
      _resumePosition = state.position.inMilliseconds / 1000;
      _reportFeedPlaybackStarted();
    }
    if (state.completed && !_lastCompleted) {
      _lastCompleted = true;
      _handlePlaybackCompleted();
    } else if (!state.completed) {
      _lastCompleted = false;
    }
    if (state.width > 0 && state.height > 0) {
      final width = state.width;
      final height = state.height;
      if ((_lastVideoWidth - width).abs() > .5 ||
          (_lastVideoHeight - height).abs() > .5) {
        _lastVideoWidth = width;
        _lastVideoHeight = height;
        if (mounted) {
          setState(() => _aspectRatio = width / height);
          _scheduleSystemUi();
        }
      }
    }
    _syncPreload();
    _acknowledgeHandoff();
  }

  void _handlePlaybackCompleted() {
    if (_loading || !_acceptErrors || _error != null) return;
    final state = _playback.state;
    final duration = state.duration;
    if (duration <= Duration.zero ||
        state.position < duration - const Duration(seconds: 2)) {
      _queueRecovery();
    } else if (_autoAdvance &&
        _foreground &&
        !_panelOpen &&
        _index + 1 < widget.detail.episodes.length) {
      unawaited(_play(_index + 1, showControlsOnReady: false));
    } else {
      _playIntent = false;
      _interactions.cancel();
      unawaited(_playback.pause());
      unawaited(_saveProgress(flush: true));
    }
  }

  void _feedVisibilityChanged() {
    if (!widget.immersiveFeed) return;
    _syncFeedBackScope();
    final feedVisible =
        (widget.feedActive?.value ?? true) &&
        (widget.feedPageActive?.value ?? true) &&
        _foreground;
    final quality = widget.store.playbackPreferences.homeQuality;
    if (feedVisible && quality != _requestedQuality && !_loading) {
      unawaited(_retry(quality: quality));
    }
    _applyLifecycleVisibility();
  }

  void _accessChanged() {
    if (!_closed &&
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked) {
      final preferences = widget.store.playbackPreferences;
      final previous = _enginePreferences;
      _enginePreferences = preferences;
      if (preferences.hardwareDecoding != previous.hardwareDecoding ||
          preferences.hardwareDecoder != previous.hardwareDecoder ||
          preferences.lowMemory != previous.lowMemory) {
        unawaited(
          (_playback as MediaKitPlaybackEngine)
              .configure(preferences)
              .catchError((Object _) {
                if (!_closed && mounted) _notice('解码或缓存设置未能应用，请重新打开播放器');
              }),
        );
        _syncPreload();
      }
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_playback.pause());
    }
  }

  void _applyLifecycleVisibility() {
    final visible =
        _lifecycleState == AppLifecycleState.resumed &&
        (!widget.immersiveFeed || widget.feedActive?.value != false) &&
        (!widget.immersiveFeed || widget.feedPageActive?.value != false);
    _foreground = visible;
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    if (!visible) {
      final returningFromFeedDetail =
          widget.immersiveFeed &&
          widget.feedActive?.value == false &&
          _lifecycleState == AppLifecycleState.resumed;
      final returningFromFeedPage =
          widget.immersiveFeed &&
          widget.feedActive?.value != false &&
          widget.feedPageActive?.value == false &&
          _lifecycleState == AppLifecycleState.resumed;
      if (!returningFromFeedDetail && !returningFromFeedPage) {
        _playIntent = false;
      }
      unawaited(_playback.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
    if (visible &&
        _playIntent &&
        _openedIndex == _index &&
        !_playback.state.playing) {
      unawaited(_playback.play());
    }
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final state = _playback.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        state.width <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20) {
      return;
    }
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed ||
          generation != _generation ||
          widget.store.profileEpoch != _profileEpoch) {
        return;
      }
      _playIntent = false;
      _interactions.cancel();
      _health.reset();
      await _playback.pause();
      await _saveProgress(flush: true);
    });
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        widget.store.playbackPreferences.lowMemory ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _playback.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000) ||
        state.buffer.inMilliseconds - position < 5000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feedActive != widget.feedActive) {
      oldWidget.feedActive?.removeListener(_feedVisibilityChanged);
      widget.feedActive?.addListener(_feedVisibilityChanged);
      _applyLifecycleVisibility();
    }
    if (oldWidget.feedPageActive != widget.feedPageActive) {
      oldWidget.feedPageActive?.removeListener(_feedVisibilityChanged);
      widget.feedPageActive?.addListener(_feedVisibilityChanged);
      _applyLifecycleVisibility();
    }
    _lastFeedCanPop = widget.immersiveFeed ? !_feedPageIsActive : null;
    if (oldWidget.immersiveFeed != widget.immersiveFeed ||
        oldWidget.hideFeedOverlays != widget.hideFeedOverlays) {
      _scheduleSystemUi();
    }
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || !_foreground || (!_mobile && !_television))
        return;
      final immersive = widget.immersiveFeed
          ? widget.hideFeedOverlays
          : _showFullscreen;
      if (_systemUiImmersive == immersive) return;
      _systemUiImmersive = immersive;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _playback.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _playback.state;
      if (state.playing &&
          !state.buffering &&
          state.width > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  void _reportFeedPlaybackStarted() {
    if (!widget.immersiveFeed || _closed || _feedMediaStarted) return;
    _feedMediaStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) widget.onFeedPlaybackStarted?.call();
    });
  }

  void _reportFeedPlaybackFailed() {
    if (!widget.immersiveFeed ||
        _closed ||
        _feedMediaStarted ||
        _feedFailureReported) {
      return;
    }
    _feedFailureReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed && widget.feedActive?.value != false) {
        widget.onFeedPlaybackFailed?.call();
      }
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    AppDiagnostics.record('playback_recovery', {
      'source': widget.detail.drama.source,
      'code': action.name,
      'stage': widget.immersiveFeed ? 'feed' : 'detail',
    });
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _playback.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : SourceSite.byId(widget.detail.drama.source).kind == 'video'
              ? '视频播放失败，备用地址和重新解析均未成功。请重试或更新站源。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
        if (!current.local) _reportFeedPlaybackFailed();
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    _playIntent = !_playback.state.playing;
    _health.reset();
    if (_playIntent && _playback.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_playback.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
  }

  Future<void> _saveProgress({bool flush = false}) async {
    if (_openedIndex < 0 || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final position = _playback.state.position.inMilliseconds / 1000;
    final duration = _playback.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == progressKey && _saveWarning == null) {
      if (flush && widget.mediaId == null) LanController.current?.flush();
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry);
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
  }) async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final warmed =
        handoffPlan ??
        (recoveryAction == null && _preloadEnabled && !widget.localOnly
            ? _preloader.take(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
              )
            : null);
    _preloader.clear();
    final ticket = ++_generation;
    _acceptErrors = false;
    _pendingError = false;
    _lastCompleted = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        _ => '正在准备播放',
      };
    });
    if (widget.immersiveFeed && widget.feedEpisode?.value != index) {
      widget.feedEpisode?.value = index;
    }
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress(flush: true);
        if (_closed || ticket != _generation) return;
        _openedIndex = -1;
        await _playback.stop().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw AppFailure(
              '播放器初始化或停止超时，请重新打开播放页面',
              code: 'player_initialization',
            );
          },
        );
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              widget.detail.drama,
              widget.detail.episodes[index],
              quality: _requestedQuality,
              localOnly: widget.localOnly,
              online:
                  _forceOnline ||
                  recoveryAction == PlaybackRecoveryAction.refresh,
            );
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        await _playback
            .open(
              plan,
              position: position > 0
                  ? Duration(milliseconds: (position * 1000).round())
                  : Duration.zero,
              play: _foreground && _playIntent,
            )
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                throw AppFailure(
                  '播放器打开媒体超时，请重新打开播放页面',
                  code: 'player_initialization',
                );
              },
            );
        if (_closed || ticket != _generation) {
          return;
        }
        if (!_foreground || !_playIntent) await _playback.pause();
        _openedIndex = index;
        _playbackChanged();
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
          _acknowledgeHandoff();
          _menuRevision.value++;
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null &&
            identical(_plan, prepared) &&
            !(error is AppFailure && error.code == 'player_initialization') &&
            error is! FormatException) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
            if (identical(_plan, prepared)) _plan = null;
          }
          _acceptErrors = false;
          _openedIndex = -1;
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure
                  ? error.message
                  : error is FormatException
                  ? '${error.message}'
                  : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
            if (!_localFailure) _reportFeedPlaybackFailed();
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady:
          quality == null || _error != null || _playback.state.playing,
    );
  }

  bool get _showFullscreen =>
      widget.immersiveFeed ||
      _television ||
      _fullscreen ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _toggleFullscreen() async {
    if (_changingFullscreen || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _changingFullscreen = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                television: _television,
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ),
            ));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _changingFullscreen = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final requestedQuality = preferences.quality;
    final currentPreferences = widget.store.playbackPreferences;
    final nextPreferences = preferences.copyWith(
      quality: widget.immersiveFeed
          ? currentPreferences.quality
          : requestedQuality,
      homeQuality: widget.immersiveFeed
          ? requestedQuality
          : currentPreferences.homeQuality,
      autoAdvance: true,
      preload: true,
    );
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final qualityChanged = requestedQuality != _requestedQuality;
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = requestedQuality;
      _autoAdvance = true;
      _preloadEnabled = true;
    });
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: requestedQuality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('收藏记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!SourceSite.byId(widget.detail.drama.source).supportsDownloads ||
        !widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadsScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = Theme.of(context);
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              local: _plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              series: SourceSite.isSeries(widget.detail.drama.source),
              mobile: _mobile,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              preloadStatus: _preloader.status,
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
        ),
      );
      if (mounted && !_closed && index != null && index != _index) {
        await _play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    try {
      await _playback.seek(target);
    } catch (_) {
      _notice('跳转失败，请重试');
    }
  }

  void _seek(int seconds) {
    final desired = _playback.state.position + Duration(seconds: seconds);
    final maxDuration = _playback.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (_) => Theme(
          data: televisionTheme(Theme.of(context)),
          child: TelevisionEpisodeDialog(
            episodes: widget.detail.episodes,
            currentIndex: _index,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: _preloader,
          builder: (_, _) => Theme(
            data: televisionTheme(Theme.of(context)),
            child: TelevisionSettingsDialog(
              speed: _speed,
              quality: _requestedQuality,
              qualities: _plan?.qualities ?? [],
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              series: SourceSite.isSeries(widget.detail.drama.source),
              onFavorite: _toggleFavorite,
              autoAdvance: _autoAdvance,
              preload: _preloadEnabled,
              preloadStatus: _preloader.status,
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: true,
          preload: true,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  void _back() {
    if (widget.immersiveFeed) {
      widget.onFeedBack?.call();
    } else if (_showFullscreen && !_television) {
      _toggleFullscreen();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _danmakuChanged() {
    if (mounted && !_closed) setState(() {});
  }

  @override
  void dispose() {
    _closed = true;
    VideoDanmaku.enabled.removeListener(_danmakuChanged);
    if (Platform.isAndroid) {
      unawaited(_deviceChannel.invokeMethod<void>('restoreScreenBrightness'));
    }
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    widget.feedEpisode?.removeListener(_feedEpisodeChanged);
    widget.feedActive?.removeListener(_feedVisibilityChanged);
    widget.feedPageActive?.removeListener(_feedVisibilityChanged);
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _interactions.dispose();
    _playback.removeListener(_playbackChanged);
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _interactions.pendingRates.catchError((Object _) {});
        await _playback.close();
      }),
    );
    if (Platform.isWindows && !widget.immersiveFeed) {
      unawaited(windowManager.setFullScreen(false));
    } else if (!widget.immersiveFeed &&
        (_mobile || _television && Platform.isAndroid)) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness =
              widget.immersiveFeed && !widget.hideFeedOverlays
              ? Theme.of(context).brightness
              : fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.detail.drama.title;
    final fullscreen = _showFullscreen;
    return PopScope(
      canPop: widget.immersiveFeed
          ? !_feedPageIsActive
          : _television || !fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.immersiveFeed && _feedPageIsActive) {
          widget.onFeedBack?.call();
        } else if (!didPop && fullscreen && !_television) {
          _toggleFullscreen();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: fullscreen
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            appBar: widget.immersiveFeed || fullscreen || _mobile
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: fullscreen ? '退出全屏' : '全屏',
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                          fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                        ),
                      ),
                    ],
                  ),
            body: widget.immersiveFeed
                ? _videoPane(context)
                : SafeArea(
                    top: !_television && (fullscreen || _mobile),
                    bottom: !fullscreen,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 840;
                        if (fullscreen) {
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 312 : 210,
                                child: _episodePanel(),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          final height = (constraints.maxWidth / (16 / 9))
                              .clamp(0.0, constraints.maxHeight * .56);
                          return Column(
                            children: [
                              SizedBox(
                                height: height,
                                width: double.infinity,
                                child: _videoPane(context),
                              ),
                              Expanded(child: _mobilePlaybackPanel()),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / (16 / 9)).clamp(
                          0.0,
                          constraints.maxHeight * .64,
                        );
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(child: _episodePanel()),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final videoTheme = Theme.of(context);
    final title =
        '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集${_plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    final Widget controls = widget.hideFeedOverlays
        ? const SizedBox.shrink()
        : _television
        ? TelevisionControls(
            player: _playback,
            title: title,
            enabled: !_loading && _error == null,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _back,
          )
        : PlayerControls(
            player: _playback,
            interactions: _interactions,
            enabled: !_loading && _error == null,
            panelOpen: _panelOpen,
            fullscreen: _showFullscreen,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            title: title,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile && !widget.immersiveFeed,
            immersiveFeed: widget.immersiveFeed,
            live:
                SourceSite.byId(widget.detail.drama.source).kind == 'live' ||
                widget.detail.drama.source == 'douyin-live',
            hideFeedOverlays: widget.hideFeedOverlays,
            onFeedDoubleTap: widget.onFeedDoubleTap,
            onFullscreen: widget.immersiveFeed ? () {} : _toggleFullscreen,
            onBack: _back,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _speed,
            qualityLabel: _qualityLabel,
            danmakuOn: VideoDanmaku.enabled.value,
            onDanmaku:
                !widget.localOnly &&
                    _plan?.local != true &&
                    SourceSite.byId(widget.detail.drama.source).supportsDanmaku
                ? () => VideoDanmaku.enabled.value = !VideoDanmaku.enabled.value
                : null,
            onEpisodes: () => _openPanel(PlayerMenuSection.episodes),
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (!_loading &&
            _error == null &&
            !widget.localOnly &&
            _plan?.local != true &&
            !widget.hideFeedOverlays &&
            VideoDanmaku.enabled.value &&
            SourceSite.byId(widget.detail.drama.source).supportsDanmaku)
          VideoDanmaku(
            key: ValueKey(
              'danmaku:${widget.detail.drama.id}:${widget.detail.episodes[_index].id}',
            ),
            player: _playback,
            repository: widget.repository,
            drama: widget.detail.drama,
            episode: widget.detail.episodes[_index],
            active: widget.feedActive,
            pageActive: widget.feedPageActive,
            lowMemory: widget.store.playbackPreferences.lowMemory,
          ),
        controls,
      ],
    );
    return Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              if (widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else
                _playback.buildSurface(
                  fit: widget.immersiveFeed && widget.hideFeedOverlays
                      ? BoxFit.cover
                      : BoxFit.contain,
                  controls: layeredControls,
                ),
              if (_loading)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .78),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppLoadingIndicator(),
                        const SizedBox(height: 16),
                        Text(_loadingMessage),
                      ],
                    ),
                  ),
                ),
              if (_error != null)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .9),
                  child: StatusPanel(
                    title: '暂时无法播放',
                    message: _error!,
                    onRetry: () => _retry(),
                    action: _localFailure ? '重试本地播放' : '重试播放',
                    secondaryAction: _localFailure && widget.allowOnlineFallback
                        ? TextButton.icon(
                            onPressed: _switchOnline,
                            icon: const Icon(Icons.cloud_outlined),
                            label: const Text('改为在线播放'),
                          )
                        : !_localFailure &&
                              !widget.localOnly &&
                              widget.repository.supportsSourceManagement
                        ? SourceDiagnosticsButton(
                            repository: widget.repository,
                            store: widget.store,
                            drama: widget.detail.drama,
                          )
                        : null,
                    icon: Icons.play_disabled_rounded,
                  ),
                ),
              if ((_loading || _error != null) &&
                  _showFullscreen &&
                  !_television)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '退出全屏',
                          onPressed: _toggleFullscreen,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              _openPanel(PlayerMenuSection.episodes),
                          child: const Text('选集'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saveWarning != null)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _saveWarning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: const Text('重试保存'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _mobilePlaybackPanel() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _mobileTabs(colors),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _mobileTab == 0
                      ? _episodePanel(compact: true)
                      : _mobileTab == 1
                      ? (SourceSite.byId(
                              widget.detail.drama.source,
                            ).supportsCreator
                            ? DouyinCreatorScreen(
                                key: ValueKey(
                                  'creator:${widget.detail.drama.id}',
                                ),
                                drama: widget.detail.drama,
                                repository: widget.repository,
                                store: widget.store,
                                embedded: true,
                                onPlay: _openCreatorWork,
                              )
                            : _mobileSynopsis())
                      : _mobileDownload(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileTabs(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
    child: SizedBox(
      height: 42,
      child: Row(
        children: [
          _mobileTabButton(0, '选集'),
          _mobileTabButton(
            1,
            SourceSite.byId(widget.detail.drama.source).supportsCreator
                ? '作者主页'
                : '简介',
          ),
          if (SourceSite.byId(widget.detail.drama.source).supportsDownloads)
            _mobileTabButton(2, '下载'),
        ],
      ),
    ),
  );

  Widget _mobileTabButton(int value, String label) {
    final selected = _mobileTab == value;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mobileTab = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openCreatorWork(Drama drama) async {
    if (_creatorWorkOpening || _closed || !mounted) return;
    _creatorWorkOpening = true;
    final resume = _playIntent;
    _playIntent = false;
    _interactions.cancel();
    try {
      await _playback.pause();
      if (!mounted || _closed) return;
      await openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      );
    } finally {
      _creatorWorkOpening = false;
      if (mounted &&
          !_closed &&
          _foreground &&
          widget.store.profileEpoch == _profileEpoch &&
          widget.store.allowsSource(widget.detail.drama.source)) {
        _playIntent = resume;
        if (resume) await _playback.play();
      }
    }
  }

  Widget _mobileSynopsis() {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
      if (drama.category.isNotEmpty) drama.category,
    ];
    final body = drama.description.trim().isEmpty ? '暂无简介' : drama.description;
    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            '${drama.onlineDate} 上线',
                          if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                          if (drama.views.isNotEmpty) '播放 ${drama.views}',
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mobileFollowControl(drama),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  Chip(label: Text(tag), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.55)),
          if (widget.detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(widget.detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _mobileFollowControl(Drama drama) {
    if (!SourceSite.isSeries(drama.source)) {
      final saved = widget.store.isFavorite(drama.id);
      return FilledButton.tonalIcon(
        key: const ValueKey('player-content-save'),
        onPressed: () =>
            saveUserChange(context, () => widget.store.toggleFavorite(drama)),
        icon: Icon(
          saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        ),
        label: Text(saved ? '已收藏' : '加入收藏'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        ),
      );
    }
    final state = widget.store.following(drama.id);
    return PopupMenuButton<String>(
      key: const ValueKey('player-follow-status'),
      tooltip: '追剧与观看状态',
      onSelected: (value) async {
        if (_profileEpoch != widget.store.profileEpoch) return;
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
        if (mounted && !_closed) setState(() {});
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(status.label),
          ),
        if (state != null)
          const PopupMenuItem(value: 'remove', child: Text('取消追剧')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: state == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              state == null
                  ? Icons.bookmark_add_outlined
                  : Icons.bookmark_rounded,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(state?.label ?? '加入追剧'),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDownload() {
    final colors = Theme.of(context).colorScheme;
    if (!SourceSite.byId(widget.detail.drama.source).supportsDownloads ||
        !widget.repository.supportsDownloads ||
        !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surface,
        child: const StatusPanel(
          title: '下载不可用',
          message: '当前用户或当前环境未开放本地下载。',
          icon: Icons.download_outlined,
        ),
      );
    }
    return DownloadPicker(
      detail: widget.detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _episodePanel({bool compact = false}) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: PlayerEpisodeGrid(
      episodes: widget.detail.episodes,
      currentIndex: _index,
      compact: compact,
      title: compact ? '剧集' : '选集',
      onSelected: (index) => _play(index),
    ),
  );
}
