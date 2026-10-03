import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'catalog_browser.dart';
import 'core_bridge.dart';
import 'detail_screen.dart';
import 'douyin_creator_screen.dart';
import 'douyin_comments_sheet.dart';
import 'douyin_author_panel.dart';
import 'app_haptics.dart';
import 'feed_preferences.dart';
import 'feed_recommendations.dart';
import 'home_feed_preferences_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'player_screen.dart';
import 'playback_preloader.dart';
import 'widgets.dart';

typedef _FeedBatch = ({
  List<Drama> items,
  List<WatchEntry> history,
  List<Drama> favorites,
  List<FeedWatchSignal> session,
  Map<String, int> exposures,
  List<Drama> recent,
  Set<String> known,
  Set<String> unavailable,
  Set<String> allowed,
  Set<String> requestSelected,
  Map<String, FeedCategoryFilter> filters,
  Set<String> excluded,
  Map<String, int> weights,
  int seed,
  bool random,
});

List<Drama> _prepareFeedBatch(_FeedBatch batch) {
  String identity(Drama drama) => '${drama.source}:${drama.id}';
  String title(Drama drama) => drama.title.toLowerCase().replaceAll(
    RegExp(r'[\s·•_\-—:：，,。.!！?？()（）\[\]【】]'),
    '',
  );
  final recentIds = batch.recent.map(identity).toSet();
  final recentTitles = batch.recent
      .map(title)
      .where((value) => value.isNotEmpty)
      .toSet();
  final seen = {...batch.known};
  final candidates = <Drama>[];
  for (final drama in batch.items) {
    final id = identity(drama);
    if (!batch.allowed.contains(drama.source) ||
        batch.unavailable.contains(id) ||
        recentIds.contains(id) ||
        recentTitles.contains(title(drama)) ||
        !seen.add(id))
      continue;
    if (batch.filters[drama.source]?.allows(
          drama,
          selectedByRequest: batch.requestSelected.contains(drama.source),
        ) !=
        true)
      continue;
    candidates.add(drama);
  }
  return FeedRecommendations.rank(
    candidates: candidates,
    history: batch.history,
    favorites: batch.favorites,
    session: batch.session,
    exposures: batch.exposures,
    recent: batch.recent.reversed.take(24),
    randomSeed: batch.seed,
    excluded: batch.excluded,
    manualWeights: batch.weights,
    randomMode: batch.random,
  );
}

const _hongguoFeedCategoryIds = ['short_play', 'comic_series', 'ai_series'];
const _hongguoFeedCategoryNames = {
  'short_play': '真人剧',
  'comic_series': '漫剧',
  'ai_series': 'AI剧',
};
const _maxEmptyFeedBatchAttempts = 8;

class _ShortDramaPageControls {
  const _ShortDramaPageControls({
    required this.identity,
    required this.episodes,
    required this.episodeNumbers,
    required this.onSelectEpisodes,
  });

  final String identity;
  final ValueListenable<int> episodes;
  final List<int> episodeNumbers;
  final VoidCallback onSelectEpisodes;
}

typedef _TakeFeedPlaybackPlan =
    PlaybackPlan? Function(Drama drama, Episode episode, int quality);

class ShortDramaFeedScreen extends StatefulWidget {
  const ShortDramaFeedScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.active,
    required this.onBack,
    required this.onCleanModeChanged,
    required this.navigationInset,
    required this.initialBatchCursor,
    required this.onBatchCursorChanged,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool active;
  final VoidCallback onBack;
  final ValueChanged<bool> onCleanModeChanged;
  final double navigationInset;
  final int initialBatchCursor;
  final ValueChanged<int> onBatchCursorChanged;

  @override
  State<ShortDramaFeedScreen> createState() => _ShortDramaFeedScreenState();
}

class _ShortDramaFeedScreenState extends State<ShortDramaFeedScreen> {
  final _pages = PageController();
  final _feedActive = ValueNotifier<bool>(false);
  final _exposures = <String, int>{};
  final _viewed = <Drama>[];
  final _unavailableThisSession = <String>{};
  final Map<String, Future<DramaDetail>> _detailPrefetches = {};
  late final FeedPlaybackPreloader _playbackPreloader;
  late CatalogBrowser _browser;
  List<Drama> _items = [];
  int _index = 0;
  int _generation = 0;
  int _seed = DateTime.now().microsecondsSinceEpoch;
  late int _refreshBatchCursor;
  int _emptyBatchAttempts = 0;
  int _refreshGeneration = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _awaitingFirstPlayback = true;
  bool _hasMore = true;
  int _consecutiveUnavailable = 0;
  String? _error;
  final Set<String> _feedWarnings = {};
  final Set<int> _loadedBatches = {};
  final Map<int, bool> _batchHasMore = {};
  DateTime _pageStarted = DateTime.now();
  String _feedSignature = '';
  Object? _rulesKey;
  Future<void> _acceptTail = Future<void>.value();
  String _candidateSignature = '';
  int _profileEpoch = -1;
  int _homeQuality = 0;
  bool _lowMemory = false;
  int get _playerRadius => _lowMemory ? 0 : 2;
  int get _prefetchRadius => _lowMemory ? 0 : 2;
  int _exposureHistoryRevision = -1;
  _ShortDramaPageControls? _pageControls;
  bool _cleanScreen = false;
  bool _detailOpening = false;

  List<SourceSite> get _feedSources => widget.store.sources.where((source) {
    final preference = widget.store.homeFeedPreferences[source.id];
    return source.id != SourceSite.stripchat.id &&
        preference?.enabled == true &&
        preference!.categories.isNotEmpty &&
        _selectedRequestCategories(
          source,
          widget.store.homeFeedPreferences,
        ).categoryIds.isNotEmpty;
  }).toList();

  List<List<({SourceSite source, String categoryId})>> get _categoryBatches {
    final preferences = widget.store.homeFeedPreferences;
    final selected = [
      for (final source in _feedSources)
        _selectedRequestCategories(source, preferences),
    ];
    final count = selected.fold<int>(
      0,
      (current, entry) => current > entry.categoryIds.length
          ? current
          : entry.categoryIds.length,
    );
    return [
      for (var index = 0; index < count; index++)
        [
          for (final entry in selected)
            if (index < entry.categoryIds.length)
              (source: entry.source, categoryId: entry.categoryIds[index]),
        ],
    ];
  }

