import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'feed_preferences.dart';
import 'feed_recommendations.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';
import 'sources_screen.dart';

class _PreferenceTopicGroup {
  const _PreferenceTopicGroup(this.group, this.categoriesByTopic);

  final FeedTopicGroup group;
  final Map<String, List<CatalogCategory>> categoriesByTopic;
  List<CatalogCategory> get categories => [
    for (final values in categoriesByTopic.values) ...values,
  ];
}

class HomeFeedPreferencesScreen extends StatefulWidget {
  const HomeFeedPreferencesScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<HomeFeedPreferencesScreen> createState() =>
      _HomeFeedPreferencesScreenState();
}

class _HomeFeedPreferencesScreenState extends State<HomeFeedPreferencesScreen> {
  final Map<String, List<CatalogCategory>> _categories = {};
  final Map<String, String> _errors = {};
  final Set<String> _loading = {};
  final Set<String> _expandedSources = {};
  final Set<String> _expandedCategoryGroups = {};
  final Map<String, ScrollController> _categoryScrollControllers = {};
  final Map<String, List<CatalogCategory>> _taxonomyInputs = {};
  final Map<String, List<_PreferenceTopicGroup>> _taxonomyGroupsCache = {};

  @override
  void dispose() {
    for (final controller in _categoryScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final source in widget.store.sources) {
        if (widget.store.homeFeedPreferences[source.id]?.enabled == true) {
          unawaited(_loadCategories(source));
        }
      }
    });
  }

  Future<void> _toggleSource(SourceSite source, bool enabled) async {
    if (!widget.store.allowsSource(source.id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先在站源管理中显示此站源')));
      return;
    }
    if (!mounted) return;
    await saveUserChange(
      context,
      () => widget.store.setHomeFeedSourceEnabled(source.id, enabled),
    );
    if (!mounted) return;
    setState(() {
      if (enabled) {
        _expandedSources.add(source.id);
        if (source.id == SourceSite.hongguo.id) {
          _expandedCategoryGroups.add('${source.id}:format');
        }
      } else {
        _expandedSources.remove(source.id);
      }
    });
    if (enabled) {
      await _loadCategories(source);
      await _ensureInitialCategorySelection(source);
    }
  }

  Future<void> _ensureInitialCategorySelection(SourceSite source) async {
    final preference = widget.store.homeFeedPreferences[source.id];
    final categories = _categories[source.id];
    if (preference?.enabled != true ||
        categories == null ||
        categories.isEmpty) {
      return;
    }
    final availableCategories = {
      for (final category in categories.take(maxHomeFeedCategoriesPerSource))
        category.id: category.name,
    };
    final shouldSelectAll =
        preference?.categoriesConfigured != true &&
        preference?.categories.isEmpty == true;
    await saveUserChange(
      context,
      () => widget.store.setHomeFeedCategories(source.id, {
        if (shouldSelectAll) ...availableCategories,
        if (!shouldSelectAll)
          for (final entry
              in preference?.categories.entries ??
                  const <MapEntry<String, String>>[])
            source.id == 'douyin' && entry.key == 'short_video'
                ? 'recommend'
                : entry.key: source.id == 'douyin' && entry.key == 'short_video'
                ? '推荐'
                : availableCategories[entry.key] ?? entry.value,
      }, availableCategories: availableCategories),
    );
  }

  Future<void> _loadCategories(SourceSite source, {bool force = false}) async {
    if (_loading.contains(source.id) ||
        (!force && _categories.containsKey(source.id)) ||
        !widget.store.allowsSource(source.id)) {
      return;
    }
    final epoch = widget.store.profileEpoch;
    setState(() {
      _loading.add(source.id);
      _errors.remove(source.id);
    });
    try {
      final available =
          (await widget.repository.categories(source.id, force: force))
              .where(
                (category) =>
                    category.id.trim().isNotEmpty &&
                    !_isAggregate(category, source.id),
              )
              .toList();
      if (source.id == SourceSite.hongguo.id &&
          mounted &&
          epoch == widget.store.profileEpoch) {
        setState(() => _categories[source.id] = available);
      }
      final categories = await _loadSourceCategories(
        source.id,
        available,
        force: force,
      );
      if (!mounted || epoch != widget.store.profileEpoch) return;
      setState(() {
        _categories[source.id] = categories
            .where(
              (category) =>
                  category.id.trim().isNotEmpty &&
                  !_isAggregate(category, source.id),
            )
            .toList();
      });
      await _ensureInitialCategorySelection(source);
    } catch (error) {
      if (!mounted || epoch != widget.store.profileEpoch) return;
      setState(() => _errors[source.id] = error.toString());
    } finally {
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _loading.remove(source.id));
      }
    }
  }

  Future<List<CatalogCategory>> _loadSourceCategories(
    String source,
    List<CatalogCategory> available, {
    required bool force,
  }) async {
    if (source != SourceSite.hongguo.id) return available;

    final pages = <Iterable<Drama>>[];
    for (final category in available) {
      final dramas = <String, Drama>{};
      try {
        final cached = await widget.repository.cached(
          source,
          category: category.id,
        );
        for (final drama in cached.items) {
          dramas[drama.id] = drama;
        }
      } catch (_) {}
      try {
        final page = await widget.repository.catalog(
          source,
          category: category.id,
          force: force,
        );
        for (final drama in page.items) {
          dramas[drama.id] = dramas[drama.id]?.merge(drama) ?? drama;
        }
      } catch (_) {}
      pages.add(dramas.values);
    }

    final seen = {
      for (final category in available) _categoryIdentity(category.name),
    };
    final discovered = <CatalogCategory>[];
    for (final dramas in pages) {
      for (final drama in dramas) {
        final names =
            <String>{
              drama.category.trim(),
              ...drama.tags.map((tag) => tag.trim()),
            }..removeWhere(
              (name) =>
                  name.isEmpty ||
                  _isAggregate(CatalogCategory('', name), source),
            );
        for (final name in names) {
          final identity = _categoryIdentity(name);
          if (!seen.add(identity)) continue;
          discovered.add(CatalogCategory('tag:$name', name));
        }
      }
    }
    return [...available, ...discovered];
  }

  String _categoryIdentity(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  bool _isAggregate(CatalogCategory category, String source) {
    if (SourceSite.byId(source).isDouyin || SourceSite.byId(source).isBilibili)
      return category.id.isEmpty;
    final id = category.id.trim().toLowerCase();
    final name = category.name.trim();
    return {'all', 'recommend', 'category:all'}.contains(id) ||
        {'全部', '全部分类', '推荐'}.contains(name);
  }

  Future<void> _toggleCategory(
    SourceSite source,
    CatalogCategory category,
    bool enabled,
  ) async {
    final name = category.name.trim();
    if (!mounted) return;
    await saveUserChange(
      context,
      () => widget.store.setHomeFeedCategory(
        source.id,
        category.id,
        name,
        enabled: enabled,
      ),
    );
  }

  List<_PreferenceTopicGroup> _taxonomyGroups(
    List<CatalogCategory> categories,
    String source,
  ) {
    if (identical(_taxonomyInputs[source], categories)) {
      return _taxonomyGroupsCache[source] ?? const [];
    }
    final values = <String, Map<String, List<CatalogCategory>>>{
      for (final group in FeedRecommendations.topicGroups)
        group.id: {
          for (final topic in group.topics) topic.id: <CatalogCategory>[],
        },
    };
    for (final category in categories) {
      final match = FeedRecommendations.topicFor(category.name);
      values[match.group.id]![match.topic.id]!.add(category);
    }
    final groups = [
      for (final group in FeedRecommendations.topicGroups)
        if (values[group.id]!.values.any((categories) => categories.isNotEmpty))
          _PreferenceTopicGroup(group, values[group.id]!),
    ];
    _taxonomyInputs[source] = categories;
    _taxonomyGroupsCache[source] = groups;
    return groups;
  }

  int _selectedCount(
    Map<String, String>? selected,
    Iterable<CatalogCategory> categories,
  ) => categories
      .where((category) => selected?.containsKey(category.id) == true)
      .length;

  Future<void> _toggleCategorySet(
    SourceSite source,
    List<CatalogCategory> categories, {
    required bool enabled,
    required List<CatalogCategory> available,
  }) async {
    if (!mounted || categories.isEmpty) return;
    final selected = Map<String, String>.of(
      widget.store.homeFeedPreferences[source.id]?.categories ?? const {},
    );
    for (final category in categories) {
      if (enabled) {
        selected[category.id] = category.name;
      } else {
        selected.remove(category.id);
      }
    }
    await saveUserChange(
      context,
      () => widget.store.setHomeFeedCategories(
        source.id,
        selected,
        availableCategories: {
          for (final category in available) category.id: category.name,
        },
      ),
    );
  }

  Future<void> _showTopicCategories(
    SourceSite source,
    FeedTopic topic,
    List<CatalogCategory> categories,
  ) async {
    if (categories.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final preference = widget.store.homeFeedPreferences[source.id];
          final selectedCount = _selectedCount(
            preference?.categories,
            categories,
          );
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .72,
              child: Column(
                children: [
                  ListTile(
                    title: Text(topic.label),
                    subtitle: Text(
                      '$selectedCount/${categories.length} 个具体分类已开启',
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        await _toggleCategorySet(
                          source,
                          categories,
                          enabled: selectedCount != categories.length,
                          available: _categories[source.id] ?? categories,
                        );
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                      child: Text(
                        selectedCount == categories.length ? '全关' : '全开',
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: categories.length,
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        final selected =
                            preference?.categories.containsKey(category.id) ==
                            true;
                        return CheckboxListTile(
                          value: selected,
                          title: Text(category.name),
                          dense: true,
                          onChanged: (enabled) async {
                            await _toggleCategory(
                              source,
                              category,
                              enabled == true,
                            );
                            if (sheetContext.mounted) setSheetState(() {});
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _categorySelectionPanel(
    SourceSite source,
    List<CatalogCategory> categories,
    ScrollController controller,
  ) {
    final preference = widget.store.homeFeedPreferences[source.id];
    final grouped = source.id == SourceSite.hongguo.id;
    final groups = grouped
        ? _taxonomyGroups(categories, source.id)
        : const <_PreferenceTopicGroup>[];
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 480,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: true,
          child: ListView.builder(
            controller: controller,
            primary: false,
            padding: const EdgeInsets.all(8),
            itemCount: grouped ? groups.length : categories.length,
            itemBuilder: (context, groupIndex) {
              if (!grouped) {
                final category = categories[groupIndex];
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CheckboxListTile(
                    value:
                        preference?.categories.containsKey(category.id) == true,
                    title: Text(category.name),
                    dense: true,
                    onChanged: (enabled) =>
                        _toggleCategory(source, category, enabled == true),
                  ),
                );
              }
              final entry = groups[groupIndex];
              final groupKey = '${source.id}:${entry.group.id}';
              final expanded = _expandedCategoryGroups.contains(groupKey);
              final groupSelected = _selectedCount(
                preference?.categories,
                entry.categories,
              );
              final groupAll = groupSelected == entry.categories.length;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          Checkbox(
                            tristate: true,
                            value: groupAll
                                ? true
                                : groupSelected == 0
                                ? false
                                : null,
                            onChanged: (_) => _toggleCategorySet(
                              source,
                              entry.categories,
                              enabled: !groupAll,
                              available: categories,
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() {
                                if (expanded) {
                                  _expandedCategoryGroups.remove(groupKey);
                                } else {
                                  _expandedCategoryGroups.add(groupKey);
                                }
                              }),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      entry.group.label,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                  Text(
                                    '$groupSelected/${entry.categories.length}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                  Icon(
                                    expanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (expanded)
                      for (final topic in entry.group.topics)
                        if (entry.categoriesByTopic[topic.id]?.isNotEmpty ==
                            true)
                          _topicSelectionRow(
                            source,
                            topic,
                            entry.categoriesByTopic[topic.id]!,
                            categories,
                            preference?.categories,
                          ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topicSelectionRow(
    SourceSite source,
    FeedTopic topic,
    List<CatalogCategory> categories,
    List<CatalogCategory> available,
    Map<String, String>? selected,
  ) {
    final count = _selectedCount(selected, categories);
    final all = count == categories.length;
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 20),
            Checkbox(
              tristate: true,
              value: all
                  ? true
                  : count == 0
                  ? false
                  : null,
              onChanged: (_) => _toggleCategorySet(
                source,
                categories,
                enabled: !all,
                available: available,
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: () => _toggleCategorySet(
                  source,
                  categories,
                  enabled: !all,
                  available: available,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(topic.label)),
                    Text(
                      '$count/${categories.length}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '查看具体分类',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showTopicCategories(source, topic, categories),
              icon: const Icon(Icons.tune_rounded, size: 20),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _selectAllCategories(
    SourceSite source,
    List<CatalogCategory> categories, {
    required bool invert,
  }) async {
    final selected =
        widget.store.homeFeedPreferences[source.id]?.categories.keys.toSet() ??
        <String>{};
    await saveUserChange(
      context,
      () => widget.store.setHomeFeedCategories(
        source.id,
        {
          for (final category in categories)
            if (!invert || !selected.contains(category.id))
              category.id: category.name,
        },
        availableCategories: {
          for (final category in categories) category.id: category.name,
        },
      ),
    );
  }

  Widget _sourceCard(SourceSite source) {
    final preference = widget.store.homeFeedPreferences[source.id];
    final enabled = preference?.enabled == true;
    final unavailable = !widget.store.allowsSource(source.id);
    final liveSource = source.id == SourceSite.stripchat.id;
    final categories = _categories[source.id] ?? const <CatalogCategory>[];
    final expanded = _expandedSources.contains(source.id);
    final categoryScrollController = _categoryScrollControllers.putIfAbsent(
      source.id,
      () => ScrollController(),
    );
    final selectedCount = categories
        .where(
          (category) => preference?.categories.containsKey(category.id) == true,
        )
        .length;
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('home-feed-source-card-${source.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      color: colors.surfaceContainer,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          ListTile(
            key: ValueKey('home-feed-source-${source.id}'),
            contentPadding: const EdgeInsets.fromLTRB(18, 8, 16, 8),
            leading: Icon(
              Icons.dns_outlined,
              color: colors.onSurfaceVariant,
              size: 24,
            ),
            title: Text(
              source.name,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              liveSource
                  ? '直播内容不进入首页短剧信息流'
                  : unavailable
                  ? '当前在站源管理中隐藏，首页不会请求此站源'
                  : enabled
                  ? _loading.contains(source.id) && categories.isEmpty
                        ? '正在读取分类…'
                        : categories.isNotEmpty
                        ? '已选 $selectedCount/${categories.length} 个分类 · 点击左侧展开'
                        : '分类暂不可用 · 点击左侧展开查看'
                  : '关闭时不会请求或推送此站源内容',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!liveSource)
                  IconButton(
                    key: ValueKey('home-feed-source-expand-${source.id}'),
                    tooltip: expanded ? '收起分类' : '展开分类',
                    visualDensity: VisualDensity.compact,
                    onPressed: unavailable || !enabled
                        ? null
                        : () => setState(() {
                            if (expanded) {
                              _expandedSources.remove(source.id);
                            } else {
                              _expandedSources.add(source.id);
                            }
                          }),
                    icon: Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ),
                Switch.adaptive(
                  key: ValueKey('home-feed-source-switch-${source.id}'),
                  value: enabled,
                  onChanged: unavailable || liveSource
                      ? null
                      : (value) => _toggleSource(source, value),
                ),
              ],
            ),
          ),
          if (enabled && !liveSource && expanded) ...[
            Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: colors.outlineVariant.withValues(alpha: .45),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_loading.contains(source.id))
                      const LinearProgressIndicator(),
                    if (_errors[source.id] != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '分类暂时无法加载：${_errors[source.id]}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                          IconButton(
                            tooltip: '重试',
                            onPressed: () =>
                                _loadCategories(source, force: true),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      )
                    else if (categories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _loading.contains(source.id)
                              ? '正在读取分类…'
                              : '此站源没有可选择的短剧分类。',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Text(
                            '$selectedCount/${categories.length} 个分类',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _selectAllCategories(
                              source,
                              categories,
                              invert: false,
                            ),
                            child: const Text('全选'),
                          ),
                          TextButton(
                            onPressed: () => _selectAllCategories(
                              source,
                              categories,
                              invert: true,
                            ),
                            child: const Text('反选'),
                          ),
                        ],
                      ),
                      if (selectedCount == 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '未选中分类：首页不会请求此站源。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      if (source.id == SourceSite.hongguo.id)
                        _categorySelectionPanel(
                          source,
                          categories,
                          categoryScrollController,
                        )
                      else
                        Container(
                          height: math.min(480.0, categories.length * 48.0),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Scrollbar(
                              controller: categoryScrollController,
                              thumbVisibility: categories.length > 10,
                              child: ListView.builder(
                                controller: categoryScrollController,
                                primary: false,
                                padding: const EdgeInsets.all(8),
                                itemExtent: 48,
                                itemCount: categories.length,
                                itemBuilder: (context, index) {
                                  final category = categories[index];
                                  final selected =
                                      preference?.categories.containsKey(
                                        category.id,
                                      ) ??
                                      false;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Semantics(
                                      key: ValueKey(
                                        'home-feed-category-${source.id}-${category.id}',
                                      ),
                                      button: true,
                                      checked: selected,
                                      label: category.name,
                                      child: InkWell(
                                        onTap: () => _toggleCategory(
                                          source,
                                          category,
                                          !selected,
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                selected
                                                    ? Icons.check_box_rounded
                                                    : Icons
                                                          .check_box_outline_blank_rounded,
                                                size: 22,
                                                color: selected
                                                    ? colors.primary
                                                    : colors.onSurfaceVariant,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  category.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('首页偏好')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.viewPaddingOf(context).bottom + 24,
            ),
            children: [
              Card(
                margin: const EdgeInsets.only(bottom: 16),
                color: Theme.of(context).colorScheme.surfaceContainer,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '站源默认关闭。首次开启站源时默认全选分类，你可以按需取消或用“反选”快速调整；剧目命中任一关闭分类时，即使同时命中已开启分类，也不会进入首页。红果细分类只在已开启的真人剧、漫剧或AI剧中生效。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (SourceSite.values.isEmpty)
                ListTile(
                  leading: const Icon(Icons.add_link),
                  title: const Text('先导入站源订阅'),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SourcesScreen(
                        repository: widget.repository,
                        store: widget.store,
                      ),
                    ),
                  ),
                ),
              for (final source in SourceSite.values) _sourceCard(source),
            ],
          ),
        ),
      ),
    ),
  );
}
