import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'background_downloads.dart';
import 'core_bridge.dart';
import 'downloads_screen.dart';
import 'home_feed_preferences_screen.dart';
import 'feed_recommendation_settings_screen.dart';
import 'local_store.dart';
import 'playback_preferences.dart';
import 'resource_settings.dart';
import 'resource_settings_screen.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';
import 'widgets.dart';
import 'webdav_backup.dart';

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
                    return _PlaybackSelectorTile<int>(
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
              ],
            ),
            _PlaybackPerformanceSettings(store: store),
          ],
        ),
      ),
    ),
  );
}

class _PlaybackPerformanceSettings extends StatefulWidget {
  const _PlaybackPerformanceSettings({required this.store});
  final LocalStore store;

  @override
  State<_PlaybackPerformanceSettings> createState() =>
      _PlaybackPerformanceSettingsState();
}

class _PlaybackPerformanceSettingsState
    extends State<_PlaybackPerformanceSettings> {
  bool _saving = false;

  Future<void> _save(
    PlaybackPreferences Function(PlaybackPreferences) update,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    await saveUserChange(
      context,
      () => widget.store.setPlaybackPreferences(
        update(widget.store.playbackPreferences),
      ),
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final preferences = widget.store.playbackPreferences;
      final supported = Platform.isAndroid || Platform.isWindows;
      final decoders = [
        HardwareDecoder.automatic,
        HardwareDecoder.copy,
        if (Platform.isAndroid) ...[
          HardwareDecoder.mediaCodec,
          HardwareDecoder.mediaCodecCopy,
        ],
        if (Platform.isWindows) ...[
          HardwareDecoder.d3d11,
          HardwareDecoder.d3d11Copy,
        ],
      ];
      return SettingsSection(
        title: '解码与内存',
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('playback-hardware-decoding'),
            secondary: const Icon(Icons.memory_rounded),
            title: const Text('硬件解码'),
            subtitle: Text(
              supported ? '使用设备视频解码能力；不支持的格式自动回退软件解码' : '当前平台保持兼容解码模式',
            ),
            value: preferences.hardwareDecoding && supported,
            onChanged: _saving || !supported
                ? null
                : (value) => _save(
                    (current) => current.copyWith(hardwareDecoding: value),
                  ),
          ),
          _PlaybackSelectorTile<HardwareDecoder>(
            icon: Icons.developer_board_outlined,
            title: '硬件解码器',
            subtitle: '通常保留自动（安全）；复制模式可改善部分设备的硬件解码兼容性',
            value: decoders.contains(preferences.hardwareDecoder)
                ? preferences.hardwareDecoder
                : HardwareDecoder.automatic,
            items: [
              for (final decoder in decoders)
                DropdownMenuItem(value: decoder, child: Text(decoder.label)),
            ],
            onChanged: _saving || !supported || !preferences.hardwareDecoding
                ? null
                : (value) {
                    if (value != null)
                      unawaited(
                        _save(
                          (current) => current.copyWith(hardwareDecoder: value),
                        ),
                      );
                  },
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('playback-low-memory'),
            secondary: const Icon(Icons.savings_outlined),
            title: const Text('低内存模式'),
            subtitle: const Text(
              '缓存从 32 MiB 降至 2 MiB，并减少首页和下一集预取；返回已离开的剧集时可能重新加载',
            ),
            value: preferences.lowMemory,
            onChanged: _saving
                ? null
                : (value) =>
                      _save((current) => current.copyWith(lowMemory: value)),
          ),
        ],
      );
    },
  );
}

class _PlaybackSelectorTile<T> extends StatelessWidget {
  const _PlaybackSelectorTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButton<T>(
                  value: value,
                  hint: hint,
                  underline: const SizedBox.shrink(),
                  items: items,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
                  key: const ValueKey('webdav-backup'),
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('WebDAV 备份'),
                  subtitle: const Text('上传或恢复 WebDAV 上的配置备份'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                WebDavBackupScreen(store: widget.store),
                          ),
                        ),
                ),
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
