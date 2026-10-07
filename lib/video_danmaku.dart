import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'core_bridge.dart';
import 'models.dart';
import 'playback_engine.dart';

class VideoDanmaku extends StatefulWidget {
  const VideoDanmaku({
    super.key,
    required this.player,
    required this.repository,
    required this.drama,
    required this.episode,
    this.active,
    this.pageActive,
    this.lowMemory = false,
  });
  static final enabled = ValueNotifier<bool>(false);
  final PlaybackEngine player;
  final AppRepository repository;
  final Drama drama;
  final Episode episode;
  final ValueListenable<bool>? active, pageActive;
  final bool lowMemory;
  @override
  State<VideoDanmaku> createState() => _VideoDanmakuState();
}

class _VideoDanmakuState extends State<VideoDanmaku>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  final _pages = <int, List<Map<String, dynamic>>>{};
  final _failed = <int>{};
  final _watch = Stopwatch();
  List<_DanmakuLine> _lines = [];
  bool _pending = false, _noticed = false;
  int _generation = 0, _timelineRevision = -1;
  int? _samplePosition;
  double _base = 0, _rate = 1, _correction = 0;
  double _width = 0;
  int get _window => SourceSite.providerIdFor(widget.drama.source) == 'bilibili'
      ? 360000
      : 32000;
  bool get _active =>
      VideoDanmaku.enabled.value &&
      widget.active?.value != false &&
      widget.pageActive?.value != false;
  double get _position =>
      _base +
      (_clock.isAnimating
          ? math.min(_watch.elapsedMicroseconds / 1000, 1500) *
                (_rate + _correction)
          : 0);

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    widget.player.addListener(_sync);
    widget.active?.addListener(_sync);
    widget.pageActive?.addListener(_sync);
    VideoDanmaku.enabled.addListener(_switch);
    _sync();
  }

  void _switch() {
    if (!VideoDanmaku.enabled.value) {
      _generation++;
      widget.repository.cancelDanmaku(widget.drama.source);
      _pages.clear();
      _failed.clear();
      _clearLines();
      _noticed = false;
    }
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    final state = widget.player.state;
    final sample = state.position.inMilliseconds;
    final position = _position;
    final running = _active && state.playing && !state.buffering;
    final timelineChanged = _timelineRevision != widget.player.timelineRevision;
    final jumped =
        _samplePosition != null &&
        sample < _samplePosition! - 1500 &&
        sample < position - 1500;
    if (_samplePosition == null || timelineChanged || jumped) {
      _base = timelineChanged && _timelineRevision >= 0
          ? widget.player.timelinePosition.inMilliseconds.toDouble()
          : sample.toDouble();
      _correction = 0;
      _watch
        ..reset()
        ..start();
    } else if (sample != _samplePosition ||
        _rate != state.rate ||
        running != _clock.isAnimating) {
      _base = position;
      _correction = sample != _samplePosition && running && _rate == state.rate
          ? ((sample - position) / 1000)
                .clamp(-state.rate * .15, state.rate * .15)
                .toDouble()
          : 0;
      _watch
        ..reset()
        ..start();
    }
    _samplePosition = sample;
    _timelineRevision = widget.player.timelineRevision;
    _rate = state.rate;
    if (running) {
      if (!_clock.isAnimating) _clock.repeat();
      if (state.duration > Duration.zero) {
        final start = (sample ~/ _window) * _window;
        final pageCount = _pages.length;
        _pages.removeWhere(
          (key, _) => key < start - _window || key > start + _window,
        );
        if (pageCount != _pages.length) _layout();
        _failed.removeWhere(
          (key) => key < start - _window || key > start + _window,
        );
        if (!_pages.containsKey(start) && !_failed.contains(start)) {
          unawaited(_fetch(start));
        } else if (!widget.lowMemory &&
            start + _window - _base < 4000 &&
            start + _window < state.duration.inMilliseconds &&
            !_pages.containsKey(start + _window) &&
            !_failed.contains(start + _window)) {
          unawaited(_fetch(start + _window));
        }
      }
    } else {
      _clock.stop();
    }
  }

  Future<void> _fetch(int start) async {
    if (_pending || !_active) return;
    _pending = true;
    final generation = _generation;
    try {
      final response = await widget.repository.danmaku(
        widget.drama,
        widget.episode,
        start,
      );
      if (!mounted || generation != _generation || !_active) return;
      final rows = (response['items'] as List? ?? const [])
          .whereType<Map>()
          .take(1800)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      _pages[start] = rows;
      final limit = widget.lowMemory ? 1 : 3;
      while (_pages.length > limit) {
        _pages.remove(_pages.keys.first);
      }
      _layout();
    } catch (_) {
      if (mounted && generation == _generation && _active) {
        _failed.add(start);
        if (!_noticed) {
          _noticed = true;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('弹幕暂时无法加载，视频播放不受影响；关闭后再开启可重试。')),
          );
        }
      }
    } finally {
      _pending = false;
      if (mounted && generation == _generation) _sync();
    }
  }

  void _clearLines() {
    for (final line in _lines) {
      line.dispose();
    }
    _lines = [];
  }

  void _layout() {
    _clearLines();
    final rows = _pages.values.expand((rows) => rows).toList()
      ..sort(
        (a, b) =>
            intValue(a['positionMs']).compareTo(intValue(b['positionMs'])),
      );
    final lanes = List<int>.filled(widget.lowMemory ? 3 : 4, -10000);
    final lines = <_DanmakuLine>[];
    final seen = <String>{};
    for (final row in rows) {
      final text = '${row['text'] ?? ''}'
          .replaceAll(RegExp(r'[\r\n]'), ' ')
          .trim();
      final position = intValue(row['positionMs']);
      final mode = intValue(row['mode']);
      if (text.isEmpty ||
          text.length > 120 ||
          position < 0 ||
          !{1, 2, 3, 4, 5}.contains(mode))
        continue;
      if (!seen.add('$position:$text')) continue;
      final lane = lanes.indexWhere((time) => time <= position);
      if (lane < 0) continue;
      lanes[lane] = position + 6000;
      lines.add(
        _DanmakuLine(
          position,
          lane,
          mode,
          text,
          Color(0xff000000 | (intValue(row['color']) & 0xffffff)),
          math.max(_width * .8, 160),
        ),
      );
    }
    _lines = lines;
  }

  @override
  void dispose() {
    _generation++;
    widget.player.removeListener(_sync);
    widget.active?.removeListener(_sync);
    widget.pageActive?.removeListener(_sync);
    VideoDanmaku.enabled.removeListener(_switch);
    _clearLines();
    _clock.dispose();
    _watch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_width != constraints.maxWidth) {
            _width = constraints.maxWidth;
            _layout();
          }
          return CustomPaint(
            painter: _DanmakuPainter(
              Listenable.merge([
                _clock,
                widget.player,
                VideoDanmaku.enabled,
                if (widget.active != null) widget.active!,
                if (widget.pageActive != null) widget.pageActive!,
              ]),
              () => _active ? _lines : [],
              () => _position,
            ),
          );
        },
      ),
    ),
  );
}

