import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'playback_launch_screen.dart';
import 'local_store.dart';
import 'lan_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'search_input.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'saved_library.dart';
import 'short_drama_feed.dart';
import 'sources_screen.dart';
import 'source_subscriptions.dart';

class _DiscoveryView {
  const _DiscoveryView({
    required this.items,
    required this.hasMore,
    required this.query,
    required this.displayOffset,
    required this.scrollOffset,
    required this.recommendations,
    this.error,
  });
  final List<Drama> items;
  final bool hasMore;
  final String query;
  final int displayOffset;
  final double scrollOffset;
  final bool recommendations;
  final String? error;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _catalogShuffleRandom = math.Random();
  Timer? _debounce;
  late SourceSite _source;
  List<Drama> _items = [];
  final _discoveryViews = <String, _DiscoveryView>{};
  late int _viewProfileEpoch;
  String get _viewKey =>
      '${_group.id}:${_group.sources.map((source) => source.id).join(',')}';

  void _rememberDiscoveryView() {
    if (_items.isEmpty && !_showRecommendations) return;
    _discoveryViews.remove(_viewKey);
    _discoveryViews[_viewKey] = _DiscoveryView(
      items: List.unmodifiable(_items),
      hasMore: _hasMore,
      query: _search.text.trim(),
      displayOffset: _catalogDisplayOffset,
      scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
      recommendations: _showRecommendations,
      error: _error,
    );
    while (_discoveryViews.length > 16) {
      _discoveryViews.remove(_discoveryViews.keys.first);
    }
  }

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = 0;
  bool _feedMounted = false;
  int _feedBatchCursor = DateTime.now().microsecondsSinceEpoch;
  String _submittedQuery = '';
  final _categorySelections = <String, String>{};
  final _contentFormatSelections = <String, String>{};
  final _recommendationFormatSelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  bool _feedCleanMode = false;
  bool _showRecommendations = false;
  String _sourceSignature = '';
  bool _catalogLoadScheduled = false;
  bool _discoveryInitialized = false;
  bool _catalogSourcesDirty = false;
  bool _catalogSourceFallbackPending = false;
  int _catalogDisplayOffset = 0;

  List<SourceGroup> get _sourceGroups =>
      SourceGroup.fromSources(widget.store.sources);

