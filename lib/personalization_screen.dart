import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'local_store.dart';
import 'widgets.dart';

class PersonalizationScreen extends StatelessWidget {
  const PersonalizationScreen({super.key, required this.store});

  final LocalStore store;

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          Card(
            margin: EdgeInsets.zero,
            color: colors.surfaceContainer,
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.settingsGroup),
            ),
            child: ListTileTheme(
              data: theme.listTileTheme.copyWith(
                titleTextStyle: theme.textTheme.titleMedium?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w500,
                ),
                subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              child: Column(
                children: [
                  for (var index = 0; index < children.length; index++) ...[
                    if (index > 0)
                      Divider(
                        height: 1,
                        endIndent: AppSpacing.l,
                        color: colors.outlineVariant.withValues(alpha: .55),
                      ),
                    children[index],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('个性化')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _section(context, '启动界面', [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '应用启动时打开',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: store.startupDestination,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'home', child: Text('首页')),
                          DropdownMenuItem(
                            value: 'discover',
                            child: Text('发现'),
                          ),
                          DropdownMenuItem(
                            value: 'following',
                            child: Text('收藏'),
                          ),
                          DropdownMenuItem(
                            value: 'settings',
                            child: Text('设置'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            saveUserChange(
                              context,
                              () => store.setStartupDestination(value),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text('下次打开应用时进入所选界面。'),
                ),
              ]),
              _section(context, '明暗模式', [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in const ['system', 'light', 'dark'])
                        ChoiceChip(
                          label: Text(AppTheme.label(mode)),
                          selected: store.themeMode == mode,
                          onSelected: (_) => saveUserChange(
                            context,
                            () => store.setThemeMode(mode),
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
              _section(context, '色彩方案', [
                SwitchListTile(
                  title: const Text('Material You 动态取色'),

                  value: store.dynamicColor,
                  onChanged: (value) => saveUserChange(
                    context,
                    () => store.setDynamicColor(value),
                  ),
                ),
                if (!store.dynamicColor)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in AppTheme.seedColors.entries)
                          ChoiceChip(
                            avatar: CircleAvatar(
                              backgroundColor: entry.value.$2,
                            ),
                            label: Text(entry.value.$1),
                            selected: store.themeSeed == entry.key,
                            onSelected: (_) => saveUserChange(
                              context,
                              () => store.setThemeSeed(entry.key),
                            ),
                          ),
                      ],
                    ),
                  ),
              ]),
              _section(context, '交互与排版', [
                SwitchListTile(
                  title: const Text('震动反馈'),

                  value: store.hapticFeedback,
                  onChanged: (value) => saveUserChange(
                    context,
                    () => store.setHapticFeedback(value),
                  ),
                ),
                const ListTile(
                  title: Text('字体粗细'),

                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        -100: '细体',
                        0: '标准',
                        100: '中等',
                        200: '较粗',
                        300: '粗体',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: store.fontWeightAdjustment == entry.key,
                          onSelected: (_) => saveUserChange(
                            context,
                            () => store.setFontWeightAdjustment(entry.key),
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}
