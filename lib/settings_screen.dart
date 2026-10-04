import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'personalization_screen.dart';
import 'detail_screen.dart';
import 'feed_recommendation_settings_screen.dart';
import 'home_feed_preferences_screen.dart';
import 'playback_launch_screen.dart';
import 'resource_settings_screen.dart';
import 'saved_library.dart';
import 'sources_screen.dart';
import 'source_subscriptions_screen.dart';
import 'widgets.dart';
import 'settings_subpages.dart';

String storageSize(int bytes) {
  if (bytes < 0) return '暂不可用';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.bottomNavPadding = 16,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  final double bottomNavPadding;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _openDrama(BuildContext context, Drama drama, {bool download = false}) {
    if (download) {
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            downloadOnOpen: true,
          ),
        ),
      );
    } else {
      unawaited(
        openPlaybackDirectly(
          context,
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      );
    }
  }

  void _showAbout() {
    final version = AppLayout.versionOf(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/icon12.png',
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  semanticLabel: '$appName 应用图标',
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '版本 $version',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: Text('追剧收藏与观看记录保存在当前设备。', style: theme.textTheme.bodyLarge),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showLicensePage(
                  context: context,
                  applicationName: appName,
                  applicationVersion: version,
                );
              },
              child: const Text('查看许可'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (_, _) => widget.embedded
        ? _content()
        : Scaffold(
            appBar: AppBar(title: const Text('设置')),
            body: _content(),
          ),
  );

  Widget _content() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, widget.bottomNavPadding),
        children: [
          SettingsSection(
            title: '最近观看',
            children: [
              ListTile(
                key: const ValueKey('playback-recent-history'),
                leading: const Icon(Icons.history_rounded),
                title: const Text('最近观看'),
                subtitle: Text('当前设备 · ${widget.store.history.length} 部'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SavedLibrary(
                      repository: widget.repository,
                      store: widget.store,
                      history: true,
                      onOpen: (drama) => _openDrama(context, drama),
                      onContinue: (drama) => _openDrama(context, drama),
                      onDownload:
                          widget.store.canDownload &&
                              widget.repository.supportsDownloads
                          ? (drama) =>
                                _openDrama(context, drama, download: true)
                          : null,
                      bottomPadding: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: '站源管理',
            children: [
              ListTile(
                key: const ValueKey('source-management-settings'),
                leading: const Icon(Icons.dns_outlined),
                title: const Text('站源与首页信息流'),
                subtitle: const Text('站源订阅、当前站源、首页偏好、画质与猜你喜欢'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SourceManagementSettingsScreen(
                      repository: widget.repository,
                      store: widget.store,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: '播放设置',
            children: [
              ListTile(
                key: const ValueKey('playback-settings'),
                leading: const Icon(Icons.play_circle_outline_rounded),
                title: const Text('播放设置'),
                subtitle: const Text('硬件解码方式与内存占用'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PlaybackSettingsScreen(store: widget.store),
                  ),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: '常规',
            children: [
              ListTile(
                key: const ValueKey('personalization-setting'),
                leading: const Icon(Icons.palette_outlined),
                title: const Text('个性化'),
                subtitle: const Text('明暗、色彩、触感、字重与底栏'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PersonalizationScreen(store: widget.store),
                  ),
                ),
              ),
            ],
          ),
          if (widget.store.canDownload)
            SettingsSection(
              title: '下载',
              children: [
                ListTile(
                  key: const ValueKey('settings-downloads'),
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('下载设置'),
                  subtitle: const Text('下载合集、画质偏好、目录空间与完成后导出'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => DownloadSettingsScreen(
                        repository: widget.repository,
                        store: widget.store,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (widget.store.profile.admin)
            SettingsSection(
              title: '管理',
              children: [
                ListTile(
                  leading: const Icon(Icons.settings_ethernet_rounded),
                  title: const Text('网络与资源'),
                  subtitle: const Text('代理、目录请求间隔、下载并发与站源目录'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ResourceSettingsScreen(
                        repository: widget.repository,
                        store: widget.store,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (widget.store.profile.admin)
            SettingsSection(
              title: '备份',
              children: [
                ListTile(
                  key: const ValueKey('backup-settings'),
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('备份设置'),
                  subtitle: const Text('导出或恢复本地用户、追剧、历史和设置'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BackupSettingsScreen(store: widget.store),
                    ),
                  ),
                ),
              ],
            ),
          if (Platform.isIOS)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('iOS 下载和媒体处理需要保持应用在前台；切到后台会暂停，回到前台后可继续。'),
            ),
          SettingsSection(
            title: '关于',
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('关于应用'),
                subtitle: const Text('版本与本地数据说明'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _showAbout,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class SourceManagementSettingsScreen extends StatelessWidget {
  const SourceManagementSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  void _open(BuildContext context, Widget page) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('站源管理')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            if (repository.supportsSourceManagement)
              SettingsSection(
                title: '站源',
                children: [
                  ListTile(
                    key: const ValueKey('source-subscriptions-settings'),
                    leading: const Icon(Icons.extension_outlined),
                    title: const Text('站源订阅'),
                    subtitle: const Text('导入站源程序，检测和更新订阅'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        _open(context, SourceSubscriptionsScreen(store: store)),
                  ),
                  ListTile(
                    key: const ValueKey('current-sources-settings'),
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('当前站源'),
                    subtitle: const Text('管理当前启用的站源、目录更新与连接检测'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(
                      context,
                      SourcesScreen(repository: repository, store: store),
                    ),
                  ),
                ],
              ),
            SettingsSection(
              title: '首页信息流',
              children: [
                ListTile(
                  key: const ValueKey('home-feed-preferences'),
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('首页偏好'),
                  subtitle: const Text('选择首页推送的站源和分类'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(
                    context,
                    HomeFeedPreferencesScreen(
                      repository: repository,
                      store: store,
                    ),
                  ),
                ),
                _HomePlaybackQualityTile(store: store),
                ListTile(
                  key: const ValueKey('playback-feed-recommendations'),
                  leading: const Icon(Icons.auto_awesome_rounded),
                  title: const Text('猜你喜欢'),
                  subtitle: const Text('查看兴趣标签，调整首页推荐权重'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(
                    context,
                    FeedRecommendationSettingsScreen(store: store),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _HomePlaybackQualityTile extends StatelessWidget {
  const _HomePlaybackQualityTile({required this.store});

  final LocalStore store;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final preferences = store.playbackPreferences;
      final qualities =
          <int>{
            0,
            2160,
            1440,
            1080,
            720,
            480,
            360,
            preferences.homeQuality,
          }.toList()..sort((a, b) {
            if (a == 0) return -1;
            if (b == 0) return 1;
            return b.compareTo(a);
          });
      return PlaybackSelectorTile<int>(
        key: const ValueKey('home-playback-quality'),
        icon: Icons.high_quality_rounded,
        title: '首页画质',
        subtitle:
            '当前：${preferences.homeQuality == 0 ? '自动（最高）' : '${preferences.homeQuality}P'} · 仅用于首页信息流；以源站实际提供的画质为准',
        value: preferences.homeQuality,
        items: [
          for (final quality in qualities)
            DropdownMenuItem<int>(
              value: quality,
              child: Text(quality == 0 ? '自动最高' : '${quality}P'),
            ),
        ],
        onChanged: (quality) {
          if (quality == null || quality == preferences.homeQuality) return;
          unawaited(
            saveUserChange(
              context,
              () => store.setPlaybackPreferences(
                preferences.copyWith(homeQuality: quality),
              ),
            ),
          );
        },
      );
    },
  );
}

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await widget.repository.storage();
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _move() async {
    String? parent;
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      final directories = <String, String>{support.path: '应用内部存储'};
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectories() ?? [];
        for (var i = 0; i < external.length; i++) {
          directories[external[i].path] = i == 0
              ? '设备共享存储（应用目录）'
              : 'SD 卡 ${i + 1}（应用目录）';
        }
      } else {
        final documents = await getApplicationDocumentsDirectory();
        directories[documents.path] = '文件 App 可见目录';
      }
      if (!mounted) return;
      parent = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择下载位置'),
          children: [
            for (final entry in directories.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
    } else {
      parent = await FilePicker.getDirectoryPath(dialogTitle: '选择下载保存位置');
    }
    if (parent == null || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移已下载内容？'),
        content: Text(
          '将视频、合并成品及导出内容迁移到：\n$parent\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('迁移'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.moveDownloads(parent);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('下载目录与空间')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_info != null) ...[
                Text(
                  '已使用 ${storageSize((_info!['bytes'] as num?)?.toInt() ?? 0)}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '剩余 ${storageSize((_info!['free'] as num?)?.toInt() ?? -1)} · ${_info!['files'] ?? 0} 个文件',
                ),
                const SizedBox(height: 24),
                const Text('当前下载目录'),
                const SizedBox(height: 8),
                SelectableText(_info!['directory'] as String? ?? ''),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: _info!['directory'] as String? ?? ''),
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制路径'),
                ),
                const SizedBox(height: 20),
                const Text('在下载页删除不需要的分集，在本地媒体页删除合并成品或 Emby 导出，可释放空间。'),
              ],
              if (_busy || (_info == null && _error == null))
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: LinearProgressIndicator(),
                ),
              if (_busy) const Text('正在迁移，请保持应用运行…'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_error!),
                ),
              if (widget.store.profile.admin)
                FilledButton.icon(
                  onPressed: _busy ? null : _move,
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('更改并迁移目录'),
                ),
              TextButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('刷新用量'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