  SourceGroup get _group =>
      _sourceGroups.where((group) => group.id == _source.groupId).firstOrNull ??
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    final online = _group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) {
      return '筛选本机已更新剧库';
    }
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索$names'
        : '搜索$names及本机剧库';
  }

  CatalogTaxonomyGroup? get _contentFormatGroup =>
      _taxonomyGroups.where((entry) => entry.group.id == 'format').firstOrNull;
  CatalogCategory? _formatCategory(String topicId) {
    final group = _contentFormatGroup;
    if (group == null) return null;
    final index = group.topicIds.indexOf(topicId);
    return index < 0 ? null : group.categories[index];
  }

  String get _category {
    final selected = _categorySelections[_group.id];
    if (selected != null && selected.isNotEmpty) return selected;
    final format = _contentFormatSelections[_group.id] ?? 'all';
    return _formatCategory(format)?.id ?? '';
  }

  List<CatalogCategory> get _categories => _browser.categories(_group);
  List<CatalogTaxonomyGroup> get _taxonomyGroups =>
      _browser.taxonomyGroups(_group);
  String get _displayCategory {
    if (_showRecommendations) return _recommendationCategory;
    final selected = _category;
    if (_contentFormatGroup?.categories.any(
          (category) => category.id == selected,
        ) ==
        true) {
      return '';
    }
    for (final group in _taxonomyGroups) {
      if (group.group.id == 'format') continue;
      if (group.filter.id == selected ||
          group.categories.any((category) => category.id == selected)) {
        return group.filter.id;
      }
    }
    return selected;
  }

  String get _selectedContentFormat {
    if (_showRecommendations) return _recommendationFormat;
    final group = _contentFormatGroup;
    final index = group?.categories.indexWhere(
      (category) => category.id == _category,
    );
    return index != null && index >= 0
        ? group!.topicIds[index]
        : _contentFormatSelections[_group.id] ?? 'all';
  }

  String get _recommendationFormat =>
      _recommendationFormatSelections[_group.id] ?? 'all';

  List<CatalogCategory> get _displayCategories {
    final taxonomyGroups = _taxonomyGroups;
    if (taxonomyGroups.isNotEmpty) {
      return [
        CatalogCategory.all,
        const CatalogCategory(_recommendationCategory, '推荐'),
        for (final entry in taxonomyGroups)
          if (entry.group.id != 'format') entry.filter,
      ];
    }
    return [
      _group.id == 'douyin'
          ? const CatalogCategory('', '推荐')
          : _group.id == 'bilibili-live'
          ? const CatalogCategory('', '推荐')
          : _group.id == 'douyin-live'
          ? const CatalogCategory('', '精选')
          : _group.id == 'douyin-series'
          ? const CatalogCategory('', '推荐')
          : _group.id == 'douyin-theater'
          ? const CatalogCategory('', '综艺')
          : CatalogCategory.all,
      ..._categories.where((entry) => entry.id.isNotEmpty),
    ];
  }

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _updateCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  Future<void> _refreshLoadedCatalog() async {
    if (!mounted || _loading || _loadingMore) return;
    final count = _visible.length;
    if (count < 2) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('当前分类暂无其他已加载内容可换批')));
      return;
    }
    final width = MediaQuery.sizeOf(context).width - 32;
    final columns = width < 600 ? 3 : (width / 180).floor().clamp(4, 9);
    final batchSize = math.min(count, columns * 6);
    final minimumShift = count > batchSize * 2 ? batchSize : 1;
    final maximumShift = count > batchSize * 2 ? count - batchSize : count - 1;
    final shift =
        minimumShift +
        _catalogShuffleRandom.nextInt(maximumShift - minimumShift + 1);
    setState(
      () => _catalogDisplayOffset =
          (_catalogDisplayOffset % count + shift) % count,
    );
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  /// 站源显示设置变化后，把当前站源归一化到仍然可见的站源。
  void _sourcesChanged() {
    if (!mounted) return;
    if (_viewProfileEpoch != widget.store.profileEpoch) {
      _viewProfileEpoch = widget.store.profileEpoch;
      _discoveryViews.clear();
    }
    final visible = widget.store.sources;
    final signature = visible.map((site) => site.id).join(',');
    if (signature == _sourceSignature) return;
    final wasEmpty = _sourceSignature.isEmpty;
    final previous = _sourceSignature
        .split(',')
        .where((source) => source.isNotEmpty)
        .toSet();
    final current = visible.map((site) => site.id).toSet();
    final changed = previous
        .union(current)
        .difference(previous.intersection(current));
    _sourceSignature = signature;
    _discoveryViews.clear();
    if (visible.isEmpty) {
      if (_tab != 1) {
        _catalogSourcesDirty = true;
        _catalogSourceFallbackPending = false;
        return;
      }
      setState(() {
        _items = [];
        _hasMore = false;
        _loading = false;
        _loadingMore = false;
      });
      return;
    }
    final allowed = visible.map((site) => site.id).toSet();
    final selectedSourceRemainsVisible =
        allowed.contains(_source.id) && _source.id == widget.store.source;
    final affectsCurrentGroup = changed.any(
      (source) => SourceSite.byId(source).groupId == _source.groupId,
    );
    if (!wasEmpty && selectedSourceRemainsVisible && !affectsCurrentGroup) {
      if (_tab == 1) setState(() {});
      return;
    }
    if (_tab != 1) {
      _catalogSourcesDirty = true;
      _catalogSourceFallbackPending = !selectedSourceRemainsVisible;
      return;
    }
    if (selectedSourceRemainsVisible && affectsCurrentGroup) {
      _reloadVisibleGroup();
      return;
    }
    _changeSource(SourceSite.byId(widget.store.source), persist: false);
  }

  void _reloadVisibleGroup() {
    _debounce?.cancel();
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    setState(() {
      _items = [];
      _catalogDisplayOffset = 0;
      _hasMore = true;
      _loading = false;
      _loadingMore = false;
      _categoriesLoading = false;
      _categoriesError = null;
      _error = null;
      _categorySelections.remove(_group.id);
    });
    unawaited(_load(useCache: true));
    unawaited(_loadCategories());
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _changeGroup(SourceGroup group) {
    if (_group.id != group.id) {
      _changeSource(group.sources.first);
    }
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _searchVisible = false;
        _submittedQuery = '';
      });
      return;
    }
    if (!_showRecommendations && category.isEmpty && _displayCategory.isEmpty) {
      return;
    }
    if (_category == category && !_showRecommendations) return;
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      _catalogDisplayOffset = 0;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _scheduleCatalogLoad(useCache: true);
  }

  void _changeContentFormat(String format) {
    if (_showRecommendations) {
      if (_recommendationFormat == format) return;
      setState(() => _recommendationFormatSelections[_group.id] = format);
      return;
    }
    if (_displayCategory.isNotEmpty || _selectedContentFormat == format) return;
    _debounce?.cancel();
    setState(() {
      _contentFormatSelections[_group.id] = format;
      _categorySelections[_group.id] = '';
      _catalogDisplayOffset = 0;
      _selectionMode = false;
      _selectedDramas.clear();
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _scheduleCatalogLoad(useCache: true);
  }

  void _scheduleCatalogLoad({bool useCache = false}) {
    final scheduledGeneration = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          scheduledGeneration != _generation ||
          _showRecommendations) {
        return;
      }
      unawaited(_load(useCache: useCache));
    });
  }

  void _changeTaxonomyGroup(String groupId) {
    final group = _taxonomyGroups
        .where((entry) => entry.group.id == groupId)
        .firstOrNull;
    if (group == null) return;
    _changeCategory(group.filter.id);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  void _toggleSearch() {
    if (!_canSearch) return;
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    if (_showRecommendations) _changeCategory('');
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    if (!_catalogTools) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
  }

  Future<void> _televisionSearch() async {
    if (!_canSearch) return;
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _group.id == 'all'
            ? '搜索已开放站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != 0) {
      setState(() {
        _tab = 0;
        _feedMounted = true;
      });
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    _tab = switch (widget.store.startupDestination) {
      'discover' => 1,
      'following' => 2,
      'settings' => 3,
      _ => 0,
    };
    _feedMounted = _tab == 0;
    _scroll.addListener(_onCatalogScroll);
    _source = SourceSite.byId(widget.store.source);
    _viewProfileEpoch = widget.store.profileEpoch;
    _sourceSignature = widget.store.sources.map((site) => site.id).join(',');
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.store.addListener(_sourcesChanged);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _loading = false;
    if (_tab == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_discoveryInitialized) _changeTab(1);
      });
    }
  }

  @override
  void dispose() {
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.store.removeListener(_sourcesChanged);
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onCatalogScroll() {
    if (!mounted ||
        _showRecommendations ||
        !_hasMore ||
        _loading ||
        _loadingMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted ||
          _showRecommendations ||
          !_hasMore ||
          _loading ||
          _loadingMore ||
          !_scroll.hasClients) {
        return;
      }
      unawaited(_load(more: true));
    });
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(
      CatalogPage result, {
      bool cached = false,
      bool cacheCatalogCandidates = true,
    }) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = cached && !result.fresh;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      if (cacheCatalogCandidates) {
        widget.store.cacheSeriesCandidatesInMemory(result.items);
      }
    }

    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) =>
            accept(result, cached: true, cacheCatalogCandidates: false),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  void _changeSource(SourceSite source, {bool persist = true}) {
    if (_source.id == source.id) return;
    if (persist) _rememberDiscoveryView();
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    _debounce?.cancel();
    _source = source;
    final view = _discoveryViews[_viewKey];
    _search.text = view?.query ?? '';
    setState(() {
      _showRecommendations = view?.recommendations ?? false;
      _selectionMode = false;
      _selectedDramas.clear();
      _searchVisible = view?.query.isNotEmpty ?? false;
      _items = view?.items ?? [];
      _catalogDisplayOffset = view?.displayOffset ?? 0;
      _hasMore = view?.hasMore ?? true;
      _submittedQuery = view?.query ?? '';
      _error = view?.error;
      _loading = false;
      _loadingMore = false;
      _categoriesLoading = false;
      _categoriesError = null;
    });
    if (persist) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.setCatalogSource(source.id, allSources: false),
        ),
      );
    }
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      _scroll.jumpTo(
        (view?.scrollOffset ?? 0).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
    if (view == null) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_loadInitialDiscovery());
      unawaited(_loadCategories());
    } else if (_categories.length <= 1) {
      unawaited(_loadCategories());
    }
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    if (!_catalogTools) return;
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    if (download) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            downloadOnOpen: true,
          ),
        ),
      );
      return;
    }
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  void _changeTab(int tab) {
    setState(() {
      _tab = tab;
      if (tab == 0) _feedMounted = true;
      _selectionMode = false;
      _selectedDramas.clear();
      _feedCleanMode = false;
    });
    if (tab == 1) {
      if (_catalogSourcesDirty) {
        _catalogSourcesDirty = false;
        if (_catalogSourceFallbackPending && widget.store.sources.isNotEmpty) {
          _catalogSourceFallbackPending = false;
          _changeSource(SourceSite.byId(widget.store.source), persist: false);
          return;
        }
        _catalogSourceFallbackPending = false;
        if (widget.store.sources.isEmpty) {
          setState(() {
            _items = [];
            _hasMore = false;
            _loading = false;
            _loadingMore = false;
          });
        } else {
          _reloadVisibleGroup();
        }
      } else if (!_discoveryInitialized) {
        _discoveryInitialized = true;
        if (widget.store.sources.isNotEmpty) {
          unawaited(_loadInitialDiscovery());
          _loadCategories();
        }
      }
    }
  }

  Future<void> _loadInitialDiscovery() async {
    final key = _viewKey;
    final epoch = widget.store.profileEpoch;
    final generation = _generation + 1;
    await _load(cacheOnly: true);
    if (!mounted ||
        generation != _generation ||
        key != _viewKey ||
        epoch != widget.store.profileEpoch ||
        _items.isNotEmpty ||
        _showRecommendations) {
      return;
    }
    await _load();
  }

  void _setFeedCleanMode(bool enabled) {
    if (!mounted || _feedCleanMode == enabled) return;
    setState(() => _feedCleanMode = enabled);
  }

  void _onNavSelected(int tab) => _changeTab(tab);

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!_catalogTools || !SourceSite.byId(drama.source).supportsDownloads)
      return;
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload:
        SourceSite.byId(drama.source).supportsDownloads &&
            widget.repository.supportsDownloads &&
            widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect:
        _catalogTools &&
            SourceSite.byId(drama.source).supportsDownloads &&
            widget.repository.supportsDownloads &&
            widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        _catalogTools &&
        SourceSite.byId(drama.source).supportsDownloads &&
        widget.store.canDownload &&
        widget.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      subtitle:
          SourceSite.byId(drama.source).supportsCreator &&
              drama.creatorName.trim().isNotEmpty
          ? drama.creatorName.trim()
          : null,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _dramaActions(drama),
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  bool get _catalogTools =>
      _group.sources.every((source) => source.supportsCatalogTools);
  bool get _canSearch => _group.sources.any((source) => source.onlineSearch);

  List<Drama> get _visible {
    final query = _search.text.trim().toLowerCase();
    final filtered = _items.where((drama) {
      if (!widget.store.allowsSource(drama.source)) return false;
      if (_category.startsWith('local:') &&
          categoryName(drama.category) != _category.substring(6)) {
        return false;
      }
      if (_hideVip && drama.source == 'huangdou' && drama.vip) {
        return false;
      }
      return _onlineSearch || query.isEmpty || matchesDramaQuery(drama, query);
    });
    final sorted = _catalogTools
        ? sortCatalog(filtered, widget.store.catalogView)
        : filtered.toList();
    if (sorted.length < 2 || _catalogDisplayOffset == 0) return sorted;
    final offset = _catalogDisplayOffset % sorted.length;
    return List<Drama>.generate(
      sorted.length,
      (index) => sorted[(index + offset) % sorted.length],
      growable: false,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store.viewChanges,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final feedActive =
            _tab == 0 && (ModalRoute.of(context)?.isCurrent ?? true);
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        final compactNavigation = !desktop && !television && !_selectionMode;
        final scaffold = Scaffold(
          backgroundColor: _tab == 0 ? Colors.black : null,
          extendBody: compactNavigation && _tab != 0,
          appBar: _tab == 0 && !_selectionMode
              ? null
              : AppBar(
                  toolbarHeight: television ? 64 : null,
                  titleSpacing: 12,
                  title: _selectionMode
                      ? const Text(
                          '选择短剧',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : _tab == 1
                      ? PopupMenuButton<SourceGroup>(
                          key: const ValueKey('source-switch'),
                          tooltip: '切换站源',
                          enabled: _sourceGroups.length > 1,
                          onSelected: _changeGroup,
                          itemBuilder: (_) => [
                            for (final group in _sourceGroups)
                              PopupMenuItem(
                                value: group,
                                child: Row(
                                  children: [
                                    Expanded(child: Text(group.name)),
                                    if (group.id == _group.id)
                                      const Icon(Icons.check_rounded, size: 20),
                                  ],
                                ),
                              ),
                          ],
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _group.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (_sourceGroups.length > 1)
                                  const Icon(Icons.expand_more_rounded),
                              ],
                            ),
                          ),
                        )
                      : _tab == 2
                      ? Text(
                          '我的收藏 · ${widget.store.favorites.length + widget.store.followedCreators.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Text(switch (_tab) {
                          0 => '首页',
                          3 => '设置',
                          _ => appName,
                        }),
                  actions: [
                    if (_selectionMode) ...[
                      TextButton(
                        key: const ValueKey('clear-catalog-selection'),
                        onPressed: _selectedDramas.isEmpty
                            ? null
                            : () => setState(_selectedDramas.clear),
                        child: const Text('清空'),
                      ),
                      TextButton(
                        key: const ValueKey('cancel-catalog-selection'),
                        onPressed: _cancelSelection,
                        child: const Text('取消'),
                      ),
                    ] else ...[
                      if (_tab == 2)
                        IconButton(
                          key: const ValueKey('follow-lan-sync'),
                          tooltip: '收藏与观看进度同步',
                          onPressed: () => openLanSync(context),
                          icon: const Icon(Icons.sync_rounded),
                        ),
                      if (_tab == 1) ...[
                        if (_catalogTools && !_showRecommendations)
                          IconButton(
                            tooltip:
                                '排序与筛选 · ${widget.store.catalogView.sort.label}',
                            onPressed: _chooseCatalogView,
                            color:
                                widget.store.catalogView.sort !=
                                        CatalogSort.source ||
                                    widget.store.catalogView.release.isNotEmpty
                                ? Theme.of(context).colorScheme.primary
                                : null,
                            icon: const Icon(Icons.sort_rounded),
                          ),
                        if (_catalogTools)
                          IconButton(
                            key: const ValueKey('open-rankings'),
                            tooltip: '榜单',
                            onPressed: widget.store.sources.isEmpty
                                ? null
                                : _openRankings,
                            icon: const Icon(Icons.leaderboard_outlined),
                          ),
                        if (_catalogTools &&
                            !_showRecommendations &&
                            widget.store.canDownload &&
                            widget.repository.supportsDownloads)
                          IconButton(
                            key: const ValueKey('select-catalog-dramas'),
                            tooltip: '多选下载',
                            onPressed: () =>
                                setState(() => _selectionMode = true),
                            icon: const Icon(Icons.checklist_rounded),
                          ),
                        if (_canSearch)
                          IconButton(
                            key: const ValueKey('toggle-search'),
                            tooltip: _searchVisible ? '收起搜索' : '搜索',
                            icon: Icon(
                              _searchVisible
                                  ? Icons.search_off_rounded
                                  : Icons.search_rounded,
                            ),
                            onPressed: _toggleSearch,
                          ),
                      ],
                      if (_tab == 1 &&
                          !_showRecommendations &&
                          constraints.maxWidth >= 400)
                        RefreshAction(
                          key: const ValueKey('catalog-refresh'),
                          loading:
                              _loading ||
                              _loadingMore ||
                              _categoriesLoading ||
                              _group.sources.any(
                                (source) => _updater.busy(source.id),
                              ),
                          tooltip: '更新剧库',
                          onPressed: widget.store.sources.isEmpty
                              ? null
                              : _updateCatalog,
                        ),
                    ],
                    const SizedBox(width: 8),
                  ],
                ),
          body: SafeArea(
            top: false,
            bottom: !compactNavigation && _tab != 0,
            child: Row(
              children: [
                if (television && !(_tab == 0 && _feedCleanMode)) ...[
                  SizedBox(
                    width: 164,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in [
                            (Icons.play_arrow_rounded, '首页'),
                            (Icons.explore_rounded, '发现'),
                            (Icons.bookmark_rounded, '收藏'),
                            (Icons.settings_rounded, '设置'),
                          ].indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: RemoteButton(
                                key: ValueKey('tv-nav-${entry.$1}'),
                                label: entry.$2.$2,
                                icon: entry.$2.$1,
                                selected: _tab == entry.$1,
                                autofocus: entry.$1 == 0,
                                onPressed: () => _onNavSelected(entry.$1),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (desktop && !(_tab == 0 && _feedCleanMode)) ...[
                  NavigationRail(
                    selectedIndex: _tab,
                    onDestinationSelected: _onNavSelected,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -.8,
                    destinations: [
                      NavigationRailDestination(
                        icon: Icon(Icons.play_arrow_rounded),
                        selectedIcon: Icon(Icons.play_arrow_rounded),
                        label: Text('首页'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.bookmark_border_rounded),
                        selectedIcon: Icon(Icons.bookmark_rounded),
                        label: Text('收藏'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings_rounded),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_feedMounted)
                        ExcludeFocus(
                          excluding: !feedActive,
                          child: Offstage(
                            offstage: !feedActive,
                            child: TickerMode(
                              enabled: feedActive,
                              child: ShortDramaFeedScreen(
                                repository: widget.repository,
                                store: widget.store,
                                active: feedActive,
                                onBack: () => _onNavSelected(1),
                                onCleanModeChanged: _setFeedCleanMode,
                                navigationInset: compactNavigation ? 56 : 16,
                                initialBatchCursor: _feedBatchCursor,
                                onBatchCursorChanged: (cursor) =>
                                    _feedBatchCursor = cursor,
                              ),
                            ),
                          ),
                        ),
                      if (_tab != 0)
                        if (_tab == 1)
                          widget.store.sources.isEmpty
                              ? StatusPanel(
                                  title:
                                      SourceSubscriptions
                                          .instance
                                          .installed
                                          .isEmpty
                                      ? '尚未导入站源'
                                      : '暂无已开启的站源',
                                  message: '在站源管理中导入订阅并开启需要使用的来源。',
                                  action: '站源管理',
                                  onRetry: () => Navigator.push<void>(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => SourcesScreen(
                                        repository: widget.repository,
                                        store: widget.store,
                                      ),
                                    ),
                                  ),
                                )
                              : _catalog(
                                  selectionInBody: desktop || television,
                                  bottomPadding: compactNavigation ? 72 : 16,
                                )
                        else if (_tab == 3)
                          SettingsScreen(
                            repository: widget.repository,
                            store: widget.store,
                            embedded: true,
                            bottomNavPadding: compactNavigation ? 72 : 16,
                          )
                        else
                          SavedLibrary(
                            key: ValueKey('saved-tab-$_tab'),
                            repository: widget.repository,
                            store: widget.store,
                            history: false,
                            onOpen: _openDrama,
                            onContinue: (drama) =>
                                _openDrama(drama, resume: true),
                            bottomPadding: compactNavigation ? 72 : 16,
                            onDownload:
                                widget.repository.supportsDownloads &&
                                    widget.store.canDownload
                                ? (drama) => _openDrama(drama, download: true)
                                : null,
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar:
              desktop || television || _tab == 0 && _feedCleanMode
              ? null
              : _selectionMode
              ? _selectionBar()
              : AppBottomNavigation(
                  selectedIndex: _tab,
                  overVideo: false,
                  onDestinationSelected: _onNavSelected,
                  destinations: const ['首页', '发现', '收藏', '设置'],
                ),
        );
        if (!television && !_selectionMode) return scaffold;
        return PopScope(
          canPop:
              !_selectionMode &&
              (!television || _tab == 0 && _search.text.isEmpty),
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  Widget _catalog({
    required bool selectionInBody,
    required double bottomPadding,
  }) {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (_searchVisible && !television)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: true,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? widget.repository.suggestions
                  : null,
              onChanged: _searchChanged,
              onCancel: () => unawaited(widget.repository.cancelSuggestions()),
              onSearch: _submitSearch,
            ),
          ),
        if (_searchVisible &&
            _search.text.trim().isEmpty &&
            widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in widget.store.recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              label: Text(query),
                              onPressed: () => _submitSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '清空最近搜索',
                  onPressed: () =>
                      saveUserChange(context, widget.store.clearRecentSearches),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        CatalogFilters(
          key: ValueKey('filters-${_group.id}'),
          categories: _displayCategories,
          category: _category,
          primaryCategory: _displayCategory,
          contentFormat: _selectedContentFormat,
          taxonomyGroups: _taxonomyGroups.isEmpty ? null : _taxonomyGroups,
          onTaxonomyGroup: _changeTaxonomyGroup,
          onContentFormat: _changeContentFormat,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_supportsVipFilter)
                IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.setHideVip(!widget.store.hideVip),
                  ),
                  icon: VipIcon(hidden: widget.store.hideVip),
                ),
            ],
          ),
        ),
        if (_group.id == 'hongguo' && _displayCategory.isEmpty)
          const SizedBox(height: 8),
        if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                selectedFormat: _recommendationFormat,
                embedded: true,
                bottomPadding: bottomPadding,
              ),
            ),
          )
        else ...[
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: _loading && _items.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppLoadingIndicator(),
                          SizedBox(height: 18),
                          Text('正在加载剧集'),
                        ],
                      ),
                    )
                  : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: () => _onNavSelected(3),
                              child: const Text('去设置检查站源'),
                            )
                          : null,
                      icon: Icons.wifi_off_rounded,
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.sources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '加载更多',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (television) {
                          return _televisionGrid(
                            items,
                            constraints.maxWidth,
                            key:
                                'catalog-${_group.id}-$_category-$_submittedQuery',
                            controller: _scroll,
                            footer: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              child: Center(
                                child: _loadingMore
                                    ? const AppLoadingIndicator()
                                    : _hasMore
                                    ? RemoteButton(
                                        label: '加载更多',
                                        icon: Icons.expand_more,
                                        onPressed: () => _load(more: true),
                                      )
                                    : const Text('已经看到这里的全部剧集'),
                              ),
                            ),
                          );
                        }
                        final padding = constraints.maxWidth < 600
                            ? 16.0
                            : 24.0;
                        return RefreshIndicator(
                          onRefresh: _refreshLoadedCatalog,
                          child: CustomScrollView(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding,
                                  0,
                                  padding,
                                  16,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: dramaGridDelegate(
                                    context,
                                    constraints.maxWidth - 2 * padding,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (_, index) => _catalogTile(items[index]),
                                    childCount: items.length,
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: bottomPadding,
                                  ),
                                  child: Center(
                                    child: _loadingMore
                                        ? const AppLoadingIndicator()
                                        : _hasMore
                                        ? OutlinedButton.icon(
                                            onPressed: () => _load(more: true),
                                            icon: const Icon(
                                              Icons.expand_more_rounded,
                                            ),
                                            label: const Text('加载更多'),
                                          )
                                        : Text(
                                            '已经看到这里的全部剧集',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_selectionMode && selectionInBody)
            _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  Widget _selectionBar({bool safeBottom = true}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: safeBottom,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final summary = Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      count == 0
                          ? '最多 ${BatchDownloads.maxDramas} 部'
                          : '下一步选择分集和画质',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
              final next = FilledButton(
                key: const ValueKey('download-selected-dramas'),
                onPressed: count == 0 ? null : _downloadSelected,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text('下一步'),
              );
              if (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [summary, const SizedBox(height: 12), next],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 16),
                  next,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    required String key,
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: ValueKey('tv-grid-$key'),
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}
