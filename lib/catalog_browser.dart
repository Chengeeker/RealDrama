import 'dart:async';
import 'dart:math';

import 'core_bridge.dart';
import 'feed_recommendations.dart';
import 'models.dart';

String categoryName(String name) {
  final compact = name.trim().replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    '' => '未分类',
    _ => name.trim(),
  };
}

class _CatalogChoice {
  _CatalogChoice(this.category, {this.taxonomyGroupId, this.taxonomyTopicId});
  final CatalogCategory category;
  final String? taxonomyGroupId;
  final String? taxonomyTopicId;
  final requests = <String, String>{};
}

class CatalogTaxonomyGroup {
  const CatalogTaxonomyGroup({
    required this.group,
    required this.filter,
    required this.categories,
    required this.topicIds,
  });

  final FeedTopicGroup group;
  final CatalogCategory filter;
  final List<CatalogCategory> categories;
  final List<String> topicIds;
}

class _CatalogEntry {
  List<Drama> items = [];
  int page = 0;
  int nextPage = 1;
  bool hasMore = true;
  bool fresh = false;
}

class _CatalogSession {
  final entries = <String, _CatalogEntry>{};
  int generation = 0;
}

class _CatalogTaxonomyIndex {
  const _CatalogTaxonomyIndex({
    required this.signature,
    required this.categories,
    required this.topics,
    required this.groups,
  });

  final String signature;
  final Set<String> categories;
  final Set<String> topics;
  final Set<String> groups;
}

class CatalogBrowser {
  CatalogBrowser(this.repository);
  final AppRepository repository;
  final _menus = <String, List<CatalogCategory>>{};
  final _library = <String, Map<String, Drama>>{};
  final _categoryItems = <String, Map<String, Set<String>>>{};
  final _topicItems = <String, Map<String, Set<String>>>{};
  final _topicGroupItems = <String, Map<String, Set<String>>>{};
  final _indexedTaxonomy = <String, Map<String, _CatalogTaxonomyIndex>>{};
  final _taxonomyGroupCache = <String, List<CatalogTaxonomyGroup>>{};
  final _sessions = <String, _CatalogSession>{};
  int _generation = 0;
  int _categoryGeneration = 0;

  Future<void> cancel() async {
    _generation++;
    _categoryGeneration++;
    for (final session in _sessions.values) {
      session.generation++;
    }
    await Future.wait([
      repository.cancelCatalog(),
      repository.cancelCategories(),
    ]);
  }

  Future<void> _remember(String source, Iterable<Drama> items) async {
    var work = 0;
    final library = _library.putIfAbsent(source, () => {});
    for (final drama in items) {
      if (++work % 128 == 0) await Future<void>.delayed(Duration.zero);
      if (drama.source == source) {
        final merged = library[drama.id]?.merge(drama) ?? drama;
        library[drama.id] = merged;
        final values = {
          for (final value in [merged.category, ...merged.tags])
            if (value.trim().isNotEmpty) value.trim(),
        };
        final signature = (values.toList()..sort()).join('\u0000');
        final indexed = _indexedTaxonomy.putIfAbsent(source, () => {});
        final previous = indexed[merged.id];
        if (previous?.signature == signature) continue;
        if (previous != null) {
          for (final category in previous.categories) {
            _categoryItems[source]?[category]?.remove(merged.id);
          }
          for (final topic in previous.topics) {
            _topicItems[source]?[topic]?.remove(merged.id);
          }
          for (final group in previous.groups) {
            _topicGroupItems[source]?[group]?.remove(merged.id);
          }
        }
        final taxonomy = FeedRecommendations.taxonomyFor(merged);
        final categories = {for (final value in values) categoryName(value)};
        for (final category in categories) {
          _categoryItems
              .putIfAbsent(source, () => {})
              .putIfAbsent(category, () => <String>{})
              .add(merged.id);
        }
        for (final topic in taxonomy.topics) {
          _topicItems
              .putIfAbsent(source, () => {})
              .putIfAbsent(topic, () => <String>{})
              .add(merged.id);
        }
        for (final group in taxonomy.groups) {
          _topicGroupItems
              .putIfAbsent(source, () => {})
              .putIfAbsent(group, () => <String>{})
              .add(merged.id);
        }
        indexed[merged.id] = _CatalogTaxonomyIndex(
          signature: signature,
          categories: categories,
          topics: taxonomy.topics,
          groups: taxonomy.groups,
        );
      }
    }
  }

