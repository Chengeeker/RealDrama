import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'drama_actions.dart';
import 'douyin_creator_screen.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class _LibraryEntry {
  const _LibraryEntry.drama(this.drama) : creator = null;
  const _LibraryEntry.creator(this.creator) : drama = null;

  final Drama? drama;
  final FollowedCreator? creator;
  String get key => drama?.id ?? 'creator:${creator!.id}';
}

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
    this.bottomPadding = 16,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;
  final double bottomPadding;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();
  String _filter = 'all';
  String _statusFilter = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('这会删除当前用户的观看进度；作品收藏、作者关注和手动已看标记会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    history: widget.history,
    onContinue: () => widget.onContinue(drama),
    onDownload: widget.onDownload == null
        ? null
        : () => widget.onDownload!(drama),
  );

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final kind = SourceSite.libraryKindFor(drama.source);
    final watched = widget.store.watched(drama.id);
    final state = kind == 'drama' ? widget.store.following(drama.id) : null;
    final badge = state == null
        ? null
        : '${state.label}${state.hasUpdates ? ' · ${state.updateLabel}' : ''}';
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => widget.onOpen(drama),
      hapticOnTap: widget.history,
      onMore: () => _actions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _actions(drama),
      ),
      badge: badge,
      subtitle: watched == null
          ? '${switch (kind) {
              'video' => '视频',
              'live' => '直播',
              _ => '剧集',
            }} · ${SourceSite.byId(drama.source).name}'
          : kind == 'drama'
          ? '第 ${watched.episode} 集 · ${formatPosition(watched.position)}'
          : '播放至 ${formatPosition(watched.position)}',
    );
  }

  void _openCreator(FollowedCreator creator) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DouyinCreatorScreen(
          drama: creator.anchor,
          repository: widget.repository,
          store: widget.store,
          onPlay: (drama) async => widget.onOpen(drama),
        ),
      ),
    );
  }

  Widget _creatorTile(
    FollowedCreator creator, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final television = AppLayout.isTelevision(context);
    final nameHeight = DramaTile.titleHeight(context);
    final subtitleHeight = DramaTile.subtitleHeight(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 38,
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    foregroundImage: creator.avatar.isEmpty
                        ? null
                        : ResizeImage(NetworkImage(creator.avatar), width: 128),
                    onForegroundImageError: creator.avatar.isEmpty
                        ? null
                        : (_, _) {},
                    child: creator.avatar.isEmpty
                        ? const Icon(Icons.person_rounded, size: 42)
                        : null,
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton.filledTonal(
                    tooltip: '取消本地关注',
                    onPressed: () => saveUserChange(
                      context,
                      () => widget.store.toggleCreatorFollow(creator.anchor),
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: .64),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(40, 40),
                      padding: const EdgeInsets.all(8),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.person_remove_alt_1_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        SizedBox(
          height: nameHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              creator.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                height: 1.3,
                fontSize: television ? 17 : 14,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: subtitleHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '${SourceSite.byId(creator.source).name} · 本地关注',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: television ? 14 : 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
    if (television) {
      return RemoteTarget(
        key: ValueKey('saved-creator-${creator.id}'),
        focusNode: focusNode,
        onFocus: onFocus,
        onPressed: () => _openCreator(creator),
        label: '${creator.name}，作者，本地关注',
        child: content,
      );
    }
    return Semantics(
      button: true,
      label: '${creator.name}，作者，本地关注',
      child: InkWell(
        key: ValueKey('saved-creator-${creator.id}'),
        onTap: () => _openCreator(creator),
        onLongPress: () => saveUserChange(
          context,
          () => widget.store.toggleCreatorFollow(creator.anchor),
        ),
        borderRadius: BorderRadius.circular(14),
        child: content,
      ),
    );
  }

  Widget _entryTile(
    _LibraryEntry entry, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final drama = entry.drama;
    if (drama != null) {
      return _tile(drama, focusNode: focusNode, onFocus: onFocus);
    }
    return _creatorTile(entry.creator!, focusNode: focusNode, onFocus: onFocus);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final history = widget.store.history;
      final favorites = widget.history ? <Drama>[] : widget.store.favorites;
      final creators = widget.history
          ? <FollowedCreator>[]
          : widget.store.followedCreators;
      final typeCounts = <String, int>{};
      for (final drama in favorites) {
        final kind = SourceSite.libraryKindFor(drama.source);
        typeCounts[kind] = (typeCounts[kind] ?? 0) + 1;
      }
      final categories = <(String, String)>[
        ('all', '全部'),
        if ((typeCounts['drama'] ?? 0) > 0) ('drama', '剧集'),
        if ((typeCounts['video'] ?? 0) > 0) ('video', '视频'),
        if (creators.isNotEmpty) ('creators', '作者'),
        if ((typeCounts['live'] ?? 0) > 0) ('live', '直播'),
      ];
      final activeFilter =
          widget.history || categories.any((item) => item.$1 == _filter)
          ? _filter
          : 'all';
      bool matchesCreator(FollowedCreator creator) {
        final fields = normalizedSearchText(
          '${creator.name} ${creator.creatorId} ${creator.creatorSecUid} ${SourceSite.byId(creator.source).name}',
        );
        final terms = _search.text
            .trim()
            .split(RegExp(r'\s+'))
            .map(normalizedSearchText)
            .where((term) => term.isNotEmpty);
        return terms.every(fields.contains);
      }

      final entries = <_LibraryEntry>[];
      if (widget.history) {
        for (final entry in history) {
          if (matchesDramaQuery(entry.drama, _search.text)) {
            entries.add(_LibraryEntry.drama(entry.drama));
          }
        }
      } else {
        for (final drama in favorites) {
          final kind = SourceSite.libraryKindFor(drama.source);
          if (activeFilter != 'all' && activeFilter != kind) continue;
          if (!matchesDramaQuery(drama, _search.text)) continue;
          if (kind == 'drama' &&
              activeFilter == 'drama' &&
              _statusFilter.isNotEmpty) {
            final state = widget.store.following(drama.id);
            if (_statusFilter == 'updates'
                ? state?.hasUpdates != true
                : state?.status.name != _statusFilter) {
              continue;
            }
          }
          entries.add(_LibraryEntry.drama(drama));
        }
        if (activeFilter == 'all' || activeFilter == 'creators') {
          for (final creator in creators) {
            if (matchesCreator(creator)) {
              entries.add(_LibraryEntry.creator(creator));
            }
          }
        }
      }
      final allCount = widget.history
          ? history.length
          : favorites.length + creators.length;
      final header = [
        if (!widget.history)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey('favorites-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索收藏',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () => setState(_search.clear),
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
        if (!widget.history)
          SizedBox(
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  for (final filter in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('library-filter-${filter.$1}'),
                        label: Text(filter.$2),
                        selected: activeFilter == filter.$1,
                        onSelected: (_) => setState(() => _filter = filter.$1),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (!widget.history && activeFilter == 'drama')
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (final filter in [
                  ('', '全部状态'),
                  for (final status in FollowStatus.values)
                    (status.name, status.label),
                  ('updates', '有更新'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('series-status-filter-${filter.$1}'),
                      label: Text(filter.$2),
                      selected: _statusFilter == filter.$1,
                      onSelected: (_) =>
                          setState(() => _statusFilter = filter.$1),
                    ),
                  ),
              ],
            ),
          ),
      ];
      final empty = StatusPanel(
        title: allCount == 0
            ? widget.history
                  ? '还没有观看记录'
                  : '还没有收藏'
            : '没有匹配的记录',
        message: allCount == 0 ? '在发现页收藏作品，或关注感兴趣的创作者。' : '可以更换搜索词或筛选条件。',
        icon: widget.history
            ? Icons.history_rounded
            : Icons.bookmark_border_rounded,
      );
      final viewPadding = MediaQuery.viewPaddingOf(context);
      final padding = MediaQuery.paddingOf(context);
      final topInset = padding.top > viewPadding.top
          ? padding.top
          : viewPadding.top;
      final searchBar = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SizedBox(
          height: 56,
          child: TextField(
            key: const ValueKey('history-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索观看记录',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
      );
      final historyHeaderExtent = viewPadding.top + kToolbarHeight + 68;
      final libraryContent = Padding(
        padding: EdgeInsets.only(top: widget.history ? 0 : topInset + 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (AppLayout.isTelevision(context)) {
              final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
                1,
                8,
              );
              final tileWidth =
                  (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
              return Column(
                children: [
                  if (widget.history) SizedBox(height: historyHeaderExtent),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .5,
                    ),
                    child: SingleChildScrollView(
                      child: Column(children: header),
                    ),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? empty
                        : Padding(
                            padding: EdgeInsets.only(
                              top: widget.history ? 8 : 0,
                            ),
                            child: RemoteGrid(
                              key: ValueKey(
                                'saved-tv-${widget.history}-$activeFilter-${_search.text}',
                              ),
                              itemKeys: entries
                                  .map((item) => item.key)
                                  .toList(),
                              columns: columns,
                              itemExtent:
                                  DramaTile.extentFor(context, tileWidth - 14) +
                                  14,
                              itemBuilder: (_, index, node, onFocus) =>
                                  _entryTile(
                                    entries[index],
                                    focusNode: node,
                                    onFocus: onFocus,
                                  ),
                            ),
                          ),
                  ),
                ],
              );
            }
            final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
            return CustomScrollView(
              key: PageStorageKey(
                'saved-${widget.history}-$activeFilter-${_search.text}',
              ),
              slivers: [
                if (widget.history)
                  SliverToBoxAdapter(
                    child: SizedBox(height: historyHeaderExtent),
                  ),
                SliverToBoxAdapter(child: Column(children: header)),
                if (entries.isEmpty)
                  SliverFillRemaining(hasScrollBody: false, child: empty)
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      padding,
                      widget.history ? 8 : 0,
                      padding,
                      widget.bottomPadding,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: dramaGridDelegate(
                        context,
                        constraints.maxWidth - 2 * padding,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _entryTile(entries[index]),
                        childCount: entries.length,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
      if (!widget.history) return libraryContent;
      final theme = Theme.of(context);
      final appBarColor =
          theme.appBarTheme.backgroundColor ?? theme.scaffoldBackgroundColor;
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text('最近观看 · $allCount'),
          actions: [
            if (history.isNotEmpty)
              IconButton(
                tooltip: '清空观看记录',
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(68),
            child: searchBar,
          ),
          backgroundColor: appBarColor.withValues(alpha: .45),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          flexibleSpace: FrostedGradientSurface(
            color: appBarColor,
            dividerColor: theme.colorScheme.outlineVariant,
            child: const SizedBox.expand(),
          ),
        ),
        body: libraryContent,
      );
    },
  );
}
