import 'source_subscriptions_screen.dart';
import 'douyin_settings_screen.dart';
import 'douyin_source.dart';
import 'bilibili_settings_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'source_status.dart';

String sourceTimestamp(DateTime? value) {
  if (value == null) return '尚无记录';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

String sourcePageSummary(SourceStatus status) {
  final page = status.page > 0 ? status.page : 1;
  if (status.totalPages > 0) {
    if (page >= status.totalPages) {
      return '共 ${status.totalPages} 页 · 已全部加载';
    }
    return status.hasMore
        ? '已加载至第 $page/${status.totalPages} 页 · 可继续加载'
        : '已加载至第 $page/${status.totalPages} 页 · 暂无后续页';
  }
  return status.hasMore ? '已加载至第 $page 页 · 总页数未知，可继续加载' : '共 $page 页 · 已全部加载';
}

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _statuses = <String, SourceStatus>{};
  final _errors = <String, String>{};
  final _pending = <String>{};
  final _visibilityPending = <String>{};
  final _revisions = <String, int>{};
  final _expandedHealth = <String>{};
  final _expandedSections = <String>{};
  final _pollingSources = <String>{};
  Timer? _timer;
  bool _polling = false;
  String? _bulkOperation;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialSource != null &&
        SourceGroup.fromSources(widget.store.sources).any(
          (group) =>
              group.id == 'huangguo' &&
              group.sources.any((source) => source.id == widget.initialSource),
        )) {
      _expandedSections.add('source-group-huangguo');
    }
    if (widget.initialSource != null &&
        SourceSite.byId(widget.initialSource!).isDouyin) {
      _expandedSections.add('source-group-douyin');
    }
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
        return;
      _ticks++;
      if (_statuses.values.any((status) => status.retryAt != null)) {
        setState(() {});
      }
      if (_ticks % 2 == 0 &&
          (_statuses.values.any((status) => status.running) ||
              _ticks % 10 == 0)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      await Future.wait([
        for (final source in widget.store.sources) _refreshSource(source),
      ]);
    } finally {
      _polling = false;
    }
  }

  Future<void> _refreshSource(SourceSite source) async {
    if (!_pollingSources.add(source.id)) return;
    final epoch = widget.store.profileEpoch;
    final revision = _revisions[source.id] ?? 0;
    try {
      final status = await widget.repository.sourceStatus(source.id);
      if (!mounted ||
          epoch != widget.store.profileEpoch ||
          revision != (_revisions[source.id] ?? 0)) {
        return;
      }
      if (_statuses[source.id]?.revision == status.revision &&
          !_errors.containsKey(source.id))
        return;
      setState(() {
        _statuses[source.id] = status;
        _errors.remove(source.id);
      });
    } catch (error) {
      if (mounted &&
          epoch == widget.store.profileEpoch &&
          revision == (_revisions[source.id] ?? 0)) {
        setState(() => _errors[source.id] = error.toString());
      }
    } finally {
      _pollingSources.remove(source.id);
    }
  }

  List<SourceSite> get _douyinSources =>
      SourceSite.values.where((source) => source.isDouyin).toList();

  List<SourceGroup> _managementGroups(List<SourceSite> sources) {
    final groups = <SourceGroup>[];
    var douyinAdded = false;
    for (final group in SourceGroup.fromSources(sources)) {
      if (group.sources.any((source) => source.isDouyin)) {
        if (!douyinAdded) {
          groups.add(SourceGroup('douyin-family', '抖音', _douyinSources));
          douyinAdded = true;
        }
      } else {
        groups.add(group);
      }
    }
    return groups;
  }

  Future<void> _configureDouyin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DouyinSettingsScreen(
          store: widget.store,
          repository: widget.repository,
        ),
      ),
    );
    if (mounted) {
      for (final source in _douyinSources) {
        if (widget.store.allowsSource(source.id)) {
          unawaited(_refreshSource(source));
        }
      }
    }
  }

  Future<void> _configureBilibili() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BilibiliSettingsScreen(
          store: widget.store,
          repository: widget.repository,
        ),
      ),
    );
    if (mounted && widget.store.allowsSource(SourceSite.bilibili.id)) {
      unawaited(_refreshSource(SourceSite.bilibili));
    }
  }

  Future<void> _setVisible(SourceSite source, bool visible) =>
      _setVisibility([source], visible);

  Future<void> _setVisibility(List<SourceSite> sources, bool visible) async {
    if (sources.any((source) => _visibilityPending.contains(source.id))) return;
    final epoch = widget.store.profileEpoch;
    final ids = sources.map((source) => source.id).toSet();
    setState(() => _visibilityPending.addAll(ids));
    try {
      if (visible && sources.any((source) => source.isDouyin)) {
        var cookie = await DouyinSource.storage.read(
          key: DouyinSource.cookieKey(widget.store.profile.id),
        );
        if (!mounted ||
            epoch != widget.store.profileEpoch ||
            widget.store.locked)
          return;
        if (cookie?.isNotEmpty != true) {
          await _configureDouyin();
          if (!mounted ||
              epoch != widget.store.profileEpoch ||
              widget.store.locked)
            return;
          cookie = await DouyinSource.storage.read(
            key: DouyinSource.cookieKey(widget.store.profile.id),
          );
          if (cookie?.isNotEmpty != true) return;
        }
      }
      if (!mounted || epoch != widget.store.profileEpoch || widget.store.locked)
        return;
      await widget.store.setSourcesVisible({
        for (final source in sources) source.id: visible,
      });
      if (!mounted || epoch != widget.store.profileEpoch) return;
      for (final source in sources) {
        if (visible) {
          unawaited(_refreshSource(source));
        } else {
          _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
          unawaited(_cancelHiddenSourceJob(source));
        }
      }
    } catch (error) {
      if (mounted && epoch == widget.store.profileEpoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存站源显示设置失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _visibilityPending.removeAll(ids));
    }
  }

  Widget _douyinVisibility() {
    final sources = _douyinSources;
    final enabled = sources
        .where((source) => widget.store.allowsSource(source.id))
        .length;
    final busy = sources.any(
      (source) => _visibilityPending.contains(source.id),
    );
    return ListTile(
      key: const ValueKey('visible-douyin-family'),
      title: const Text('抖音'),
      subtitle: Text('已开启 $enabled/${sources.length} · 子项在下方管理'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '统一配置抖音 Cookie',
            icon: const Icon(Icons.manage_accounts_outlined),
            onPressed: busy ? null : _configureDouyin,
          ),
          Switch(
            value: enabled > 0,
            onChanged: busy
                ? null
                : (visible) => _setVisibility(sources, visible),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelHiddenSourceJob(SourceSite source) async {
    if (!widget.repository.supportsSourceManagement) return;
    try {
      await widget.repository.cancelSourceJob(source.id);
    } catch (_) {}
  }

  Future<void> _run(SourceSite source, String operation) async {
    if (_pending.contains(source.id) ||
        operation != 'cancel' && !widget.store.allowsSource(source.id)) {
      return;
    }
    final epoch = widget.store.profileEpoch;
    setState(() {
      _pending.add(source.id);
      _errors.remove(source.id);
      _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
      if (operation == 'check' || operation == 'checkCatalog') {
        _expandedHealth.add(source.id);
      } else if (operation == 'cancel') {
        _expandedHealth.remove(source.id);
      }
    });
    try {
      final status = operation == 'cancel'
          ? await widget.repository.cancelSourceJob(source.id)
          : await widget.repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == widget.drama?.source ? widget.drama : null,
            );
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _statuses[source.id] = status);
      }
    } catch (error) {
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _errors[source.id] = error.toString());
      }
    } finally {
      if (mounted) setState(() => _pending.remove(source.id));
    }
  }

  Future<void> _runAll(String operation) async {
    if (_bulkOperation != null || !widget.repository.supportsSourceManagement) {
      return;
    }
    setState(() => _bulkOperation = operation);
    try {
      for (final source in widget.store.sources) {
        if (!mounted) return;
        await _run(source, operation);
      }
    } finally {
      if (mounted) setState(() => _bulkOperation = null);
    }
  }

  Future<void> _copy(SourceSite source, SourceStatus status) async {
    final text = StringBuffer('${source.name}\n');
    text.writeln(
      '缓存 ${status.count} 部，更新 ${sourceTimestamp(status.updatedAt)}',
    );
    final health = status.health;
    if (health != null) {
      text.writeln('${health.label} · ${sourceTimestamp(health.checkedAt)}');
      if (health.sample.isNotEmpty) text.writeln('检测剧集：${health.sample}');
      for (final step in health.steps) {
        text.writeln('${step.name}：${step.message}');
        text.writeln(
          '${step.host} HTTP ${step.httpStatus} · ${step.elapsedMs} ms',
        );
        if (step.cfRay.isNotEmpty) text.writeln('CF Ray: ${step.cfRay}');
      }
    }
    if (status.error.isNotEmpty) text.writeln(status.error);
    if (status.storageError.isNotEmpty) text.writeln(status.storageError);
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
    }
  }

  Widget _expandableSection({
    required String section,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    EdgeInsets childrenPadding = const EdgeInsets.all(8),
  }) {
    final expanded = _expandedSections.contains(section);
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('section-$section'),
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
              onTap: () => setState(() {
                if (expanded) {
                  _expandedSections.remove(section);
                } else {
                  _expandedSections.add(section);
                }
              }),
            ),
          ),
          if (expanded)
            Padding(
              padding: childrenPadding,
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final sources =
          SourceSite.values
              .where(
                (source) =>
                    source.isDouyin || widget.store.allowsSource(source.id),
              )
              .toList()
            ..sort((a, b) {
              final aFirst = a.id == widget.initialSource ? 0 : 1;
              final bFirst = b.id == widget.initialSource ? 0 : 1;
              final priority = aFirst.compareTo(bFirst);
              return priority != 0
                  ? priority
                  : SourceSite.values
                        .indexOf(a)
                        .compareTo(SourceSite.values.indexOf(b));
            });
      final visibleGroups = SourceSite.values
          .where((source) => widget.store.allowsSource(source.id))
          .map((source) => source.isDouyin ? 'douyin-family' : source.id)
          .toSet()
          .length;
      final totalGroups = SourceSite.values
          .map((source) => source.isDouyin ? 'douyin-family' : source.id)
          .toSet()
          .length;
      final viewPaddingBottom = MediaQuery.viewPaddingOf(context).bottom;
      final paddingBottom = MediaQuery.paddingOf(context).bottom;
      final bottomInset = viewPaddingBottom > paddingBottom
          ? viewPaddingBottom
          : paddingBottom;
      return Scaffold(
        appBar: AppBar(
          title: const Text('站源管理'),
          actions: [
            IconButton(tooltip: '站源订阅与更新', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourceSubscriptionsScreen(store: widget.store))), icon: const Icon(Icons.extension_outlined)),
            IconButton(
              tooltip: '同步全部内容',
              onPressed:
                  _bulkOperation == null &&
                      widget.repository.supportsSourceManagement
                  ? () => _runAll('update')
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '一键检测',
              onPressed:
                  _bulkOperation == null &&
                      widget.repository.supportsSourceManagement
                  ? () => _runAll('check')
                  : null,
              icon: const Icon(Icons.wifi_rounded),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
                children: [
                  Card.outlined(child: ListTile(leading: const Icon(Icons.extension_outlined), title: const Text('站源订阅'), subtitle: const Text('从 GitHub 或独立链接导入，检查和更新站源程序'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourceSubscriptionsScreen(store: widget.store))))),
                  const SizedBox(height: 12),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '各站源可分别更新和检测。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；“加载后续所有页”会逐页低频请求，同一时间只运行一个站源，最多连续加载 1000 页或 30 分钟。遇到限流、超时或错误会停止并保留已加载内容，也可随时手动停止。',
                    ),
                  ),
                  _expandableSection(
                    section: 'source-visibility',
                    icon: Icons.visibility_outlined,
                    title: '显示的站源',
                    subtitle: '已显示 $visibleGroups/$totalGroups · 点击选择隐藏',
                    children: [
                      for (final source in SourceSite.values)
                        if (source.id == SourceSite.douyin.id)
                          _douyinVisibility()
                        else if (!source.isDouyin)
                          ListTile(
                            key: ValueKey('visible-${source.id}'),
                            title: Text(source.name),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: widget.store.allowsSource(source.id),
                                  onChanged: (visible) =>
                                      _setVisible(source, visible),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (widget.store.sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有已开启的站源，请先导入订阅或开启已安装站源'),
                    ),
                  for (final group in _managementGroups(sources))
                    if (group.id == 'douyin-family')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _expandableSection(
                          section: 'source-group-douyin',
                          icon: Icons.video_library_outlined,
                          title: '抖音',
                          subtitle: '短视频、直播、短剧、放映厅 · 共用一个 Cookie',
                          children: [
                            for (final source in group.sources)
                              _sourceCard(source),
                          ],
                        ),
                      )
                    else if (group.id == 'huangguo')
                      _expandableSection(
                        section: 'source-group-huangguo',
                        icon: Icons.hub_outlined,
                        title: '黄果',
                        subtitle:
                            '${group.sources.length} 个入口 · ${group.sources.fold<int>(0, (count, source) => count + (_statuses[source.id]?.count ?? 0))} 部',
                        childrenPadding: const EdgeInsets.all(8),
                        children: [
                          for (final source in group.sources)
                            _sourceCard(source),
                        ],
                      )
                    else
                      for (final source in group.sources) _sourceCard(source),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _sourceCard(SourceSite source) {
    final visible = widget.store.allowsSource(source.id);
    if (source.isDouyin && !visible) {
      return Card(
        elevation: 0,
        child: ListTile(
          title: Text(
            source.id == SourceSite.douyin.id ? '抖音短视频' : source.name,
          ),
          subtitle: const Text('已关闭'),
          trailing: Switch(
            value: false,
            onChanged: _visibilityPending.contains(source.id)
                ? null
                : (value) => _setVisible(source, value),
          ),
        ),
      );
    }
    final status = _statuses[source.id];
    final pending = _pending.contains(source.id);
    final busy = pending || status?.running == true;
    final seconds = status?.retrySeconds ?? 0;
    final enabled =
        !busy &&
        seconds == 0 &&
        _bulkOperation == null &&
        widget.repository.supportsSourceManagement;
    final error = _errors[source.id] ?? status?.error ?? '';
    final health = status?.health;
    final healthExpanded = _expandedHealth.contains(source.id);
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('source-${source.id}'),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dns_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    source.id == SourceSite.douyin.id ? '抖音短视频' : source.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${status?.count ?? 0} ${source.id == SourceSite.douyinLive.id ? '个直播间' : '部'}',
                ),
                if (source.id == SourceSite.bilibili.id)
                  IconButton(
                    tooltip: '哔哩哔哩 Cookie 设置',
                    onPressed: _configureBilibili,
                    icon: const Icon(Icons.key_outlined),
                  ),
                if (source.isDouyin)
                  Switch(
                    value: visible,
                    onChanged: _visibilityPending.contains(source.id)
                        ? null
                        : (value) => _setVisible(source, value),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('最近更新：${sourceTimestamp(status?.updatedAt)}'),
            if (status != null &&
                (status.count > 0 || status.page > 1 || status.totalPages > 0))
              Text(sourcePageSummary(status)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton.filledTonal(
                  key: ValueKey('update-${source.id}'),
                  tooltip: '更新',
                  onPressed: enabled ? () => _run(source, 'update') : null,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton.outlined(
                  key: ValueKey('check-${source.id}'),
                  tooltip: '检测连接与播放',
                  onPressed: enabled ? () => _run(source, 'check') : null,
                  icon: const Icon(Icons.wifi_rounded),
                ),
                if (status?.running == true)
                  TextButton(
                    onPressed: pending ? null : () => _run(source, 'cancel'),
                    child: const Text('停止'),
                  ),
                if (source.isDouyin && source.id != SourceSite.douyin.id)
                  PopupMenuButton<String>(
                    tooltip: '${source.name}更多操作',
                    enabled: enabled,
                    onSelected: (operation) => _run(source, operation),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'more',
                        enabled: status?.hasMore ?? true,
                        child: const Text('继续加载一页'),
                      ),
                      const PopupMenuItem(
                        value: 'checkCatalog',
                        child: Text('仅检测目录'),
                      ),
                    ],
                  )
                else if (source.id != SourceSite.douyin.id)
                  PopupMenuButton<String>(
                    tooltip: '${source.name}更多操作',
                    enabled: enabled,
                    onSelected: (operation) => _run(source, operation),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'more',
                        enabled: status?.hasMore ?? true,
                        child: const Text('继续加载一页'),
                      ),
                      PopupMenuItem(
                        value: 'allPages',
                        enabled: status?.hasMore ?? true,
                        child: const Text('加载后续所有页'),
                      ),
                      const PopupMenuItem(
                        value: 'metadata',
                        child: Text('补齐资料'),
                      ),
                      if (source.id == 'huangdou')
                        PopupMenuItem(
                          value: 'vipMetadata',
                          enabled: (status?.unknownVip ?? 0) > 0,
                          child: Text(
                            '补齐 VIP 资料（${status?.unknownVip ?? 0} 部）',
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'checkCatalog',
                        child: Text('仅检测目录'),
                      ),
                    ],
                  ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: status != null && status.total > 0
                      ? (status.completed / status.total).clamp(0, 1)
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${status?.stage ?? '准备中'}${(status?.total ?? 0) > 0 ? ' · ${status!.completed}/${status.total}' : ''}',
              ),
            ] else if (status != null && status.stage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${status.stage}${status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
              ),
            ],
            if (seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '请在 $seconds 秒后重试',
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  error,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (status != null && status.storageError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.storageError,
                      style: TextStyle(color: colors.error),
                    ),
                    TextButton.icon(
                      key: ValueKey('save-${source.id}'),
                      onPressed:
                          !busy && widget.repository.supportsSourceManagement
                          ? () => _run(source, 'retrySave')
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            if (health != null) ...[
              const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      expanded: healthExpanded,
                      child: Tooltip(
                        message: healthExpanded ? '收起检测详情' : '展开检测详情',
                        child: TextButton(
                          key: ValueKey('health-toggle-${source.id}'),
                          onPressed: () => setState(() {
                            if (healthExpanded) {
                              _expandedHealth.remove(source.id);
                            } else {
                              _expandedHealth.add(source.id);
                            }
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(health.label),
                                    Text(
                                      sourceTimestamp(health.checkedAt),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                healthExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制诊断信息',
                    onPressed: () => _copy(source, status!),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
              if (healthExpanded) ...[
                if (health.sample.isNotEmpty) Text('检测剧集：${health.sample}'),
                for (final step in health.steps)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          step.state == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 20,
                          color: step.state == 'ok'
                              ? colors.primary
                              : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${step.name}：${step.message}'),
                              if (step.host.isNotEmpty || step.httpStatus > 0)
                                Text(
                                  '${step.host}${step.httpStatus > 0 ? ' · HTTP ${step.httpStatus}' : ''} · ${step.elapsedMs} ms',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              const Text('尚未检测连接'),
            ],
          ],
        ),
      ),
    );
  }
}

class SourceDiagnosticsButton extends StatelessWidget {
  const SourceDiagnosticsButton({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
  });
  final AppRepository repository;
  final LocalStore store;
  final Drama drama;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: repository,
          store: store,
          initialSource: drama.source,
          drama: drama,
        ),
      ),
    ),
    icon: const Icon(Icons.network_check),
    label: const Text('站源诊断'),
  );
}