  void updateDrama(Drama drama) {
    updateDramas([drama]);
  }

  void updateDramas(Iterable<Drama> dramas) {
    final updates = {for (final drama in dramas) drama.id: drama};
    for (final drama in updates.values) {
      final library = _library[drama.source];
      if (library?.containsKey(drama.id) == true) {
        unawaited(_remember(drama.source, [library![drama.id]!.merge(drama)]));
      }
    }
    for (final session in _sessions.values) {
      for (final entry in session.entries.values) {
        entry.items = [
          for (final item in entry.items)
            updates[item.id] == null ? item : item.merge(updates[item.id]!),
        ];
      }
    }
  }

  Future<void> _each<T>(List<T> entries, Future<void> Function(T) visit) async {
    var index = 0;
    Future<void> worker() async {
      while (index < entries.length) {
        final entry = entries[index++];
        await visit(entry);
      }
    }

    await Future.wait(List.generate(min(4, entries.length), (_) => worker()));
  }

  Future<String?> loadCategories(
    SourceGroup group, {
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final failures = <String>[];
    await _each(group.sources, (source) async {
      if (generation != _categoryGeneration) return;
      try {
        final cached = await repository.cached(source.id);
        if (generation != _categoryGeneration) return;
        await _remember(source.id, cached.items);
      } catch (_) {}
      if (cacheOnly || generation != _categoryGeneration) return;
      try {
        final categories = await repository.categories(source.id, force: force);
        if (generation == _categoryGeneration) {
          _menus[source.id] = categories;
          _taxonomyGroupCache.remove(group.id);
        }
      } catch (error) {
        if (generation == _categoryGeneration) {
          failures.add('${source.groupName}：$error');
        }
      }
    });
    if (generation != _categoryGeneration) return null;
    return failures.isEmpty ? null : '部分分类暂未加载，点击重试：${failures.join('；')}';
  }

  List<_CatalogChoice> _choices(SourceGroup group) {
    if (group.sources.length == 1 &&
        (group.sources.single.isDouyin ||
            group.sources.single.id == 'bilibili')) {
      final source = group.sources.single;
      return [
        for (final category in _menus[source.id] ?? const <CatalogCategory>[])
          if (!{
            'recommend',
            'series:recommend',
            'vs:variety',
            'for-you',
          }.contains(category.id))
            _CatalogChoice(category)..requests[source.id] = category.id,
      ];
    }
    if (group.id == 'hongguo' && group.sources.length == 1) {
      final source = group.sources.single;
      final menu = _menus[source.id] ?? const <CatalogCategory>[];
      final choices = <_CatalogChoice>[];
      for (final topicGroup in FeedRecommendations.topicGroups) {
        choices.add(
          _CatalogChoice(
            CatalogCategory(
              'taxonomy-group:${topicGroup.id}',
              topicGroup.label,
              local: true,
            ),
            taxonomyGroupId: topicGroup.id,
          ),
        );
        for (final topic in topicGroup.topics) {
          final rootId = switch (topic.id) {
            'live' => 'short_play',
            'manga' => 'comic_series',
            'ai' => 'ai_series',
            _ => null,
          };
          final root = rootId == null
              ? null
              : menu.where((category) => category.id == rootId).firstOrNull;
          if (root == null) {
            choices.add(
              _CatalogChoice(
                CatalogCategory(
                  'taxonomy:${topic.id}',
                  topic.label,
                  local: true,
                ),
                taxonomyTopicId: topic.id,
              ),
            );
          } else {
            choices.add(
              _CatalogChoice(
                CatalogCategory(
                  'category:${categoryName(root.name)}',
                  categoryName(root.name),
                ),
                taxonomyTopicId: topic.id,
              )..requests[source.id] = root.id,
            );
          }
        }
      }
      return choices;
    }
    final choices = <String, _CatalogChoice>{};
    for (final source in group.sources) {
      for (final category in _menus[source.id] ?? const <CatalogCategory>[]) {
        if (category.id.isEmpty) continue;
        final name = categoryName(category.name);
        final choice = choices.putIfAbsent(
          name,
          () => _CatalogChoice(CatalogCategory('category:$name', name)),
        );
        choice.requests[source.id] = category.id;
      }
    }
    final names = {
      for (final source in group.sources)
        for (final item in _library[source.id]?.values ?? const <Drama>[])
          categoryName(item.category),
    }.toList()..sort();
    for (final name in names) {
      choices.putIfAbsent(
        name,
        () => _CatalogChoice(CatalogCategory('local:$name', name, local: true)),
      );
    }
    return choices.values.toList();
  }

  List<CatalogTaxonomyGroup> taxonomyGroups(SourceGroup group) {
    if (group.id != 'hongguo' || group.sources.length != 1) return const [];
    return _taxonomyGroupCache.putIfAbsent(group.id, () {
      final choices = _choices(group);
      return [
        for (final topicGroup in FeedRecommendations.topicGroups)
          CatalogTaxonomyGroup(
            group: topicGroup,
            filter: choices
                .firstWhere((choice) => choice.taxonomyGroupId == topicGroup.id)
                .category,
            categories: [
              for (final topic in topicGroup.topics)
                choices
                    .firstWhere((choice) => choice.taxonomyTopicId == topic.id)
                    .category,
            ],
            topicIds: [for (final topic in topicGroup.topics) topic.id],
          ),
      ];
    });
  }

  List<CatalogCategory> categories(SourceGroup group) => [
    group.id == 'bilibili'
        ? const CatalogCategory('', '个性推荐')
        : group.id == 'douyin'
        ? const CatalogCategory('', '推荐')
        : group.id == 'douyin-live'
        ? const CatalogCategory('', '精选')
        : group.id == 'douyin-series'
        ? const CatalogCategory('', '推荐')
        : group.id == 'douyin-theater'
        ? const CatalogCategory('', '综艺')
        : CatalogCategory.all,
    for (final choice in _choices(group)) choice.category,
  ];

  _CatalogChoice? _choice(SourceGroup group, String category) => _choices(
    group,
  ).where((choice) => choice.category.id == category).firstOrNull;

  Future<CatalogPage> load(
    SourceGroup group, {
    String category = '',
    String query = '',
    bool more = false,
    bool force = false,
    bool useCache = false,
    bool staleWhileRefreshing = false,
    bool cacheOnly = false,
    void Function(CatalogPage)? onCached,
    Map<String, String>? categoryRequests,
  }) async {
    if (cacheOnly && (more || force || query.trim().isNotEmpty)) {
      throw AppFailure('缓存读取不能同时请求搜索或续页');
    }
    final request = ++_generation;
    for (final session in _sessions.values) {
      session.generation++;
    }
    await repository.cancelCatalog();
    if (request != _generation) throw AppFailure('已取消加载');
    if (categoryRequests != null &&
        (categoryRequests.isEmpty ||
            categoryRequests.keys.any(
              (source) => !group.sources.any((site) => site.id == source),
            ) ||
            categoryRequests.values.any((id) => id.isEmpty))) {
      throw ArgumentError.value(categoryRequests, 'categoryRequests');
    }
    final choice = categoryRequests == null && query.isEmpty
        ? _choice(group, category)
        : null;
    final requests =
        categoryRequests ??
        (choice != null && !choice.category.local
            ? choice.requests
            : {for (final source in group.sources) source.id: ''});
    final key =
        '${group.sources.map((s) => s.id).join(',')}|'
        '${categoryRequests == null
            ? choice == null
                  ? ''
                  : category
            : categoryRequests.entries.map((entry) => '${entry.key}:${entry.value}').join(',')}|$query';
    final session = _sessions.putIfAbsent(key, _CatalogSession.new);
    final generation = ++session.generation;
    final failures = <String, String>{};
    final sourceOrder = requests.keys.toList();
    for (final source in sourceOrder) {
      session.entries.putIfAbsent(source, _CatalogEntry.new);
    }

    Future<CatalogPage> snapshot() async {
      final localIds = <String, Set<String>>{};
      if (choice != null && choice.category.local) {
        for (final source in sourceOrder) {
          if (choice.taxonomyTopicId != null) {
            localIds[source] =
                _topicItems[source]?[choice.taxonomyTopicId!] ??
                const <String>{};
          } else if (choice.taxonomyGroupId != null) {
            localIds[source] =
                _topicGroupItems[source]?[choice.taxonomyGroupId!] ??
                const <String>{};
          } else {
            localIds[source] =
                _categoryItems[source]?[choice.category.name] ??
                const <String>{};
          }
        }
      }

      bool matchesChoice(String source, Drama drama) =>
          choice == null ||
          !choice.category.local ||
          localIds[source]!.contains(drama.id);

      var work = 0;
      final rows = <List<Drama>>[];
      for (final source in sourceOrder) {
        final row = <Drama>[];
        for (final drama in session.entries[source]!.items) {
          if (matchesChoice(source, drama)) row.add(drama);
          if (++work % 256 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        rows.add(row);
      }
      final items = <String, Drama>{};
      final count = rows.fold<int>(0, (count, row) => max(count, row.length));
      for (var index = 0; index < count; index++) {
        for (final row in rows) {
          if (index < row.length) items[row[index].id] = row[index];
          if (++work % 256 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
      if (choice != null && choice.category.local) {
        for (final source in sourceOrder) {
          final library = _library[source];
          for (final id in localIds[source]!) {
            final item = library?[id];
            if (item != null) items.putIfAbsent(item.id, () => item);
            if (++work % 256 == 0) {
              await Future<void>.delayed(Duration.zero);
            }
          }
        }
      }
      return CatalogPage(
        items.values.toList(),
        hasMore: sourceOrder.any((source) => session.entries[source]!.hasMore),
        page: sourceOrder.fold<int>(
          1,
          (page, source) => max(page, session.entries[source]!.page),
        ),
        fresh: sourceOrder.every((source) => session.entries[source]!.fresh),
        warning: failures.values.toSet().join('；'),
      );
    }

    if ((useCache || cacheOnly) &&
        (!force || staleWhileRefreshing) &&
        !more &&
        query.isEmpty) {
      await _each(sourceOrder, (source) async {
        try {
          final cached = await repository.cached(
            source,
            category: requests[source]!,
          );
          if (generation != session.generation || cached.items.isEmpty) return;
          final entry = session.entries[source]!;
          entry.items = cached.items;
          entry.page = cached.page;
          entry.nextPage = cached.page + 1;
          entry.hasMore = cached.hasMore || cached.warning.isNotEmpty;
          entry.fresh = cached.fresh && cached.warning.isEmpty;
          if (cached.warning.isNotEmpty) failures[source] = cached.warning;
          await _remember(source, cached.items);
        } catch (error) {
          if (cacheOnly) failures[source] = error.toString();
        }
      });
      if (generation != session.generation) return await snapshot();
      final cached = await snapshot();
      if (cached.items.isNotEmpty) onCached?.call(cached);
      if (cacheOnly) return cached;
      if (cached.fresh && cached.items.isNotEmpty && !force) return cached;
    }

    await _each(sourceOrder, (source) async {
      if (generation != session.generation) return;
      final entry = session.entries[source]!;
      if (more && !entry.hasMore) return;
      if (useCache && !force && !more && entry.fresh) return;
      final page = more ? entry.nextPage : 1;
      try {
        final result = await repository.catalog(
          source,
          category: requests[source]!,
          query: query,
          page: page,
          force: force,
        );
        if (generation != session.generation) return;
        final items = <String, Drama>{
          if (more)
            for (final item in entry.items) item.id: item,
          for (final item in result.items) item.id: item,
        };
        entry.items = items.values.toList();
        entry.page = result.page;
        entry.nextPage = result.warning.isEmpty ? result.page + 1 : page;
        entry.hasMore =
            (query.isEmpty || SourceSite.byId(source).pagedSearch) &&
            (result.hasMore || result.warning.isNotEmpty);
        entry.fresh = result.fresh && result.warning.isEmpty;
        if (query.isEmpty) await _remember(source, result.items);
        if (result.warning.isNotEmpty) {
          failures[source] = result.warning;
        } else {
          failures.remove(source);
        }
      } catch (error) {
        if (generation != session.generation) return;
        entry.nextPage = page;
        entry.hasMore = query.isEmpty || SourceSite.byId(source).pagedSearch;
        entry.fresh = false;
        failures[source] = error.toString();
      }
    });
    final result = await snapshot();
    if (result.items.isEmpty && failures.isNotEmpty) {
      throw AppFailure(result.warning);
    }
    return result;
  }
}