  ({SourceSite source, List<String> categoryIds}) _selectedRequestCategories(
    SourceSite source,
    Map<String, HomeFeedSourcePreference> preferences,
  ) {
    final selected = preferences[source.id]!.categories.keys.toSet();
    final requests = <String>{
      for (final category in selected)
        if (!category.startsWith('tag:')) category,
      if (source.id == SourceSite.hongguo.id &&
          selected.any((category) => category.startsWith('tag:')))
        ..._hongguoFeedCategoryIds.where(selected.contains),
    }.toList()..sort();
    return (source: source, categoryIds: requests);
  }

  String get _currentCandidateSignature {
    final preferences = widget.store.homeFeedPreferences.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return '${widget.store.profileEpoch}|'
        '${widget.store.feedExposureRevision}|'
        '${widget.store.sources.map((source) => source.id).join(',')}|'
        '${preferences.map((entry) => '${entry.key}:${entry.value.enabled}:${(entry.value.categories.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((category) => '${category.key}=${category.value}').join(',')}').join(';')}';
  }

  String get _currentFeedSignature {
    final recommendation = widget.store.feedRecommendationPreferences;
    final recommendationWeights = recommendation.manualWeights.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return '$_currentCandidateSignature|'
        '${recommendation.randomMode}|'
        '${jsonEncode({for (final entry in recommendationWeights) entry.key: entry.value})}';
  }

  bool _hasMoreBatches(int count) =>
      _loadedBatches.length < count ||
      _batchHasMore.values.any((value) => value);

  @override
  void initState() {
    super.initState();
    _feedActive.value = widget.active;
    _refreshBatchCursor = widget.initialBatchCursor;
    _viewed.addAll(widget.store.feedExposureHistory);
    _exposureHistoryRevision = widget.store.feedExposureRevision;
    _playbackPreloader = FeedPlaybackPreloader(widget.repository);
    _browser = CatalogBrowser(widget.repository);
    _candidateSignature = _currentCandidateSignature;
    _feedSignature = _currentFeedSignature;
    _rulesKey = widget.store.feedRuleKey;
    _profileEpoch = widget.store.profileEpoch;
    _homeQuality = widget.store.playbackPreferences.homeQuality;
    _lowMemory = widget.store.playbackPreferences.lowMemory;
    widget.store.addListener(_storeChanged);
    _applySystemUi(false);
    unawaited(_load(rotate: true));
  }

  @override
  void didUpdateWidget(covariant ShortDramaFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _feedActive.value = widget.active;
      if (!widget.active) _playbackPreloader.clear();
      if (widget.active) _primeNearbyDetails();
      if (!widget.active) {
        _applySystemUi(false);
      } else if (_cleanScreen) {
        _applySystemUi(true);
      }
    }
  }

