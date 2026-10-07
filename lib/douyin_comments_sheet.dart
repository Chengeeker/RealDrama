import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'douyin_source.dart';
import 'models.dart';

const _douyinEmojiFallbacks = <String, String>{
  '大笑': '😄',
  '笑哭': '😂',
  '笑哭了': '😂',
  '微笑': '😊',
  '偷笑': '🤭',
  '捂脸': '🤦',
  '捂嘴笑': '🤭',
  '尬笑': '😅',
  '奸笑': '😏',
  '害羞': '☺️',
  '可爱': '🥰',
  '暗中观察': '👀',
  '灵机一动': '💡',
  '耶': '✌️',
  '酷拽': '😎',
  '泣不成声': '😭',
  '石化': '🗿',
  '舔屏': '😍',
  '吐血': '🤮',
  '憨笑': '😁',
  '快哭了': '🥺',
  '呲牙': '😬',
  '流泪': '😢',
  '泪目': '🥹',
  '泪奔': '😭',
  '大哭': '😭',
  '发怒': '😡',
  '生气': '😠',
  '惊讶': '😮',
  '吃惊': '😲',
  '震惊': '😱',
  '疑问': '❓',
  '疑惑': '🤔',
  '思考': '🤔',
  '白眼': '🙄',
  '翻白眼': '🙄',
  '爱心': '❤️',
  '心': '❤️',
  '心碎': '💔',
  '比心': '🫰',
  '抱抱': '🤗',
  '飞吻': '😘',
  '玫瑰': '🌹',
  '点赞': '👍',
  '赞': '👍',
  '鼓掌': '👏',
  '加油': '💪',
  '打call': '🙌',
  '互粉': '🤝',
  '碰拳': '🤜🤛',
  '打脸': '🤦',
  '击掌': '🙌',
  '无辜': '🥺',
  '菜刀': '🔪',
  '草莓': '🍓',
  '熊吉': '🐻',
  '666': '🔥',
  'ok': '👌',
  'doge': '🐶',
  'like': '👍',
  'love': '❤️',
  'cry': '😢',
  'laugh': '😆',
  'smile': '😊',
  'clap': '👏',
  'wow': '😮',
  '狗头': '🐶',
  '旺柴': '🐕',
  '吃瓜': '🍉',
  '太阳': '☀️',
  '月亮': '🌙',
  '咖啡': '☕',
  '啤酒': '🍺',
  '困': '😴',
};

String _douyinEmojiText(String shortcode) {
  final name = shortcode.substring(1, shortcode.length - 1).trim();
  final key = name.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');
  return _douyinEmojiFallbacks[key] ?? name;
}

Future<void> showDouyinComments(
  BuildContext context,
  AppRepository repository,
  Drama drama,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _DouyinComments(repository: repository, drama: drama),
);

class _DouyinComments extends StatefulWidget {
  const _DouyinComments({required this.repository, required this.drama});

  final AppRepository repository;
  final Drama drama;

  @override
  State<_DouyinComments> createState() => _DouyinCommentsState();
}

class _DouyinCommentsState extends State<_DouyinComments> {
  static int _nextScope = 0;
  late final String _scope = 'douyin-comments-${++_nextScope}';
  final _items = <DouyinComment>[];
  final _ids = <String>{};
  String _cursor = '0';
  String _error = '';
  bool _loading = false;
  bool _hasMore = true;
  int? _total;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading || !_hasMore || _items.length >= 200) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final page = await widget.repository.videoComments(
        widget.drama,
        cursor: _cursor,
        requestScope: _scope,
      );
      if (!mounted) return;
      setState(() {
        var added = 0;
        for (final item in page.items) {
          if (_items.length < 200 && _ids.add(item.id)) {
            _items.add(item);
            added++;
          }
        }
        _cursor = page.cursor;
        _total = page.total;
        _hasMore = page.hasMore && added > 0 && _items.length < 200;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is DouyinFailure
            ? error.message
            : error is AppFailure
            ? error.message
            : '评论加载失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    widget.repository.cancelVideoComments(_scope);
    super.dispose();
  }

  Widget _avatar(DouyinComment item) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget fallback() => ColoredBox(
      color: colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.person_rounded,
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    return SizedBox.square(
      dimension: 36,
      child: ClipOval(
        child: item.avatar.isEmpty
            ? fallback()
            : Image.network(
                item.avatar,
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }

  Widget _commentText(String value) {
    final matches = RegExp(r'\[[^\[\]\r\n]{1,24}\]').allMatches(value);
    if (matches.isEmpty) {
      return Text(value, style: Theme.of(context).textTheme.bodyMedium);
    }
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: value.substring(offset, match.start)));
      }
      spans.add(TextSpan(text: _douyinEmojiText(match.group(0)!)));
      offset = match.end;
    }
    if (offset == 0) {
      return Text(value, style: Theme.of(context).textTheme.bodyMedium);
    }
    if (offset < value.length)
      spans.add(TextSpan(text: value.substring(offset)));
    return Text.rich(
      TextSpan(children: spans),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(_error, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('暂无文字评论')),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextButton(onPressed: _load, child: const Text('加载更多评论')),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Text(_items.length >= 200 ? '已显示前 200 条评论' : '已显示全部可查看评论'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .68,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _total == null ? '评论' : '评论 · $_total',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭评论',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _items.length + 1,
                itemBuilder: (context, index) {
                  if (index == _items.length) return _footer();
                  final item = _items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _avatar(item),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const Icon(Icons.favorite_border_rounded, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              '${item.likes}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _commentText(item.text),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
