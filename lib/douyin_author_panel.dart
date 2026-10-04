import 'package:flutter/material.dart';

import 'app_haptics.dart';
import 'models.dart';

class DouyinAuthorPanel extends StatelessWidget {
  const DouyinAuthorPanel({
    super.key,
    required this.drama,
    required this.onOpen,
    required this.followed,
    required this.onFollow,
  });

  final Drama drama;
  final VoidCallback onOpen;
  final bool followed;
  final VoidCallback onFollow;

  void _more(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .65,
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                drama.title,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _authorLink(Widget child, {required String label}) =>
      AppHaptics.tapTarget(
        onTap: onOpen,
        label: label,
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final name = drama.creatorName.isEmpty ? '查看作者' : drama.creatorName;
    final descriptionStyle = DefaultTextStyle.of(context).style.merge(
      const TextStyle(
        color: Colors.white,
        fontSize: 14,
        height: 1.4,
        shadows: [Shadow(color: Colors.black, blurRadius: 6)],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _authorLink(
              CircleAvatar(
                radius: 22,
                backgroundColor: Colors.white24,
                child: ClipOval(
                  child: drama.creatorAvatar.isEmpty
                      ? const Icon(Icons.person_rounded, color: Colors.white)
                      : Image.network(
                          drama.creatorAvatar,
                          width: 44,
                          height: 44,
                          cacheWidth: 144,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.person_rounded,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              label: '查看$name的个人主页',
            ),
            const SizedBox(width: 10),
            Flexible(
              child: _authorLink(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                    ),
                    if (drama.creatorId.isNotEmpty)
                      Text(
                        '${drama.source == 'bilibili' ? 'UID' : '抖音号'}：${drama.creatorId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                label: '查看$name的个人主页',
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onFollow,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 34),
              ),
              child: Text(followed ? '已关注' : '关注'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final painter = TextPainter(
              text: TextSpan(text: drama.title, style: descriptionStyle),
              maxLines: 2,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              locale: Localizations.maybeLocaleOf(context),
            )..layout(maxWidth: constraints.maxWidth);
            final truncated = painter.didExceedMaxLines;
            painter.dispose();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppHaptics.tapTarget(
                  onTap: onOpen,
                  label: '进入短视频详情',
                  child: GestureDetector(
                    excludeFromSemantics: true,
                    behavior: HitTestBehavior.opaque,
                    onTap: onOpen,
                    child: Text(
                      drama.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: descriptionStyle,
                    ),
                  ),
                ),
                if (truncated)
                  AppHaptics.tapTarget(
                    onTap: () => _more(context),
                    label: '显示完整文字内容',
                    child: GestureDetector(
                      excludeFromSemantics: true,
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _more(context),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '更多',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