  void _applySystemUi(bool immersive) {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  @override
  void dispose() {
    _recordLeaving(_index);
    _generation++;
    widget.store.removeListener(_storeChanged);
    _applySystemUi(false);
    _pages.dispose();
    _feedActive.dispose();
    _playbackPreloader.dispose();
    unawaited(_browser.cancel());
    super.dispose();
  }

  void _storeChanged() {
    final lowMemory = widget.store.playbackPreferences.lowMemory;
    if (lowMemory != _lowMemory && mounted) {
      setState(() => _lowMemory = lowMemory);
      _playbackPreloader.clear();
      _primeNearbyDetails();
    }
    final homeQuality = widget.store.playbackPreferences.homeQuality;
    if (homeQuality != _homeQuality) {
      _homeQuality = homeQuality;
      _playbackPreloader.clear();
    }
    final rulesKey = widget.store.feedRuleKey;
    if (rulesKey == _rulesKey || !mounted) return;
    _rulesKey = rulesKey;
    final signature = _currentFeedSignature;
    if (signature == _feedSignature || !mounted) return;
    final candidateSignature = _currentCandidateSignature;
    if (candidateSignature == _candidateSignature) {
      _feedSignature = signature;
      _seed = DateTime.now().microsecondsSinceEpoch;
      setState(_rerankBeyondStableQueueWindow);
      _primeNearbyDetails();
      if (_items.length <= _index + 1 && _hasMore) {
        unawaited(_load(more: _items.isNotEmpty, rotate: true));
      }
      return;
    }
    final profileChanged = _profileEpoch != widget.store.profileEpoch;
    final exposureHistoryCleared =
        _exposureHistoryRevision != widget.store.feedExposureRevision;
    _profileEpoch = widget.store.profileEpoch;
    _exposureHistoryRevision = widget.store.feedExposureRevision;
    _candidateSignature = candidateSignature;
    _generation++;
    _feedSignature = signature;
    _items = [];
    _index = 0;
    _awaitingFirstPlayback = true;
    if (profileChanged || exposureHistoryCleared) {
      _viewed
        ..clear()
        ..addAll(widget.store.feedExposureHistory);
      _exposures.clear();
    }
    if (profileChanged) {
      _unavailableThisSession.clear();
    }
    _detailPrefetches.clear();
    _playbackPreloader.clear();
    _pageControls = null;
    _loading = false;
    _loadingMore = false;
    _hasMore = true;
    _error = null;
    _feedWarnings.clear();
    _emptyBatchAttempts = 0;
    _consecutiveUnavailable = 0;
    _loadedBatches.clear();
    _batchHasMore.clear();
    _seed = DateTime.now().microsecondsSinceEpoch;
    unawaited(_browser.cancel());
    if (_pages.hasClients) _pages.jumpToPage(0);
    setState(() {});
    unawaited(_load(rotate: true));
  }

  Future<void> _accept(
    CatalogPage page, {
    required bool hasMore,
    Map<String, String> requestedCategories = const {},
    String? warning,
  }) {
    final generation = _generation;
    final next = _acceptTail
        .catchError((Object _) {})
        .then(
          (_) => _processPage(
            page,
            hasMore: hasMore,
            requestedCategories: requestedCategories,
            warning: warning,
            generation: generation,
          ),
        );
    _acceptTail = next;
    return next;
  }

  Future<void> _processPage(
    CatalogPage page, {
    required bool hasMore,
    required Map<String, String> requestedCategories,
    required String? warning,
    required int generation,
  }) async {
    if (!mounted || generation != _generation) return;
    final ruleKey = widget.store.feedRuleKey;
    final preferences = widget.store.homeFeedPreferences;
    final recommendation = widget.store.feedRecommendationPreferences;
    final filters = {
      for (final entry in preferences.entries)
        if (entry.value.enabled && entry.value.categories.isNotEmpty)
          entry.key: FeedCategoryFilter(entry.value.categories.values, {
            if (entry.key != SourceSite.bilibili.id)
              ...entry.value.excludedCategories.values,
            if (entry.key == SourceSite.hongguo.id)
              for (final category in _hongguoFeedCategoryNames.entries)
                if (!entry.value.categories.containsKey(category.key))
                  category.value,
          }),
    };
    final ranked = await compute(_prepareFeedBatch, (
      items: page.items,
      history: widget.store.history,
      favorites: widget.store.favorites,
      session: widget.store.feedSessionSignals,
      exposures: Map<String, int>.of(_exposures),
      recent: List<Drama>.of(_viewed),
      known: _items.map(_identity).toSet(),
      unavailable: {
        ...widget.store.unavailableFeedDramas,
        ..._unavailableThisSession,
      },
      allowed: widget.store.sources
          .map((source) => source.id)
          .where((source) => source != SourceSite.stripchat.id)
          .toSet(),
      requestSelected: {
        for (final entry in requestedCategories.entries)
          if (preferences[entry.key]?.categories.containsKey(entry.value) ==
              true)
            entry.key,
      },
      filters: filters,
      excluded: widget.store.feedNotInterested,
      weights: recommendation.manualWeights,
      seed: _seed,
      random: recommendation.randomMode,
    ));
    if (!mounted || generation != _generation) return;
    if (ruleKey != widget.store.feedRuleKey) {
      await _processPage(
        page,
        hasMore: hasMore,
        requestedCategories: requestedCategories,
        warning: warning,
        generation: generation,
      );
      return;
    }
    if (warning != null && warning.isNotEmpty) _feedWarnings.add(warning);
    if (page.warning.isNotEmpty) _feedWarnings.add(page.warning);
    final known = _items.map(_identity).toSet();
    final accepted = ranked
        .where(
          (drama) =>
              !known.contains(_identity(drama)) &&
              !_unavailableThisSession.contains(_identity(drama)),
        )
        .toList();
    setState(() {
      _items = [..._items, ...accepted];
      _hasMore = hasMore;
      _error = _feedWarnings.isEmpty ? null : _feedWarnings.take(3).join('；');
    });
    _primeNearbyDetails();
    if (accepted.isNotEmpty) _emptyBatchAttempts = 0;
    if (_items.isNotEmpty &&
        !_exposures.containsKey(_identity(_items[_index]))) {
      _recordExposure(_index);
    }
  }

  Future<void> _load({
    bool more = false,
    bool force = false,
    bool rotate = false,
  }) async {
    if (_loading || _loadingMore || more && !_hasMore) return;
    final generation = ++_generation;
    final batches = _categoryBatches;
    if (batches.isEmpty) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        _items = [];
        _hasMore = false;
        _error =
            '请在“设置 → 播放设置 → 首页偏好”开启站源并选择可请求的短剧分类。红果细分类只在已开启的真人剧、漫剧或AI剧中生效。';
      });
      return;
    }
    _refreshBatchCursor %= batches.length;
    widget.onBatchCursorChanged(_refreshBatchCursor);
    if (!more || force) {
      _loadedBatches.clear();
      _batchHasMore.clear();
    }
    final unrequested = [
      for (var index = 0; index < batches.length; index++)
        if (!_loadedBatches.contains(index)) index,
    ];
    final available = [
      for (var index = 0; index < batches.length; index++)
        if (_batchHasMore[index] == true) index,
    ];
    int nextRefreshBatch(List<int> candidates) {
      final ordered = [...candidates]..sort();
      final selected = ordered.firstWhere(
        (index) => index >= _refreshBatchCursor,
        orElse: () => ordered.first,
      );
      _refreshBatchCursor = (selected + 1) % batches.length;
      widget.onBatchCursorChanged(_refreshBatchCursor);
      return selected;
    }

    List<int> rotatingRefreshBatches() {
      final selected = <int>[];
      final count = math.min(2, unrequested.length);
      while (selected.length < count) {
        selected.add(
          nextRefreshBatch(
            unrequested.where((index) => !selected.contains(index)).toList(),
          ),
        );
      }
      return selected;
    }

    final batchIndices = more
        ? unrequested.isNotEmpty
              ? [rotate ? nextRefreshBatch(unrequested) : unrequested.first]
              : rotate
              ? available.isEmpty
                    ? <int>[]
                    : [nextRefreshBatch(available)]
              : available
        : rotate
        ? rotatingRefreshBatches()
        : [
            for (var index = 0; index < math.min(2, batches.length); index++)
              index,
          ];
    if (batchIndices.isEmpty) {
      setState(() {
        _hasMore = false;
        _loading = false;
        _loadingMore = false;
        if (_items.isEmpty) {
          _error = _viewed.isEmpty
              ? '暂时没有可播放的内容，请稍后刷新再试。'
              : '最近推荐内容已看完。可在“设置 → 播放设置 → 猜你喜欢”清除首页去重记录后重新推荐。';
        }
      });
      if (_items.isNotEmpty && !_exposures.containsKey(_identity(_items[0]))) {
        _recordExposure(0);
      }
      return;
    }
    setState(() {
      _loading = !more;
      _loadingMore = more;
      if (!more && force) {
        _items = [];
        _detailPrefetches.clear();
      }
    });
    for (final index in batchIndices) {
      if (!mounted || generation != _generation) return;
      final batch = batches[index];
      final group = SourceGroup('feed-$index', '首页偏好', [
        for (final entry in batch) entry.source,
      ]);
      final requests = {
        for (final entry in batch) entry.source.id: entry.categoryId,
      };
      final requestMore = _loadedBatches.contains(index);
      try {
        final page = await _browser.load(
          group,
          more: requestMore,
          useCache: !requestMore,
          staleWhileRefreshing: force && !requestMore,
          force: force,
          categoryRequests: requests,
          onCached: (cached) {
            if (generation == _generation && mounted) {
              _batchHasMore[index] = cached.hasMore;
              unawaited(
                _accept(
                  cached,
                  hasMore: _hasMoreBatches(batches.length),
                  requestedCategories: requests,
                ).catchError((Object _) {}),
              );
            }
          },
        );
        if (!mounted || generation != _generation) return;
        _loadedBatches.add(index);
        _batchHasMore[index] = page.hasMore;
        await _accept(
          page,
          hasMore: _hasMoreBatches(batches.length),
          requestedCategories: requests,
        );
      } catch (error) {
        if (!mounted || generation != _generation) return;
        _feedWarnings.add(error.toString());
        _loadedBatches.add(index);
        _batchHasMore[index] = false;
      }
    }
    if (!mounted || generation != _generation) return;
    if (!more && !rotate && batchIndices.isNotEmpty) {
      _refreshBatchCursor = (batchIndices.last + 1) % batches.length;
    }
    if (_items.isEmpty) {
      _emptyBatchAttempts += batchIndices.length;
    } else {
      _emptyBatchAttempts = 0;
    }
    final hasMore = _hasMoreBatches(batches.length);
    setState(() {
      _loading = false;
      _loadingMore = false;
      _hasMore = hasMore;
      _error = _feedWarnings.isNotEmpty
          ? _feedWarnings.take(3).join('；')
          : _items.isEmpty && _emptyBatchAttempts >= _maxEmptyFeedBatchAttempts
          ? _viewed.isEmpty
                ? '已检查多个目录批次，暂时没有可播放内容。点击刷新重新尝试。'
                : '当前没有新的推荐内容。可在“设置 → 播放设置 → 猜你喜欢”清除首页去重记录后重新推荐。'
          : null;
    });
    if (_items.isNotEmpty && _items.length - _index <= 3 && hasMore) {
      unawaited(_load(more: true));
    } else if (_items.isEmpty &&
        hasMore &&
        _consecutiveUnavailable < 20 &&
        _emptyBatchAttempts < _maxEmptyFeedBatchAttempts) {
      unawaited(_load(more: true, rotate: true));
    } else if (_items.isEmpty && _consecutiveUnavailable >= 20) {
      setState(() {
        _error = '已跳过 20 部暂不可用内容，点击刷新继续加载。';
      });
    }
  }

  String _identity(Drama drama) => '${drama.source}:${drama.id}';

  String _normalizeTitle(String title) => title.toLowerCase().replaceAll(
    RegExp(r'[\s·•_\-—:：，,。.!！?？()（）\[\]【】]'),
    '',
  );

  void _skipUnavailable(Drama drama) {
    final identity = _identity(drama);
    if (!mounted) return;
    if (_unavailableThisSession.add(identity)) {
      unawaited(
        widget.store.markFeedDramaUnavailable(identity).catchError((_) {}),
      );
    }
    final failedIndex = _items.indexWhere(
      (item) => _identity(item) == identity,
    );
    if (failedIndex < 0) return;
    final skippedCurrent = failedIndex == _index;
    _consecutiveUnavailable++;
    _items.removeAt(failedIndex);
    _exposures.remove(identity);
    _detailPrefetches.remove(identity);
    _viewed.removeWhere((item) => _identity(item) == identity);
    widget.store.removeFeedSignalsForDrama(drama);
    if (failedIndex < _index) _index--;
    if (_items.isEmpty) _index = 0;
    if (skippedCurrent) _pageStarted = DateTime.now();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pages.hasClients && _items.isNotEmpty) {
        _pages.jumpToPage(_index);
      }
      _primeNearbyDetails();
      if (skippedCurrent && _items.isNotEmpty) _recordExposure(_index);
      if (_consecutiveUnavailable >= 20 && _items.isEmpty) {
        setState(() {
          _error = '已跳过 20 部暂不可用内容，点击刷新继续加载。';
        });
      } else if (_items.length - _index <= 3 && _hasMore) {
        unawaited(_load(more: true));
      }
    });
  }

  void _markAvailable(Drama drama) {
    if (!mounted ||
        _index >= _items.length ||
        _identity(_items[_index]) != _identity(drama) ||
        !_awaitingFirstPlayback && _consecutiveUnavailable == 0) {
      return;
    }
    setState(() {
      _awaitingFirstPlayback = false;
      _consecutiveUnavailable = 0;
      _error = null;
    });
  }

  void _recordExposure(int index) {
    if (index < 0 || index >= _items.length) return;
    final drama = _items[index];
    final id = _identity(drama);
    _exposures.update(id, (value) => value + 1, ifAbsent: () => 1);
    _viewed.add(drama);
    if (_viewed.length > 30) _viewed.removeAt(0);
    unawaited(
      widget.store.rememberFeedExposure(drama).catchError((Object _) {}),
    );
  }

  void _recordLeaving(int index) {
    if (index < 0 || index >= _items.length) return;
    final drama = _items[index];
    final elapsed = DateTime.now().difference(_pageStarted).inSeconds;
    final watch = widget.store.watched(drama.id);
    var value = elapsed < 3
        ? -1.2
        : elapsed >= 30
        ? .3
        : .05;
    if (watch != null &&
        watch.duration > 0 &&
        watch.updatedAt.isAfter(_pageStarted)) {
      final ratio = (watch.position / watch.duration).clamp(0, 1);
      value = switch (ratio) {
        < .05 => -1.2,
        < .20 => -.7,
        < .50 => -.2,
        < .80 => .45,
        _ => .85,
      };
      if (ratio >= .98) value += .45;
      if (watch.episode >= 3) value += .6;
      if (watch.episode >= 5) value += .9;
    }
    widget.store.recordFeedWatchSignal(
      FeedWatchSignal(drama: drama, value: value),
    );
  }

  Future<DramaDetail> _detailFutureFor(Drama drama) {
    final identity = _identity(drama);
    return _detailPrefetches.putIfAbsent(identity, () {
      final future = widget.repository.detail(drama);
      unawaited(
        future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      return future;
    });
  }

  void _primeNearbyDetails() {
    if (_items.isEmpty || !widget.active || !_feedActive.value) return;
    final first = math.max(0, _index - _playerRadius);
    final last = math.min(_items.length - 1, _index + _prefetchRadius);
    final upcoming = [
      for (
        var index = _index + 1;
        index <= math.min(_items.length - 1, _index + _prefetchRadius);
        index++
      )
        index,
    ];
    final identities = {
      for (var index = first; index <= last; index++) _identity(_items[index]),
    };
    _playbackPreloader.retainDramas({
      for (
        var index = _index;
        index <= math.min(_items.length - 1, _index + _prefetchRadius);
        index++
      )
        _identity(_items[index]),
    });
    _detailPrefetches.removeWhere(
      (identity, _) => !identities.contains(identity),
    );
    for (var index = first; index <= last; index++) {
      _detailFutureFor(_items[index]);
    }
    if (upcoming.isNotEmpty) {
      unawaited(
        _warmUpcomingPlayback(upcoming.first).then((_) async {
          if (upcoming.length > 1) {
            await _warmUpcomingPlayback(upcoming[1]);
          }
        }),
      );
    }
  }

  Future<void> _warmUpcomingPlayback(int index) async {
    if (index <= _index ||
        index > _index + _prefetchRadius ||
        index >= _items.length)
      return;
    final drama = _items[index];
    final DramaDetail detail;
    try {
      detail = await _detailFutureFor(drama);
    } catch (_) {
      return;
    }
    if (!mounted ||
        !widget.active ||
        !_feedActive.value ||
        index <= _index ||
        index > _index + _prefetchRadius ||
        index >= _items.length ||
        _identity(_items[index]) != _identity(drama) ||
        detail.episodes.isEmpty) {
      return;
    }
    final watch = widget.store.watched(drama.id);
    final episodeIndex = watch == null || watch.finished
        ? -1
        : detail.episodes.indexWhere(
            (episode) => episode.number == watch.episode,
          );
    _playbackPreloader.prepare(
      drama,
      detail.episodes[episodeIndex < 0 ? 0 : episodeIndex],
      quality: widget.store.playbackPreferences.homeQuality,
    );
  }

  void _onPageChanged(int index) {
    _recordLeaving(_index);
    setState(() {
      _index = index;
      _pageStarted = DateTime.now();
      _pageControls = null;
      _rerankBeyondStableQueueWindow();
    });
    _primeNearbyDetails();
    _recordExposure(index);
    if (_items.length - index <= 3 && _hasMore) unawaited(_load(more: true));
  }

  void _like(Drama drama, bool liked) {
    widget.store.setFeedLikeSignal(drama, liked: liked);
    if (mounted) {
      setState(_rerankBeyondStableQueueWindow);
      _primeNearbyDetails();
    }
  }

  void _follow(Drama drama) {
    unawaited(
      widget.store.toggleFavorite(drama).then((_) {
        if (mounted) {
          setState(_rerankBeyondStableQueueWindow);
          _primeNearbyDetails();
        }
      }),
    );
  }

  void _rerankBeyondStableQueueWindow() {
    final first = math.min(_items.length, _index + 6);
    if (_items.length <= first) return;
    final count = (_items.length - first).clamp(0, 60).toInt();
    final end = first + count;
    final prefix = _items.take(first).toList();
    final pending = _items.skip(first).take(count).toList();
    final preferences = widget.store.feedRecommendationPreferences;
    final ranked = FeedRecommendations.rank(
      candidates: pending,
      history: widget.store.history,
      favorites: widget.store.favorites,
      session: widget.store.feedSessionSignals,
      exposures: _exposures,
      recent: _viewed.reversed.take(24),
      randomSeed: _seed,
      excluded: widget.store.feedNotInterested,
      manualWeights: preferences.manualWeights,
      randomMode: preferences.randomMode,
    );
    _items = [...prefix, ...ranked, ..._items.skip(end)];
  }

  Future<void> _notInterested(Drama drama) async {
    await widget.store.setFeedNotInterested(_identity(drama), true);
    if (!mounted) return;
    widget.store.recordFeedWatchSignal(
      FeedWatchSignal(drama: drama, value: -1.5),
    );
    setState(_rerankBeyondStableQueueWindow);
    if (_index + 1 < _items.length) {
      await _pages.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else if (_hasMore) {
      unawaited(_load(more: true));
    }
  }

  Future<void> _openDetail(Drama drama) async {
    if (!mounted || _detailOpening) return;
    _detailOpening = true;
    _feedActive.value = false;
    _applySystemUi(false);
    try {
      await Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (_, _, _) =>
              SourceSite.byId(drama.source).supportsCreator
              ? DouyinCreatorScreen(
                  drama: drama,
                  repository: widget.repository,
                  store: widget.store,
                )
              : DetailScreen(
                  drama: drama,
                  repository: widget.repository,
                  store: widget.store,
                ),
          transitionsBuilder: (_, animation, secondaryAnimation, child) {
            final incoming = animation.drive(
              Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeOutCubic)),
            );
            final outgoing = secondaryAnimation.drive(
              Tween<Offset>(
                begin: Offset.zero,
                end: const Offset(-.22, 0),
              ).chain(CurveTween(curve: Curves.easeInOutCubic)),
            );
            return SlideTransition(
              position: outgoing,
              child: SlideTransition(position: incoming, child: child),
            );
          },
        ),
      );
    } finally {
      if (mounted) {
        _applySystemUi(_cleanScreen);
        _feedActive.value = widget.active;
        _detailOpening = false;
      }
    }
  }

  void _setCleanScreen(bool enabled) {
    if (!mounted || _cleanScreen == enabled) return;
    setState(() => _cleanScreen = enabled);
    _applySystemUi(enabled);
    widget.onCleanModeChanged(enabled);
  }

  Future<void> _refresh() async {
    final refreshGeneration = ++_refreshGeneration;
    _generation++;
    await _browser.cancel();
    if (!mounted || refreshGeneration != _refreshGeneration) return;
    _items = [];
    _index = 0;
    _awaitingFirstPlayback = true;
    _playbackPreloader.clear();
    _pageControls = null;
    _pageStarted = DateTime.now();
    _hasMore = true;
    _loading = false;
    _loadingMore = false;
    _consecutiveUnavailable = 0;
    _emptyBatchAttempts = 0;
    _feedWarnings.clear();
    _error = null;
    _loadedBatches.clear();
    _batchHasMore.clear();
    _seed = DateTime.now().microsecondsSinceEpoch;
    if (_pages.hasClients) _pages.jumpToPage(0);
    setState(() {});
    await _load(force: true, rotate: true);
  }

  Future<void> _openFeedPreferences() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HomeFeedPreferencesScreen(
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feedMaxWidth = MediaQuery.sizeOf(context).width > 560
        ? 520.0
        : double.infinity;
    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          if (!_cleanScreen) _topBar(feedMaxWidth),
          Expanded(child: _feedContent(feedMaxWidth)),
        ],
      ),
    );
  }

  Widget _topBar(double feedMaxWidth) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: feedMaxWidth),
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: _cleanScreen
                    ? const SizedBox.expand()
                    : Row(
                        children: [
                          Text(
                            '推荐',
                            style: TextStyle(
                              color: colors.onSurface,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          if (_items.isNotEmpty &&
                              {
                                'douyin',
                                'douyin-live',
                              }.contains(_items[_index].source))
                            const SizedBox.shrink()
                          else if (_pageControls case final controls?)
                            ValueListenableBuilder<int>(
                              valueListenable: controls.episodes,
                              builder: (context, index, _) => IconButton(
                                tooltip:
                                    '选集 · 第 ${controls.episodeNumbers[index.clamp(0, controls.episodeNumbers.length - 1)]} 集',
                                onPressed: controls.onSelectEpisodes,
                                color: colors.onSurface,
                                icon: const Icon(Icons.grid_view_rounded),
                              ),
                            )
                          else
                            IconButton(
                              tooltip: '选集',
                              onPressed: null,
                              icon: const Icon(Icons.grid_view_rounded),
                            ),
                          IconButton(
                            tooltip: '刷新推荐',
                            onPressed: _refresh,
                            color: colors.onSurface,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                          IconButton(
                            tooltip: '清屏',
                            onPressed: () => _setCleanScreen(true),
                            color: colors.onSurface,
                            icon: const Icon(Icons.visibility_off_rounded),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _pageControlsChanged(Drama drama, _ShortDramaPageControls? controls) {
    if (!mounted || _index >= _items.length) return;
    final identity = _identity(_items[_index]);
    if (identity != _identity(drama)) return;
    if (controls == null && _pageControls?.identity != identity) return;
    if (identical(_pageControls, controls)) return;
    setState(() => _pageControls = controls);
  }

  Widget _feedContent(double feedMaxWidth) {
    if (_items.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: _loading || _loadingMore
              ? const AppLoadingIndicator(color: Colors.white)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.live_tv_outlined,
                      color: Colors.white70,
                      size: 44,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _categoryBatches.isEmpty
                          ? '先选择首页推荐内容'
                          : _error == null
                          ? '暂时没有可播放内容'
                          : '推荐内容暂时不可用',
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 280,
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _categoryBatches.isEmpty
                          ? _openFeedPreferences
                          : _refresh,
                      icon: Icon(
                        _categoryBatches.isEmpty
                            ? Icons.tune_rounded
                            : Icons.refresh_rounded,
                      ),
                      label: Text(
                        _categoryBatches.isEmpty
                            ? '设置首页偏好'
                            : _loading || _loadingMore
                            ? '重新开始加载'
                            : '重新加载',
                      ),
                    ),
                  ],
                ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pages,
          scrollDirection: Axis.vertical,
          allowImplicitScrolling: !_lowMemory,
          itemCount: _items.length,
          onPageChanged: _onPageChanged,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = _items.indexWhere(
              (drama) => _identity(drama) == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(_identity(_items[index])),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: feedMaxWidth),
                child: SizedBox.expand(
                  child: _ShortDramaPage(
                    drama: _items[index],
                    active: index == _index,
                    keepPlayerAlive:
                        !{
                          'douyin',
                          'douyin-live',
                        }.contains(_items[index].source) &&
                        (index - _index).abs() <= _playerRadius,
                    detailFuture: _detailFutureFor(_items[index]),
                    repository: widget.repository,
                    store: widget.store,
                    playbackActive: _feedActive,
                    cleanScreen: _cleanScreen,
                    onOpenDetail: _openDetail,
                    onPageControlsChanged: _pageControlsChanged,
                    onRestoreCleanScreen: () => _setCleanScreen(false),
                    onLike: _like,
                    onFollow: _follow,
                    onNotInterested: _notInterested,
                    takePlaybackPlan: (drama, episode, quality) =>
                        _playbackPreloader.take(
                          drama,
                          episode,
                          quality: quality,
                        ),
                    onUnavailable: _skipUnavailable,
                    onAvailable: _markAvailable,
                    onBack: widget.onBack,
                    navigationInset: widget.navigationInset,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_awaitingFirstPlayback)
          const Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black,
                child: Center(child: AppLoadingIndicator(color: Colors.white)),
              ),
            ),
          ),
      ],
    );
  }
}

