import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'douyin_source.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'widgets.dart';

class DouyinCreatorScreen extends StatefulWidget {
  const DouyinCreatorScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.onPlay,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  final Future<void> Function(Drama)? onPlay;

  @override
  State<DouyinCreatorScreen> createState() => _DouyinCreatorScreenState();
}

class _DouyinCreatorScreenState extends State<DouyinCreatorScreen> {
  final _scroll = ScrollController();
  final _items = <Drama>[];
  String _name = '';
  String _avatar = '';
  String _cursor = '0';
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  final Set<String> _seen = {};
  DouyinCreatorPage? _profile;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkMore);
    unawaited(_load());
  }

  void _checkMore() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 640 &&
        _hasMore &&
        !_loading &&
        !_loadingMore) {
      unawaited(_load(more: true));
    }
  }

  Future<void> _load({bool more = false}) async {
    if (more && _loading) return;
    if (more && (!_hasMore || _loadingMore)) return;
    final generation = ++_generation;
    final epoch = widget.store.profileEpoch;
    final requestedCursor = more ? _cursor : '0';
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final page = await widget.repository.creatorVideos(
        widget.drama,
        cursor: requestedCursor,
      );
      if (!mounted ||
          generation != _generation ||
          epoch != widget.store.profileEpoch)
        return;
      setState(() {
        if (!more) {
          _items.clear();
          _seen.clear();
          _profile = page;
        }
        if (page.name.isNotEmpty) _name = page.name;
        if (page.avatar.isNotEmpty) _avatar = page.avatar;
        _cursor = page.cursor;
        _hasMore = page.hasMore && page.cursor != requestedCursor;
        for (final item in page.items) {
          if (_seen.add(item.id)) _items.add(item);
        }
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          epoch != widget.store.profileEpoch)
        return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _scroll.removeListener(_checkMore);
    _scroll.dispose();
    super.dispose();
  }

  Widget _creatorAvatar(BuildContext context) {
    final image = _avatar.isEmpty ? widget.drama.creatorAvatar : _avatar;
    return CircleAvatar(
      radius: 42,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: image.isEmpty
            ? const Icon(Icons.person_rounded, size: 36)
            : Image.network(
                image,
                width: 84,
                height: 84,
                cacheWidth: 256,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.person_rounded, size: 36),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bilibili = widget.drama.source == SourceSite.bilibili.id;
    final title = _name.isEmpty
        ? (widget.drama.creatorName.isEmpty ? '作者主页' : widget.drama.creatorName)
        : _name;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final body = CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _creatorAvatar(context),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                (_profile?.userId ?? widget.drama.creatorId)
                                        .isEmpty
                                    ? (bilibili ? '哔哩哔哩创作者' : '抖音创作者')
                                    : '${bilibili ? 'UID' : '抖音号'}：${_profile?.userId ?? widget.drama.creatorId}',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_profile != null) ...[
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 24,
                        runSpacing: 8,
                        children: [
                          if (_profile!.likes != null)
                            Text('${_number(_profile!.likes!)} 获赞'),
                          if (_profile!.following != null)
                            Text('${_number(_profile!.following!)} 关注'),
                          if (_profile!.followers != null)
                            Text('${_number(_profile!.followers!)} 粉丝'),
                        ],
                      ),
                      if (_profile!.bio.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(
                            _profile!.bio,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    AnimatedBuilder(
                      animation: widget.store,
                      builder: (context, _) => SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          onPressed: () => unawaited(
                            widget.store.toggleFavorite(widget.drama),
                          ),
                          child: Text(
                            widget.store.isFavorite(widget.drama.id)
                                ? '已关注 · 本地收藏'
                                : '关注 · 加入本地收藏',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '作品 · 已加载 ${_items.length} 条',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_error != null && _items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_search_outlined, size: 42),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _load(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_loading && _items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: AppLoadingIndicator()),
          )
        else if (_items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('暂时没有可展示的作品')),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 18,
                childAspectRatio: .64,
              ),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return Semantics(
                  button: true,
                  label: '播放${item.title}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      if (widget.onPlay case final play?) {
                        unawaited(play(item));
                        return;
                      }
                      unawaited(
                        openPlaybackDirectly(
                          context,
                          drama: item,
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SizedBox.expand(
                            child: DramaCover(
                              drama: item,
                              repository: widget.repository,
                              radius: 18,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: AppLoadingIndicator(size: 28)),
            ),
          ),
        if (_error != null && _items.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('作者主页'),
        actions: [
          IconButton(
            tooltip: '刷新作品',
            onPressed: _loading || _loadingMore ? null : () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }

  String _number(int value) =>
      value >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万' : '$value';
}
