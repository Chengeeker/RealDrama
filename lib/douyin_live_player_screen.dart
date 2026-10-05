import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
import 'douyin_author_panel.dart';
import 'douyin_creator_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_preferences.dart';
import 'widgets.dart';

class DouyinLivePlayerScreen extends StatefulWidget {
  const DouyinLivePlayerScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;

  @override
  State<DouyinLivePlayerScreen> createState() => _DouyinLivePlayerScreenState();
}

class _DouyinLivePlayerScreenState extends State<DouyinLivePlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _video;
  late final StreamSubscription<String> _errors;
  int _generation = 0;
  bool _loading = true;
  String? _error;
  String _title = '';
  Drama? _roomDrama;
  bool _creatorOpen = false;
  bool get _foreground =>
      !_creatorOpen &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<void> _openCreator() async {
    if (_creatorOpen) return;
    final resume = _player.state.playing || _loading;
    _creatorOpen = true;
    await _player.pause();
    if (!mounted) return;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => DouyinCreatorScreen(
            drama: _roomDrama ?? widget.drama,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
    } finally {
      _creatorOpen = false;
      if (mounted && resume && _foreground && _error == null && !_loading)
        await _player.play();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) MediaKit.ensureInitialized();
    final preferences = widget.store.playbackPreferences;
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: preferences.bufferBytes,
        logLevel: MPVLogLevel.error,
      ),
    );
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration:
            preferences.hardwareDecoding && !Platform.isIOS,
        hwdec: preferences.hardwareDecoding && !Platform.isIOS ? null : 'no',
      ),
    );
    _errors = _player.stream.error.listen((message) {
      if (mounted && message.trim().isNotEmpty) {
        setState(() {
          _loading = false;
          _error = '直播播放失败，请重试或更换直播间';
        });
      }
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final room = await widget.repository.douyinLiveRoom(widget.drama);
      if (!mounted || generation != _generation) return;
      setState(() {
        _title = room.drama.title;
        _roomDrama = room.drama;
      });
      await _player.open(
        Media(room.plan.url, httpHeaders: room.plan.headers),
        play: _foreground,
      );
      if (!mounted || generation != _generation) return;
      if (!_foreground) await _player.pause();
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_player.pause());
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_errors.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _title.isEmpty ? widget.drama.title : _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  controller: _video,
                  fit: BoxFit.contain,
                  fill: Colors.black,
                  controls: (_) => const SizedBox.shrink(),
                  wakelock: true,
                ),
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: false,
                  builder: (context, snapshot) {
                    final playing = snapshot.data == true;
                    return Center(
                      child: IconButton.filledTonal(
                        tooltip: playing ? '暂停直播' : '播放直播',
                        style: IconButton.styleFrom(
                          backgroundColor: colors.primary.withValues(
                            alpha: .88,
                          ),
                          foregroundColor: colors.onPrimary,
                          fixedSize: const Size(64, 64),
                        ),
                        onPressed: () => unawaited(
                          playing ? _player.pause() : _player.play(),
                        ),
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 38,
                        ),
                      ),
                    );
                  },
                ),
                if (_loading || _error != null)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: .55),
                    child: Center(
                      child: _error == null
                          ? const AppLoadingIndicator(size: 38)
                          : Padding(
                              padding: const EdgeInsets.all(28),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.live_tv_outlined,
                                    color: Colors.white,
                                    size: 42,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  const SizedBox(height: 14),
                                  FilledButton.icon(
                                    onPressed: _loading ? null : _load,
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                Positioned(
                  left: 16,
                  top: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade700,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '直播',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AnimatedBuilder(
                animation: widget.store,
                builder: (context, _) => DouyinAuthorPanel(
                  drama: _roomDrama ?? widget.drama,
                  onOpen: _openCreator,
                  followed: widget.store.isCreatorFollowed(
                    _roomDrama ?? widget.drama,
                  ),
                  onFollow: () => widget.store.toggleCreatorFollow(
                    _roomDrama ?? widget.drama,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