class _ShortDramaPage extends StatefulWidget {
  const _ShortDramaPage({
    required this.drama,
    required this.active,
    required this.keepPlayerAlive,
    required this.detailFuture,
    required this.repository,
    required this.store,
    required this.playbackActive,
    required this.cleanScreen,
    required this.onOpenDetail,
    required this.onPageControlsChanged,
    required this.onRestoreCleanScreen,
    required this.onLike,
    required this.onFollow,
    required this.onNotInterested,
    required this.takePlaybackPlan,
    required this.onUnavailable,
    required this.onAvailable,
    required this.onBack,
    required this.navigationInset,
  });

  final Drama drama;
  final bool active;
  final bool keepPlayerAlive;
  final Future<DramaDetail> detailFuture;
  final AppRepository repository;
  final LocalStore store;
  final ValueListenable<bool> playbackActive;
  final bool cleanScreen;
  final ValueChanged<Drama> onOpenDetail;
  final void Function(Drama, _ShortDramaPageControls?) onPageControlsChanged;
  final VoidCallback onRestoreCleanScreen;
  final void Function(Drama, bool liked) onLike;
  final ValueChanged<Drama> onFollow;
  final ValueChanged<Drama> onNotInterested;
  final _TakeFeedPlaybackPlan takePlaybackPlan;
  final ValueChanged<Drama> onUnavailable;
  final ValueChanged<Drama> onAvailable;
  final VoidCallback onBack;
  final double navigationInset;

