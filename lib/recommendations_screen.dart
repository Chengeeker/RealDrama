import 'dart:async';

import 'package:flutter/material.dart';

import 'catalog_filters.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'widgets.dart';

class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.selectedFormat = 'all',
    this.embedded = false,
    this.bottomPadding = 16,
  });
  final AppRepository repository;
  final LocalStore store;
  final String selectedFormat;
  final bool embedded;
  final double bottomPadding;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  static const _genres = [
    CatalogCategory('all', '全部内容形式'),
    CatalogCategory('live', '真人剧'),
    CatalogCategory('manga', '漫剧'),
    CatalogCategory('ai', 'AI 剧'),
  ];
  static const _apiGenres = {
    'live': 'short_play',
    'manga': 'comic_series',
    'ai': 'ai_series',
  };
  static const _allApiGenres = ['short_play', 'comic_series', 'ai_series'];
  final _scroll = ScrollController();
  String _genre = 'all';
  List<Drama> _items = [];
  bool _loading = false;
  bool _more = false;
  bool _hasMore = true;
  bool _failedMore = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _genre = widget.selectedFormat;
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant RecommendationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedFormat == widget.selectedFormat) return;
    _genre = widget.selectedFormat;
    _items = [];
    _hasMore = true;
    _error = null;
    _loading = true;
    _more = false;
    _scheduleLoad(resetScroll: true);
  }

  @override
  void dispose() {
    _generation++;
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    unawaited(widget.repository.cancelRecommendations());
    _scroll.dispose();
    super.dispose();
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null) return;
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    if (more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    final genre = _genre;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = more;
    });
    try {
      await widget.repository.cancelRecommendations();
      if (!mounted || generation != _generation) return;
      final requestedGenres = genre == 'all'
          ? _allApiGenres
          : [_apiGenres[genre] ?? _allApiGenres.first];
      final failures = <String>[];
      final pages = await Future.wait(
        requestedGenres.map((requestedGenre) async {
          try {
            return await widget.repository.recommendations(
              requestedGenre,
              more: more,
              force: force,
            );
          } catch (error) {
            failures.add(error.toString());
            return null;
          }
        }),
      );
      if (!mounted || generation != _generation) return;
      final available = pages.whereType<CatalogPage>().toList();
      if (available.isEmpty && failures.isNotEmpty) {
        throw AppFailure(failures.join('；'));
      }
      final merged = _mergePages([
        ...available,
        if (_items.isNotEmpty) CatalogPage(_items, hasMore: _hasMore),
      ]);
      final warnings = {
        ...available
            .map((page) => page.warning)
            .where((warning) => warning.isNotEmpty),
        ...failures,
      };
      setState(() {
        _items = merged;
        _hasMore = available.any((page) => page.hasMore) || failures.isNotEmpty;
        _error = warnings.isEmpty ? null : warnings.join('；');
        _loading = _more = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = _more = false;
        _error = error.toString();
      });
    }
  }

  void _select(String genre) {
    if (_genre == genre) return;
    setState(() {
      _genre = genre;
      _items = [];
      _hasMore = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _scheduleLoad(resetScroll: true);
  }

  void _scheduleLoad({bool resetScroll = false}) {
    final schedule = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || schedule != _generation) return;
      if (resetScroll && _scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_load());
    });
  }

  List<Drama> _mergePages(Iterable<CatalogPage> pages) {
    final rows = [for (final page in pages) page.items];
    final result = <String, Drama>{};
    final count = rows.fold<int>(
      0,
      (value, row) => value < row.length ? row.length : value,
    );
    for (var index = 0; index < count; index++) {
      for (final row in rows) {
        if (index < row.length)
          result.putIfAbsent(row[index].id, () => row[index]);
      }
    }
    return result.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final refresh = RefreshAction(
      loading: _loading || _more,
      tooltip: '刷新推荐',
      onPressed: () => _load(force: true),
    );
    final content = Column(
      children: [
        if (!widget.embedded)
          CatalogFilters(
            categories: _genres,
            category: _genre,
            onCategory: _select,
            onRetry: () => _load(force: true),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '公开推荐 · 已加载 ${_items.length} 部',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (widget.embedded) refresh,
            ],
          ),
        ),
        if (_loading && _items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (_error != null && _items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loading || _more
                      ? null
                      : () => _load(more: _failedMore, force: !_failedMore),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        Expanded(
          child: !widget.store.allowsSource('hongguo')
              ? const StatusPanel(
                  title: '红果站源当前不可用',
                  message: '可在“设置 → 播放与信息流 → 站源管理”中恢复显示。',
                )
              : _loading && _items.isEmpty
              ? const Center(child: AppLoadingIndicator())
              : _items.isEmpty
              ? StatusPanel(
                  title: _error == null ? '暂无推荐' : '推荐暂时无法加载',
                  message: _error ?? '稍后刷新可获取新的推荐。',
                  onRetry: () => _load(force: true),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => RefreshIndicator(
                    onRefresh: () => _load(force: true),
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: dramaGridDelegate(
                              context,
                              constraints.maxWidth - 32,
                            ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final drama = _items[index];
                              return DramaTile(
                                key: ValueKey(drama.id),
                                drama: drama,
                                repository: widget.repository,
                                onTap: () => unawaited(
                                  openPlaybackDirectly(
                                    context,
                                    drama: drama,
                                    repository: widget.repository,
                                    store: widget.store,
                                  ),
                                ),
                              );
                            }, childCount: _items.length),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              widget.bottomPadding,
                            ),
                            child: Center(
                              child: _more
                                  ? const AppLoadingIndicator()
                                  : _hasMore
                                  ? OutlinedButton.icon(
                                      onPressed: () => _load(more: true),
                                      icon: const Icon(
                                        Icons.auto_awesome_rounded,
                                      ),
                                      label: const Text('继续推荐'),
                                    )
                                  : TextButton(
                                      onPressed: () => _load(force: true),
                                      child: const Text('本轮推荐已看完，刷新获取新推荐'),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('红果推荐'), actions: [refresh]),
      body: SafeArea(top: false, child: content),
    );
  }
}
