import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(this.repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final String _requestKey =
      'preloadplayer${DateTime.now().microsecondsSinceEpoch}';
  PlaybackPlan? _ready;
  String? _identity;
  Timer? _delay;
  DateTime _expires = DateTime(2000), _retryAt = DateTime(2000);
  int _generation = 0;
  bool _closed = false, loading = false;
  String error = '';
  void _release(PlaybackPlan plan) =>
      unawaited(repository.release(plan.session).catchError((Object _) {}));

  String get status {
    if (_ready != null && _now().isBefore(_expires)) {
      final bytes = _ready!.prefetchedBytes;
      return _ready!.local
          ? '下一集已下载'
          : bytes > 0
          ? '下一集已准备 · 预取 ${(bytes / 1024).ceil()} KB'
          : '下一集播放地址已准备';
    }
    if (loading || _delay != null) return '正在准备下一集';
    return error.isNotEmpty ? '下一集预加载暂不可用，切集时会重新获取' : '播放后段提前准备下一集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.number}\u0000$quality\u0000$online';

  void prepare(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    if (_closed) return;
    final identity = _key(drama, episode, quality, online);
    if (_identity != identity) {
      clear();
      _identity = identity;
    }
    if (_ready != null && !_now().isBefore(_expires)) {
      final expired = _ready!;
      _ready = null;
      _release(expired);
    }
    if (_ready != null ||
        loading ||
        _delay != null ||
        _now().isBefore(_retryAt)) {
      return;
    }
    final ticket = _generation;
    _delay = Timer(const Duration(milliseconds: 600), () async {
      _delay = null;
      loading = true;
      notifyListeners();
      try {
        final plan = await repository.preload(
          drama,
          episode,
          quality: quality,
          online: online,
          requestKey: _requestKey,
        );
        if (_closed || ticket != _generation) {
          if (plan != null) await repository.release(plan.session);
          return;
        }
        if (plan == null || plan.url.isEmpty) throw AppFailure('未取得预加载结果');
        var expires = _now().add(const Duration(minutes: 2));
        if (plan.expiresAt > 0) {
          final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
            plan.expiresAt,
          ).subtract(const Duration(seconds: 5));
          if (authorizationExpiry.isBefore(expires)) {
            expires = authorizationExpiry;
          }
        }
        if (!expires.isAfter(_now())) {
          _release(plan);
          throw AppFailure('下一集播放凭证即将过期');
        }
        _ready = plan;
        _expires = expires;
        error = '';
      } catch (failure) {
        if (_closed || ticket != _generation) return;
        error = failure.toString();
        _retryAt = _now().add(const Duration(seconds: 30));
      } finally {
        if (!_closed && ticket == _generation) {
          loading = false;
          notifyListeners();
        }
      }
    });
    notifyListeners();
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final result =
        _identity == _key(drama, episode, quality, online) &&
            _now().isBefore(_expires)
        ? _ready
        : null;
    if (result != null) _ready = null;
    clear();
    return result;
  }

  void pause() {
    final changed = loading || _delay != null;
    _generation++;
    _delay?.cancel();
    _delay = null;
    if (loading) {
      unawaited(
        repository
            .cancelPreload(requestKey: _requestKey)
            .catchError((Object _) {}),
      );
    }
    loading = false;
    if (changed && !_closed) notifyListeners();
  }

  void clear() {
    pause();
    final old = _ready;
    _ready = null;
    _identity = null;
    _retryAt = DateTime(2000);
    error = '';
    if (old != null) _release(old);
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}

class FeedPlaybackPreloader {
  FeedPlaybackPreloader(this.repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final Map<String, _FeedPreparedPlayback> _ready = {};
  final Map<String, _FeedPlaybackWarmup> _pending = {};
  final Set<String> _targetDramas = {};
  Future<void> _queue = Future<void>.value();
  int _sequence = 0;
  bool _closed = false;

  String _dramaIdentity(Drama drama) => '${drama.source}:${drama.id}';

  String _planIdentity(
    Drama drama,
    Episode episode,
    int quality,
    bool online,
  ) =>
      '${_dramaIdentity(drama)}\u0000${episode.number}\u0000$quality\u0000$online';

  void retainDramas(Set<String> identities) {
    if (_closed) return;
    _targetDramas
      ..clear()
      ..addAll(identities);
    final expired = <String>[];
    for (final entry in _ready.entries) {
      if (!_targetDramas.any(
            (identity) => entry.key.startsWith('$identity\u0000'),
          ) ||
          !_now().isBefore(entry.value.expiresAt)) {
        expired.add(entry.key);
      }
    }
    for (final key in expired) {
      final prepared = _ready.remove(key);
      if (prepared != null) _release(prepared.plan);
    }
    for (final entry in _pending.entries.toList()) {
      if (_targetDramas.any(
        (identity) => entry.key.startsWith('$identity\u0000'),
      )) {
        continue;
      }
      _pending.remove(entry.key);
      unawaited(
        repository
            .cancelPreload(requestKey: entry.value.requestKey)
            .catchError((Object _) {}),
      );
    }
  }

  void prepare(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    if (_closed) return;
    final identity = _planIdentity(drama, episode, quality, online);
    final dramaIdentity = _dramaIdentity(drama);
    if (!_targetDramas.contains(dramaIdentity) ||
        _ready.containsKey(identity) ||
        _pending.containsKey(identity)) {
      return;
    }
    final requestKey =
        'preloadfeed${DateTime.now().microsecondsSinceEpoch}${++_sequence}';
    final task = _FeedPlaybackWarmup(
      identity: identity,
      dramaIdentity: dramaIdentity,
      requestKey: requestKey,
    );
    _pending[identity] = task;
    _queue = _queue
        .catchError((Object _) {})
        .then((_) => _run(task, drama, episode, quality, online));
  }

  Future<void> _run(
    _FeedPlaybackWarmup task,
    Drama drama,
    Episode episode,
    int quality,
    bool online,
  ) async {
    if (_closed ||
        !_targetDramas.contains(task.dramaIdentity) ||
        !identical(_pending[task.identity], task)) {
      _finish(task);
      return;
    }
    PlaybackPlan? plan;
    try {
      plan = await repository.preload(
        drama,
        episode,
        quality: quality,
        online: online,
        requestKey: task.requestKey,
      );
      if (plan == null || plan.url.isEmpty || !_keep(task)) {
        if (plan != null) _release(plan);
        return;
      }
      var expiresAt = _now().add(const Duration(minutes: 2));
      if (plan.expiresAt > 0) {
        final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
          plan.expiresAt,
        ).subtract(const Duration(seconds: 5));
        if (authorizationExpiry.isBefore(expiresAt)) {
          expiresAt = authorizationExpiry;
        }
      }
      if (!expiresAt.isAfter(_now())) {
        _release(plan);
        return;
      }
      _ready[task.identity] = _FeedPreparedPlayback(plan, expiresAt);
    } catch (_) {
      if (plan != null) _release(plan);
    } finally {
      _finish(task);
    }
  }

  bool _keep(_FeedPlaybackWarmup task) =>
      !_closed &&
      _targetDramas.contains(task.dramaIdentity) &&
      identical(_pending[task.identity], task);

  void _finish(_FeedPlaybackWarmup task) {
    if (identical(_pending[task.identity], task)) {
      _pending.remove(task.identity);
    }
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final identity = _planIdentity(drama, episode, quality, online);
    final prepared = _ready.remove(identity);
    if (prepared == null) return null;
    if (!_now().isBefore(prepared.expiresAt)) {
      _release(prepared.plan);
      return null;
    }
    return prepared.plan;
  }

  void clear() => retainDramas(const {});

  void _release(PlaybackPlan plan) =>
      unawaited(repository.release(plan.session).catchError((Object _) {}));

  void dispose() {
    if (_closed) return;
    _closed = true;
    _targetDramas.clear();
    for (final task in _pending.values) {
      unawaited(
        repository
            .cancelPreload(requestKey: task.requestKey)
            .catchError((Object _) {}),
      );
    }
    _pending.clear();
    for (final prepared in _ready.values) {
      _release(prepared.plan);
    }
    _ready.clear();
  }
}

class _FeedPreparedPlayback {
  const _FeedPreparedPlayback(this.plan, this.expiresAt);

  final PlaybackPlan plan;
  final DateTime expiresAt;
}

class _FeedPlaybackWarmup {
  const _FeedPlaybackWarmup({
    required this.identity,
    required this.dramaIdentity,
    required this.requestKey,
  });

  final String identity;
  final String dramaIdentity;
  final String requestKey;
}