  @override
  State<_ShortDramaPage> createState() => _ShortDramaPageState();
}

class _ShortDramaPageState extends State<_ShortDramaPage>
    with AutomaticKeepAliveClientMixin<_ShortDramaPage> {
  late Future<DramaDetail> _detail;
  late final ValueNotifier<bool> _pageActive;
  bool _playerCreated = false;
  final _episode = ValueNotifier<int>(0);
  bool _liked = false;
  bool _commentsOpen = false;
  bool _progressRestored = false;
  bool _startupPlanTaken = false;
  PlaybackPlan? _startupPlaybackPlan;
  bool _showLike = false;
  int _likeAnimation = 0;
  Timer? _likeTimer;
  bool _unavailabilityReported = false;
  bool _availabilityReported = false;
  DramaDetail? _controlsDetail;
  _ShortDramaPageControls? _controls;

  @override
  bool get wantKeepAlive => widget.active || widget.keepPlayerAlive;

  @override
  void initState() {
    super.initState();
    _pageActive = ValueNotifier(widget.active);
    _playerCreated = widget.active;
    _detail = widget.detailFuture;
  }

  @override
  void didUpdateWidget(_ShortDramaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _pageActive.value = widget.active;
      if (widget.active) {
        _playerCreated = true;
      } else if ({'douyin', 'douyin-live'}.contains(widget.drama.source)) {
        _playerCreated = false;
      }
    }
    if (oldWidget.active != widget.active ||
        oldWidget.keepPlayerAlive != widget.keepPlayerAlive) {
      updateKeepAlive();
    }
    if (oldWidget.active && !widget.active) {
      widget.onPageControlsChanged(widget.drama, null);
    }
    if (oldWidget.detailFuture != widget.detailFuture) {
      _detail = widget.detailFuture;
    }
    if (oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.source != widget.drama.source) {
      _detail = widget.repository.detail(widget.drama);
      _episode.value = 0;
      _unavailabilityReported = false;
      _availabilityReported = false;
      _controlsDetail = null;
      _controls = null;
    }
  }

  @override
  void dispose() {
    _likeTimer?.cancel();
    _pageActive.dispose();
    _episode.dispose();
    super.dispose();
  }

  void _doubleTapLike() {
    if (!_liked) {
      _liked = true;
      widget.onLike(widget.drama, true);
    }
    _likeTimer?.cancel();
    setState(() {
      _showLike = true;
      _likeAnimation++;
    });
    _likeTimer = Timer(const Duration(milliseconds: 620), () {
      if (mounted) setState(() => _showLike = false);
    });
  }

  void _publishPageControls(DramaDetail detail) {
    if (!widget.active) return;
    if (!identical(_controlsDetail, detail)) {
      _controlsDetail = detail;
      _controls = _ShortDramaPageControls(
        identity: _identity(widget.drama),
        episodes: _episode,
        episodeNumbers: [for (final episode in detail.episodes) episode.number],
        onSelectEpisodes: () => _selectEpisode(detail),
      );
    }
    final controls = _controls;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && controls != null) {
        widget.onPageControlsChanged(widget.drama, controls);
      }
    });
  }

  void _restoreProgress(DramaDetail detail) {
    if (_progressRestored) return;
    _progressRestored = true;
    final watch = widget.store.watched(widget.drama.id);
    if (watch == null || watch.finished) return;
    final index = detail.episodes.indexWhere(
      (episode) => episode.number == watch.episode,
    );
    if (index >= 0) _episode.value = index;
  }

  Future<void> _selectEpisode(DramaDetail detail) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: .62,
          minChildSize: .35,
          maxChildSize: .9,
          builder: (context, controller) => Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选集 · 共 ${detail.episodes.length} 集',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text(SourceSite.byId(widget.drama.source).name),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: detail.episodes.length,
                  itemBuilder: (context, index) => FilledButton.tonal(
                    onPressed: () => Navigator.pop(context, index),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${detail.episodes[index].number}',
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null && mounted) _episode.value = selected;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final drama = widget.drama;
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<DramaDetail>(
          future: _detail,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            if (detail != null && detail.episodes.isNotEmpty) {
              _restoreProgress(detail);
              if (!widget.active &&
                  ({'douyin', 'douyin-live'}.contains(widget.drama.source) ||
                      !_playerCreated)) {
                return _poster(
                  context,
                  loading: false,
                  failed: false,
                  hasEpisodes: true,
                  failureMessage: '',
                  onRetry: _retryDetail,
                );
              }
              if (widget.active) _publishPageControls(detail);
              return ValueListenableBuilder<int>(
                valueListenable: _episode,
                builder: (context, episode, _) {
                  final index = episode.clamp(0, detail.episodes.length - 1);
                  if (widget.active && !_startupPlanTaken) {
                    _startupPlanTaken = true;
                    _startupPlaybackPlan = widget.takePlaybackPlan(
                      drama,
                      detail.episodes[index],
                      widget.store.playbackPreferences.homeQuality,
                    );
                  }
                  final watch = widget.store.watched(drama.id);
                  final initialPosition =
                      watch != null &&
                          !watch.finished &&
                          detail.episodes[index].number == watch.episode
                      ? watch.position
                      : 0.0;
                  return PlayerScreen(
                    key: ValueKey('feed-player-${_identity(drama)}'),
                    detail: detail,
                    initialIndex: index,
                    initialPosition: initialPosition,
                    initialPlaybackPlan: _startupPlaybackPlan,
                    repository: widget.repository,
                    store: widget.store,
                    immersiveFeed: true,
                    hideFeedOverlays: widget.cleanScreen,
                    feedEpisode: _episode,
                    feedActive: widget.playbackActive,
                    feedPageActive: _pageActive,
                    onFeedBack: widget.onBack,
                    onFeedDoubleTap: _doubleTapLike,
                    onFeedPlaybackStarted: _reportAvailable,
                    onFeedPlaybackFailed: _reportUnavailable,
                  );
                },
              );
            }
            final unavailable =
                snapshot.connectionState == ConnectionState.done &&
                (snapshot.hasError ||
                    snapshot.data != null && detail!.episodes.isEmpty);
            if (unavailable) {
              if (widget.active) _reportUnavailable();
              return const ColoredBox(color: Colors.black);
            }
            return _poster(
              context,
              loading: snapshot.connectionState != ConnectionState.done,
              failed: snapshot.hasError,
              hasEpisodes: snapshot.data?.episodes.isNotEmpty == true,
              failureMessage: snapshot.error?.toString() ?? '',
              onRetry: _retryDetail,
            );
          },
        ),
        FutureBuilder<DramaDetail>(
          future: _detail,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            if (!widget.active || detail == null || detail.episodes.isEmpty) {
              return const SizedBox.shrink();
            }
            if (widget.cleanScreen) return const SizedBox.shrink();
            return _overlay(context, detail);
          },
        ),
        if (_showLike && !widget.cleanScreen)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_likeAnimation),
                  tween: Tween(begin: .55, end: 1.15),
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutBack,
                  builder: (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Icon(
                    Icons.favorite_rounded,
                    size: 104,
                    color: Colors.pinkAccent.withValues(alpha: .92),
                    shadows: const [
                      Shadow(color: Colors.black45, blurRadius: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (widget.cleanScreen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onRestoreCleanScreen,
            ),
          ),
      ],
    );
  }

  String _identity(Drama drama) => '${drama.source}:${drama.id}';

  void _reportUnavailable() {
    if (_unavailabilityReported) return;
    _unavailabilityReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onUnavailable(widget.drama);
    });
  }

  void _reportAvailable() {
    if (_availabilityReported) return;
    _availabilityReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onAvailable(widget.drama);
    });
  }

  void _retryDetail() {
    setState(() => _detail = widget.repository.refreshDetail(widget.drama));
  }

  Widget _poster(
    BuildContext context, {
    required bool loading,
    required bool failed,
    required bool hasEpisodes,
    required String failureMessage,
    required VoidCallback onRetry,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      ColoredBox(
        color: Colors.black,
        child: DramaCover(drama: widget.drama, repository: widget.repository),
      ),
      if (loading)
        const Center(child: AppLoadingIndicator(color: Colors.white))
      else if (failed)
        ColoredBox(
          color: Colors.black.withValues(alpha: .6),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('剧集详情暂时不可用', style: TextStyle(color: Colors.white)),
                if (failureMessage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      failureMessage,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新获取'),
                ),
              ],
            ),
          ),
        )
      else if (!hasEpisodes)
        ColoredBox(
          color: Color(0x99000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('源站未返回可播放分集', style: TextStyle(color: Colors.white)),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新获取'),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Future<void> _openComments(Drama drama) async {
    if (_commentsOpen) return;
    _commentsOpen = true;
    AppHaptics.light();
    try {
      await showDouyinComments(context, widget.repository, drama);
    } finally {
      _commentsOpen = false;
    }
  }

  Widget _overlay(BuildContext context, DramaDetail detail) => Stack(
    children: [
      Positioned(
        left: 16,
        right: 84,
        bottom: 27,
        child: SourceSite.byId(widget.drama.source).supportsCreator
            ? AnimatedBuilder(
                animation: widget.store,
                builder: (context, _) => DouyinAuthorPanel(
                  drama: detail.drama,
                  onOpen: () => widget.onOpenDetail(detail.drama),
                  followed: widget.store.isFavorite(widget.drama.id),
                  onFollow: () => widget.onFollow(widget.drama),
                ),
              )
            : Semantics(
                button: true,
                label: '查看${widget.drama.title}详情',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => AppHaptics.light(),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onOpenDetail(widget.drama),
                    onDoubleTap: _doubleTapLike,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.drama.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ValueListenableBuilder<int>(
                            valueListenable: _episode,
                            builder: (_, index, _) => Text(
                              '${widget.drama.category.isEmpty ? '短剧' : widget.drama.category} · 第 ${detail.episodes[index.clamp(0, detail.episodes.length - 1)].number} 集',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 8),
                                ],
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
      Positioned(
        right: 12,
        bottom: 34,
        child: AnimatedBuilder(
          animation: widget.store,
          builder: (context, _) => Column(
            children: [
              _FeedAction(
                icon: _liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: '喜欢',
                active: _liked,
                onTap: () {
                  final liked = !_liked;
                  setState(() => _liked = liked);
                  widget.onLike(widget.drama, liked);
                },
              ),
              const SizedBox(height: 20),
              if (!SourceSite.byId(widget.drama.source).supportsCreator)
                _FeedAction(
                  icon: widget.store.isFavorite(widget.drama.id)
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  label: '追剧',
                  active: widget.store.isFavorite(widget.drama.id),
                  onTap: () => widget.onFollow(widget.drama),
                ),
              if (!SourceSite.byId(widget.drama.source).supportsCreator)
                const SizedBox(height: 20),
              if ({'douyin', 'bilibili'}.contains(widget.drama.source))
                _FeedAction(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: '评论',
                  onTap: () => unawaited(_openComments(detail.drama)),
                ),
              if ({'douyin', 'bilibili'}.contains(widget.drama.source))
                const SizedBox(height: 20),
              _FeedAction(
                icon: Icons.not_interested_rounded,
                label: '不喜欢',
                onTap: () => widget.onNotInterested(widget.drama),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _FeedAction extends StatelessWidget {
  const _FeedAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 62,
    child: Column(
      children: [
        IconButton.filledTonal(
          onPressed: onTap,
          icon: Icon(icon, color: active ? Colors.pinkAccent : Colors.white),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: .46),
            fixedSize: const Size(50, 50),
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            shadows: [Shadow(color: Colors.black, blurRadius: 6)],
          ),
        ),
      ],
    ),
  );
}
