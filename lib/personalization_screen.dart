import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'local_store.dart';
import 'widgets.dart';

class PersonalizationScreen extends StatelessWidget {
  const PersonalizationScreen({super.key, required this.store});

  final LocalStore store;

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: colors.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...children,
          ],
        ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<String>(
                    initialValue: store.startupDestination,
                    decoration: const InputDecoration(labelText: '应用启动时打开'),
                    items: const [
                      DropdownMenuItem(value: 'home', child: Text('首页')),
                      DropdownMenuItem(value: 'discover', child: Text('发现')),
                      DropdownMenuItem(value: 'following', child: Text('追剧')),
                      DropdownMenuItem(value: 'settings', child: Text('设置')),
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
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
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
                  subtitle: const Text('安卓 12+ 从壁纸取色；不支持时使用下方预设色'),
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
                  subtitle: const Text('开启后，应用内 Material 触控会提供轻触反馈'),
                  value: store.hapticFeedback,
                  onChanged: (value) => saveUserChange(
                    context,
                    () => store.setHapticFeedback(value),
                  ),
                ),
                const ListTile(
                  title: Text('字体粗细'),
                  subtitle: Text('调整应用的 Material 字阶'),
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
