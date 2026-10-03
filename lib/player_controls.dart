import 'dart:async';

import 'package:flutter/material.dart';

import 'playback_engine.dart';
import 'player_interactions.dart';
import 'widgets.dart';

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    required this.onFullscreen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.title,
    required this.onTogglePlayback,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onQuality,
    required this.speed,
    required this.qualityLabel,
    required this.onFocusSurface,
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.immersiveFeed = false,
    this.hideFeedOverlays = false,
    this.live = false,
    this.onFeedDoubleTap,
    this.onSeek,
  });

  final PlaybackEngine player;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String title;
  final VoidCallback onTogglePlayback;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSpeed;
  final Future<void> Function() onQuality;
  final double speed;
  final String qualityLabel;
  final VoidCallback onFocusSurface;
  final bool swipeEnabled;
  final bool panelOpen;
  final bool immersiveFeed;
  final bool hideFeedOverlays;
  final bool live;
  final VoidCallback? onFeedDoubleTap;
  final Future<void> Function(Duration)? onSeek;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  Timer? _redrawTimer;
  bool _lastBuffering = false;
  Timer? _hideTimer;
  Timer? _playbackFeedbackTimer;
  bool _visible = true;
  bool _playbackFeedbackVisible = false;
  bool _suppressAutoPlaybackStart = false;
  bool _lastPlaying = false;
  double? _seekValue;
  Offset? _doubleTapPosition;

  @override
  void initState() {
    super.initState();
    _visible = widget.showOnPlaybackReady;
    _suppressAutoPlaybackStart = !widget.showOnPlaybackReady;
    _lastPlaying = widget.player.state.playing;
    _lastBuffering = widget.player.state.buffering;
    widget.player.addListener(_playerChanged);
    widget.interactions.addListener(_interactionChanged);
    _scheduleHide();
  }

  void _playerChanged() {
    if (!mounted) return;
    final state = widget.player.state;
    final wasPlaying = _lastPlaying;
    final changedPlayback =
        state.playing != wasPlaying || state.buffering != _lastBuffering;
    _lastPlaying = state.playing;
    _lastBuffering = state.buffering;
    if (changedPlayback) {
      _redrawTimer?.cancel();
      _redrawTimer = null;
      setState(() {});
    } else {
      _redrawTimer ??= Timer(const Duration(milliseconds: 100), () {
        _redrawTimer = null;
        if (mounted) setState(() {});
      });
    }
    if (!widget.enabled) return;
    if (!state.playing && wasPlaying) {
      _show();
    } else if (state.playing && !wasPlaying) {
      if (_suppressAutoPlaybackStart) {
        _suppressAutoPlaybackStart = false;
        _scheduleHide();
      } else {
        _show();
      }
    }
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      _seekValue = null;
      if (widget.showOnPlaybackReady) {
        _suppressAutoPlaybackStart = false;
      } else if (widget.enabled && !oldWidget.enabled) {
        _suppressAutoPlaybackStart = !widget.player.state.playing;
      } else if (!widget.enabled && oldWidget.enabled) {
        _suppressAutoPlaybackStart = true;
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        if (widget.showOnPlaybackReady || !widget.player.state.playing) {
          _visible = true;
        } else {
          _visible = false;
        }
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      _scheduleHide();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.interactions.feedback.isNotEmpty) _show();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.enabled ||
        widget.panelOpen ||
        !widget.player.state.playing ||
        _seekValue != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          widget.enabled &&
          !widget.panelOpen &&
          widget.player.state.playing &&
          !widget.player.state.buffering &&
          !widget.interactions.boosting &&
          _seekValue == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _showPlaybackFeedback() {
    if (!widget.immersiveFeed) return;
    _playbackFeedbackTimer?.cancel();
    if (!_playbackFeedbackVisible) {
      setState(() => _playbackFeedbackVisible = true);
    }
    _playbackFeedbackTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _playbackFeedbackVisible = false);
    });
  }

  void _tap() {
    if (widget.interactions.suppressTap) return;
    widget.onFocusSurface();
    if (widget.immersiveFeed) {
      if (!widget.enabled) return;
      widget.onTogglePlayback();
      _showPlaybackFeedback();
      _show();
      return;
    }
    setState(() => _visible = !_visible);
    _scheduleHide();
  }

  void _doubleTap(BoxConstraints constraints) {
    if (!widget.enabled || widget.interactions.suppressTap) return;
    if (widget.immersiveFeed) {
      widget.onFeedDoubleTap?.call();
      _show();
      return;
    }
    final position = _doubleTapPosition;
    final width = constraints.maxWidth;
    if (position != null && width > 0 && position.dx < width * .35) {
      widget.interactions.seek(-10);
    } else if (position != null && width > 0 && position.dx > width * .65) {
      widget.interactions.seek(10);
    } else {
      widget.onTogglePlayback();
    }
    _show();
  }

  Future<void> _panel(Future<void> Function() open) async {
    _hideTimer?.cancel();
    widget.interactions.cancel();
    await open();
    _show();
  }

  @override
  void dispose() {
    _redrawTimer?.cancel();
    _hideTimer?.cancel();
    _playbackFeedbackTimer?.cancel();
    widget.player.removeListener(_playerChanged);
    widget.interactions.removeListener(_interactionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.immersiveFeed && widget.hideFeedOverlays) {
      return const SizedBox.expand();
    }
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position = state.position.inMilliseconds / 1000;
    final buffered = state.buffer.inMilliseconds / 1000;
    final showFeedPlaybackControl = !state.playing || _playbackFeedbackVisible;
    final visible =
        _visible || !state.playing || state.buffering || widget.panelOpen;
    return MouseRegion(
      onHover: (_) => _show(),
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('player-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                widget.onFocusSurface();
                widget.interactions.pointerDown(
                  event,
                  swipeEnabled: widget.swipeEnabled,
                  height: constraints.maxHeight,
                );
              },
              onPointerMove: widget.interactions.pointerMove,
              onPointerUp: widget.interactions.pointerUp,
              onPointerCancel: widget.interactions.pointerCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: (details) {
                  _doubleTapPosition = details.localPosition;
                },
                onTap: _tap,
                onDoubleTap: () => _doubleTap(constraints),
              ),
            ),
            if (state.buffering && widget.enabled)
              const IgnorePointer(child: Center(child: AppLoadingIndicator())),
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!widget.immersiveFeed)
                        const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0xAA000000),
                                  Colors.transparent,
                                  Color(0xE6000000),
                                ],
                                stops: [0, .45, 1],
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          _topChromeInset(),
                          8,
                          _bottomChromeInset(),
                        ),
                        child: Stack(
                          children: [
                            if (!widget.immersiveFeed &&
                                (widget.fullscreen || widget.swipeEnabled))
                              _topBar(),
                            if (!widget.interactions.boosting &&
                                !state.buffering &&
                                widget.enabled &&
                                constraints.maxHeight >=
                                    (widget.swipeEnabled ? 168 : 220))
                              IgnorePointer(
                                ignoring:
                                    widget.immersiveFeed &&
                                    !showFeedPlaybackControl,
                                child: AnimatedOpacity(
                                  opacity:
                                      !widget.immersiveFeed ||
                                          showFeedPlaybackControl
                                      ? 1
                                      : 0,
                                  duration: const Duration(milliseconds: 150),
                                  child: _centerPlayback(
                                    state.playing,
                                    showSkip: !widget.immersiveFeed,
                                  ),
                                ),
                              ),
                            if (!widget.immersiveFeed)
                              _bottomControls(
                                constraints: constraints,
                                volume: state.volume,
                                duration: duration,
                                position: position,
                                buffered: buffered,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.immersiveFeed && !widget.live && duration > 0)
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: IgnorePointer(
                  child: SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      value: (position / duration).clamp(0, 1).toDouble(),
                      backgroundColor: Colors.white38,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            _gestureFeedback(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    if (widget.immersiveFeed) return const SizedBox.shrink();
    final compact = widget.swipeEnabled && !widget.fullscreen;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: compact ? 8 : 0),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: widget.fullscreen ? '退出全屏' : '返回',
              onPressed: widget.fullscreen
                  ? widget.onFullscreen
                  : widget.onBack,
              icon: widget.fullscreen
                  ? Icons.arrow_back_rounded
                  : Icons.arrow_back_ios_new_rounded,
            ),
            if (!compact)
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(22),
      ),
      child: IconButton(
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 42, height: 42),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    ),
  );

  Widget _centerPlayback(bool playing, {required bool showSkip}) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSkip) ...[
            IconButton(
              tooltip: '上一集',
              onPressed: widget.onPrevious,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            const SizedBox(width: 12),
          ],
          IconButton.filled(
            tooltip: playing ? '暂停播放' : '开始播放',
            iconSize: 38,
            style: IconButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
            ),
            onPressed: () {
              widget.onTogglePlayback();
              _showPlaybackFeedback();
              _show();
            },
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          if (showSkip) ...[
            const SizedBox(width: 12),
            IconButton(
              tooltip: '下一集',
              onPressed: widget.onNext,
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ],
      ),
    );
  }

  Widget _bottomControls({
    required BoxConstraints constraints,
    required double volume,
    required double duration,
    required double position,
    required double buffered,
  }) {
    final width = constraints.maxWidth;
    final fullscreen = widget.fullscreen;
    final mobile = widget.swipeEnabled;
    final showEpisodes = fullscreen;
    final showSpeedQuality =
        mobile || fullscreen && width >= 720 || !fullscreen && width >= 560;
    final showVolume = !widget.swipeEnabled && width >= 360;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mobile)
            _mobileControlRow(fullscreen: fullscreen)
          else
            _desktopControlRow(
              fullscreen: fullscreen,
              showEpisodes: showEpisodes,
              showSpeedQuality: showSpeedQuality,
              showVolume: showVolume,
              volume: volume,
            ),
          _progressRow(
            duration: duration,
            position: position,
            buffered: buffered,
          ),
        ],
      ),
    );
  }

  double _topChromeInset() {
    if (widget.fullscreen) {
      final top = MediaQuery.paddingOf(context).top;
      if (top <= 0) return 16;
      return (top + 16).clamp(40.0, 80.0);
    }
    if (widget.swipeEnabled) {
      return 10;
    }
    return 0;
  }

  double _bottomChromeInset() {
    if (widget.fullscreen) {
      final media = MediaQuery.of(context);
      if (media.size.width > media.size.height) {
        return (media.viewPadding.bottom + 8).clamp(12.0, 28.0);
      }
      return (MediaQuery.viewPaddingOf(context).bottom + 24).clamp(64.0, 104.0);
    }
    return 0;
  }

  Widget _progressRow({
    required double duration,
    required double position,
    required double buffered,
  }) {
    final timeStyle = TextStyle(
      fontSize: 12,
      color: Colors.white.withValues(alpha: .82),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 43,
              child: Text(
                formatPosition(_seekValue ?? position),
                style: timeStyle,
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('player-progress'),
                  value: (_seekValue ?? position).clamp(
                    0,
                    duration > 0 ? duration : 1,
                  ),
                  max: duration > 0 ? duration : 1,
                  secondaryTrackValue: buffered.clamp(
                    0,
                    duration > 0 ? duration : 1,
                  ),
                  semanticFormatterCallback: formatPosition,
                  onChangeStart: widget.enabled && duration > 0
                      ? (_) {
                          widget.interactions.cancel();
                          _hideTimer?.cancel();
                        }
                      : null,
                  onChanged: !widget.enabled || duration <= 0
                      ? null
                      : (value) {
                          _hideTimer?.cancel();
                          setState(() => _seekValue = value);
                        },
                  onChangeEnd: (value) {
                    if (widget.enabled && duration > 0) {
                      (widget.onSeek ?? widget.player.seek)(
                        Duration(milliseconds: (value * 1000).round()),
                      );
                    }
                    setState(() => _seekValue = null);
                    _show();
                  },
                ),
              ),
            ),
            SizedBox(
              width: 43,
              child: Text(formatPosition(duration), style: timeStyle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: Icon(icon, size: 22),
  );

  Widget _toolText({
    required Key key,
    required String tooltip,
    required String label,
    required VoidCallback? onPressed,
    double width = 52,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    visualWidth: width,
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    ),
  );

  Widget _toolButton({
    required Key key,
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
    double visualWidth = 36,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = selected
        ? scheme.primary
        : Colors.white.withValues(alpha: enabled ? .92 : .36);
    final background = selected
        ? scheme.primary.withValues(alpha: .20)
        : Colors.black.withValues(alpha: .22);
    final border = selected
        ? scheme.primary.withValues(alpha: .62)
        : Colors.white.withValues(alpha: .08);
    final targetWidth = visualWidth < 40 ? 48.0 : visualWidth + 8;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: targetWidth,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: visualWidth,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: border),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 22),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13.5,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolGroup(List<Widget> children) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);

  Widget _clusteredToolRow(List<Widget> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    if (tools.length <= 5) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [_toolGroup(tools)],
      );
    }
    final leftCount = tools.length ~/ 2;
    return Row(
      children: [
        _toolGroup(tools.take(leftCount).toList()),
        const Spacer(),
        _toolGroup(tools.skip(leftCount).toList()),
      ],
    );
  }

  Widget _desktopControlRow({
    required bool fullscreen,
    required bool showEpisodes,
    required bool showSpeedQuality,
    required bool showVolume,
    required double volume,
  }) {
    final tools = [
      if (showSpeedQuality) ...[
        _toolText(
          key: const ValueKey('player-speed'),
          tooltip: '倍速',
          label: '${widget.speed}x',
          onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
          width: 50,
        ),
        _toolText(
          key: const ValueKey('player-quality'),
          tooltip: '清晰度',
          label: widget.qualityLabel,
          onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
          width: 52,
        ),
      ],
      if (showEpisodes)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (showVolume)
        _toolIcon(
          key: const ValueKey('player-volume'),
          tooltip: '音量',
          icon: volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          onPressed: widget.enabled
              ? () => _panel(() => _openVolume(volume))
              : null,
        ),
      _toolIcon(
        key: const ValueKey('player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '全屏',
        icon: fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        onPressed: widget.onFullscreen,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Widget _mobileControlRow({required bool fullscreen}) {
    final tools = [
      _toolText(
        key: const ValueKey('player-speed'),
        tooltip: '倍速',
        label: '${widget.speed}x',
        onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
        width: 50,
      ),
      _toolText(
        key: const ValueKey('player-quality'),
        tooltip: '清晰度',
        label: widget.qualityLabel,
        onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
        width: 52,
      ),
      if (fullscreen)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (!widget.immersiveFeed)
        _toolIcon(
          key: const ValueKey('player-fullscreen'),
          tooltip: fullscreen ? '退出全屏' : '全屏',
          icon: fullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          onPressed: widget.enabled ? widget.onFullscreen : null,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Future<void> _openVolume(double initialVolume) async {
    var volume = initialVolume.clamp(0.0, 100.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setState) => SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: widget.swipeEnabled ? 12 : 20,
                    bottom: widget.fullscreen ? 88 : 74,
                  ),
                  child: Material(
                    color: Colors.black.withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 62,
                      height: 192,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: volume == 0 ? '恢复音量' : '静音',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              final next = volume == 0 ? 100.0 : 0.0;
                              setState(() => volume = next);
                              unawaited(widget.player.setVolume(next));
                            },
                            icon: Icon(
                              volume == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  value: volume,
                                  max: 100,
                                  divisions: 20,
                                  onChanged: (value) {
                                    setState(() => volume = value);
                                    unawaited(widget.player.setVolume(value));
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: Center(
                              child: Text(
                                '${volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(.04, .08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
              child: child,
            ),
          ),
    );
  }

  Widget _gestureFeedback() => AnimatedBuilder(
    animation: widget.interactions,
    builder: (context, _) {
      final feedback = widget.interactions.feedback;
      if (feedback.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.5),
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(
                alpha: widget.interactions.speedFeedback ? .18 : .87,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(feedback, textAlign: TextAlign.center),
          ),
        ),
      );
    },
  );
}
