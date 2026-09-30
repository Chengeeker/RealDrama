import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'background_downloads.dart';
import 'core_bridge.dart';
import 'downloads_screen.dart';
import 'detail_screen.dart';
import 'home_feed_preferences_screen.dart';
import 'feed_recommendation_settings_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'resource_settings.dart';
import 'resource_settings_screen.dart';
import 'saved_library.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';
import 'widgets.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: colors.surfaceContainerLow,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                indent: 20,
                endIndent: 20,
                color: colors.outlineVariant.withValues(alpha: .45),
              ),
            children[index],
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  void _openDrama(BuildContext context, Drama drama, {bool download = false}) {
    if (download) {
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: drama,
            repository: repository,
            store: store,
            downloadOnOpen: true,
          ),
        ),
      );
    } else {
      unawaited(
        openPlaybackDirectly(
          context,
          drama: drama,
          repository: repository,
          store: store,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            SettingsSection(
              title: '播放与信息流',
              children: [
                if (repository.supportsSourceManagement)
                  ListTile(
                    key: const ValueKey('playback-source-management'),
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('站源管理'),
                    subtitle: const Text('管理站源显示、更新与连接检测'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SourcesScreen(repository: repository, store: store),
                      ),
                    ),
                  ),
                ListTile(
                  key: const ValueKey('home-feed-preferences'),
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('首页偏好'),
                  subtitle: const Text('只推送已启用站源和所选分类'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => HomeFeedPreferencesScreen(
                        repository: repository,
                        store: store,
                      ),
                    ),
                  ),
                ),
                AnimatedBuilder(
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
                    return ListTile(
                      key: const ValueKey('home-playback-quality'),
                      leading: const Icon(Icons.high_quality_rounded),
                      title: const Text('首页画质'),
                      subtitle: Text(
                        '当前：${preferences.homeQuality == 0 ? '自动（最高）' : '${preferences.homeQuality}P'} · 仅用于首页信息流；以源站实际提供的画质为准',
                      ),
                      trailing: DropdownButton<int>(
                        value: preferences.homeQuality,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final quality in qualities)
                            DropdownMenuItem<int>(
                              value: quality,
                              child: Text(
                                quality == 0 ? '自动最高' : '${quality}P',
                              ),
                            ),
                        ],
                        onChanged: (quality) {
                          if (quality == null ||
                              quality == preferences.homeQuality) {
                            return;
                          }
                          unawaited(
                            saveUserChange(
                              context,
                              () => store.setPlaybackPreferences(
                                preferences.copyWith(homeQuality: quality),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('playback-feed-recommendations'),
                  leading: const Icon(Icons.auto_awesome_rounded),
                  title: const Text('猜你喜欢'),
                  subtitle: const Text('查看兴趣标签，调整首页推荐权重'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          FeedRecommendationSettingsScreen(store: store),
                    ),
                  ),
                ),
                ListTile(
                  key: const ValueKey('playback-recent-history'),
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('最近观看'),
                  subtitle: Text('当前设备 · ${store.history.length} 部'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SavedLibrary(
                        repository: repository,
                        store: store,
                        history: true,
                        onOpen: (drama) => _openDrama(context, drama),
                        onContinue: (drama) => _openDrama(context, drama),
                        onDownload:
                            store.canDownload && repository.supportsDownloads
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
          ],
        ),
      ),
    ),
  );
}

class DownloadSettingsScreen extends StatefulWidget {
  const DownloadSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<DownloadSettingsScreen> createState() => _DownloadSettingsScreenState();
}

class _DownloadSettingsScreenState extends State<DownloadSettingsScreen> {
  bool _busy = false;
  String? _message;
  ResourceSettings? _resourceSettings;
  bool _resourceLoading = false;
  bool _resourceSaving = false;
  String? _resourceError;

  @override
  void initState() {
    super.initState();
    if (widget.store.profile.admin) _loadResourceSettings();
  }

  Future<void> _loadResourceSettings() async {
    setState(() {
      _resourceLoading = true;
      _resourceError = null;
    });
    try {
      final settings = await widget.repository.resourceSettings();
      if (mounted) setState(() => _resourceSettings = settings);
    } catch (error) {
      if (mounted) setState(() => _resourceError = '$error');
    } finally {
      if (mounted) setState(() => _resourceLoading = false);
    }
  }

  Future<void> _setDownloadBySource(bool value) async {
    final current = _resourceSettings;
    if (_resourceSaving || current == null) return;
    setState(() {
      _resourceSaving = true;
      _resourceError = null;
    });
    try {
      final saved = await widget.repository.saveResourceSettings(
        ResourceSettings(
          proxyMode: current.proxyMode,
          proxyUrl: current.proxyUrl,
          catalogConcurrency: current.catalogConcurrency,
          catalogIntervalMs: current.catalogIntervalMs,
          downloadConcurrency: current.downloadConcurrency,
          downloadBySource: value,
        ),
      );
      if (mounted) setState(() => _resourceSettings = saved);
    } catch (error) {
      if (mounted) setState(() => _resourceError = '$error');
    } finally {
      if (mounted) setState(() => _resourceSaving = false);
    }
  }

  Future<void> _setAutoExport(bool value) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (value) await BackgroundDownloads.ensureStarted();
      await widget.store.setAutoExport(value);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('下载设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              SettingsSection(
                title: '下载任务',
                children: [
                  ListTile(
                    key: const ValueKey('download-collection'),
                    leading: const Icon(Icons.download_rounded),
                    title: const Text('下载合集'),
                    subtitle: const Text('查看、继续与管理下载任务'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => DownloadsScreen(
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('下载偏好'),
                    subtitle: Text(
                      widget.store.downloadPreferences.qualityLabel,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            DownloadPreferencesScreen(store: widget.store),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('下载目录与空间'),
                    subtitle: const Text('查看存储用量、迁移已下载文件'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => StorageScreen(
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
                  title: '保存方式',
                  children: [
                    if (_resourceLoading)
                      const ListTile(
                        leading: SizedBox(
                          width: 24,
                          height: 24,
                          child: AppLoadingIndicator(size: 24, strokeWidth: 2),
                        ),
                        title: Text('正在读取下载保存设置'),
                      )
                    else if (_resourceSettings != null)
                      SwitchListTile(
                        value: _resourceSettings!.downloadBySource,
                        title: const Text('按站源分类保存'),
                        subtitle: const Text('新下载任务放入各站源的子目录，已有下载继续使用原位置。'),
                        onChanged: _resourceSaving
                            ? null
                            : _setDownloadBySource,
                      )
                    else
                      ListTile(
                        title: const Text('无法读取下载保存设置'),
                        subtitle: Text(_resourceError ?? '请重试'),
                        trailing: IconButton(
                          tooltip: '重试',
                          onPressed: _resourceLoading
                              ? null
                              : _loadResourceSettings,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ),
                    if (_resourceError != null && _resourceSettings != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          _resourceError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              if (widget.store.profile.admin)
                SettingsSection(
                  title: '完成后处理',
                  children: [
                    SwitchListTile(
                      value: widget.store.autoExport,
                      title: const Text('下载完成后自动导出 Emby'),
                      subtitle: const Text(
                        '在下载目录的 exports 中生成视频和海报 URL 元数据，可将该目录加入 Emby 媒体库。',
                      ),
                      onChanged: _busy ? null : _setAutoExport,
                    ),
                    SwitchListTile(
                      value: widget.store.exportPosters,
                      title: const Text('同时导出海报文件'),
                      subtitle: const Text('默认只写海报 URL。源站海报需要解密或外部读取失败时可开启。'),
                      onChanged: _busy
                          ? null
                          : (value) => saveUserChange(
                              context,
                              () => widget.store.setExportPosters(value),
                            ),
                    ),
                  ],
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_message!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _backup(bool restore) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!restore) {
        final content = await widget.store.exportBackup();
        final saved = await FilePicker.saveFile(
          fileName:
              '$appSlug-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json',
          bytes: Uint8List.fromList(utf8.encode(content)),
          mimeType: 'application/json',
        );
        if (saved != null && mounted) setState(() => _message = '备份已保存');
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (file == null || !mounted) return;
        final size = await file.length();
        if (size == null || size > 8 * 1024 * 1024) {
          throw const FormatException('备份文件过大或无法读取');
        }
        final content = utf8.decode(await file.readAsBytes());
        final data = widget.store.validateBackup(content);
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复备份？'),
            content: Text(
              '包含 ${(data['profiles'] as List).length} 个用户。将替换本机的用户、追剧、观看记录和偏好设置；已下载视频保留。恢复后使用备份内的管理员密码登录。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('恢复'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await widget.store.importBackup(content);
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('备份设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            SettingsSection(
              title: '配置备份',
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('导出配置备份'),
                  subtitle: const Text('包含本地用户、追剧、历史和设置，不含视频文件'),
                  onTap: _busy ? null : () => _backup(false),
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('恢复配置备份'),
                  subtitle: const Text('从 JSON 文件恢复本地配置'),
                  onTap: _busy ? null : () => _backup(true),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(_message!),
              ),
          ],
        ),
      ),
    ),
  );
}