class _DanmakuLine {
  _DanmakuLine(
    this.position,
    this.lane,
    this.mode,
    this.content,
    this.color,
    this.width,
  );
  final int position, lane, mode;
  final String content;
  final Color color;
  final double width;
  TextPainter? _text;
  TextPainter get text {
    final cached = _text;
    if (cached != null) return cached;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
      text: TextSpan(
        text: content,
        style: TextStyle(
          fontSize: 16,
          color: color,
          shadows: const [
            Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1, 1)),
          ],
        ),
      ),
    )..layout(maxWidth: width);
    _text = painter;
    return painter;
  }

  void dispose() {
    _text?.dispose();
    _text = null;
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(Listenable clock, this.lines, this.position)
    : super(repaint: clock);
  final List<_DanmakuLine> Function() lines;
  final double Function() position;
  @override
  void paint(Canvas canvas, Size size) {
    final now = position();
    final rows = lines();
    var low = 0, high = rows.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (rows[mid].position < now - 6000) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = low; i < rows.length && rows[i].position <= now; i++) {
      final row = rows[i];
      final fraction = (now - row.position) / 6000;
      final x = row.mode == 4 || row.mode == 5
          ? (size.width - row.text.width) / 2
          : size.width - (size.width + row.text.width) * fraction;
      final y = row.mode == 4
          ? math.max(18.0, size.height - 120 - row.lane * 26)
          : 18.0 + row.lane * 26;
      row.text.paint(canvas, Offset(x, y));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter old) => true;
}
