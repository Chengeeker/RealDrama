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
  Timer? _reorderTimer;
  List<String>? _heldSourceOrder;
  List<String>? _heldManagementGroupOrder;
  List<String>? _lastSourceOrder;
  List<String>? _lastManagementGroupOrder;
  int _visibilityOperations = 0;
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
      _expandedSections.add(
        SourceSite.byId(widget.initialSource!).isSubscriptionTest
            ? 'source-group-douyin-test'
            : 'source-group-douyin',
      );
    }
    if (widget.initialSource != null &&
        SourceSite.byId(widget.initialSource!).isBilibili) {
      _expandedSections.add(
        SourceSite.byId(widget.initialSource!).isSubscriptionTest
            ? 'source-group-bilibili-test'
            : 'source-group-bilibili',
      );
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
    _reorderTimer?.cancel();
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

  List<SourceSite> get _bilibiliSources =>
      SourceSite.values.where((source) => source.isBilibili).toList();

  List<SourceGroup> _managementGroups(List<SourceSite> sources) {
    final groups = <SourceGroup>[];
    final added = <String>{};
    for (final group in SourceGroup.fromSources(sources)) {
      if (group.sources.any((source) => source.isDouyin)) {
        final isTest = group.sources.every(
          (source) => source.isSubscriptionTest,
        );
        final id = isTest ? 'douyin-test-family' : 'douyin-family';
        if (added.add(id)) {
          groups.add(
            SourceGroup(
              id,
              isTest ? '抖音（测试版）' : '抖音',
              _douyinSources
                  .where((source) => source.isSubscriptionTest == isTest)
                  .toList(),
            ),
          );
        }
      } else if (group.sources.any((source) => source.isBilibili)) {
        final isTest = group.sources.every(
          (source) => source.isSubscriptionTest,
        );
        final id = isTest ? 'bilibili-test-family' : 'bilibili-family';
        if (added.add(id)) {
          groups.add(
            SourceGroup(
              id,
              isTest ? 'Bilibili（测试版）' : 'Bilibili',
              _bilibiliSources
                  .where((source) => source.isSubscriptionTest == isTest)
                  .toList(),
            ),
          );
        }
      } else {
        groups.add(group);
      }
    }
    return groups;
  }

  List<SourceGroup> _orderedManagementGroups(List<SourceSite> sources) {
    final groups = _managementGroups(sources);
    final heldOrder = _heldManagementGroupOrder;
    if (heldOrder != null) {
      groups.sort((a, b) {
        int rank(String id) {
          final index = heldOrder.indexOf(id);
          return index < 0 ? heldOrder.length + 1 : index;
        }

        return rank(a.id).compareTo(rank(b.id));
      });
      return groups;
    }

    final indexedGroups = groups.asMap().entries.toList();
    int enabledCount(SourceGroup group) => group.sources
        .where((source) => widget.store.allowsSource(source.id))
        .length;
    indexedGroups.sort((a, b) {
      final enabledOrder = enabledCount(
        b.value,
      ).compareTo(enabledCount(a.value));
      if (enabledOrder != 0) return enabledOrder;
      final aSelected = a.value.sources.any(
        (source) => source.id == widget.initialSource,
      );
      final bSelected = b.value.sources.any(
        (source) => source.id == widget.initialSource,
      );
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      return a.key.compareTo(b.key);
    });
    final ordered = indexedGroups.map((entry) => entry.value).toList();
    if (_visibilityOperations == 0) {
      _lastManagementGroupOrder = ordered.map((group) => group.id).toList();
    }
    return ordered;
  }

  void _beginVisibilityChange() {
    _reorderTimer?.cancel();
    if (_visibilityOperations == 0) {
      _heldSourceOrder =
          _lastSourceOrder ??
          SourceSite.values.map((source) => source.id).toList();
      _heldManagementGroupOrder =
          _lastManagementGroupOrder ??
          _managementGroups(
            SourceSite.values,
          ).map((group) => group.id).toList();
    }
    _visibilityOperations++;
  }

  void _finishVisibilityChange() {
    if (_visibilityOperations > 0) _visibilityOperations--;
    if (_visibilityOperations != 0 || !mounted) return;
    _reorderTimer?.cancel();
    _reorderTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() {
        _heldSourceOrder = null;
        _heldManagementGroupOrder = null;
      });
    });
  }

  ShapeBorder _sourceCardShape() =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));

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
    if (mounted) {
      for (final source in _bilibiliSources) {
        if (widget.store.allowsSource(source.id)) {
          unawaited(_refreshSource(source));
        }
      }
    }
  }

  Future<void> _setVisible(SourceSite source, bool visible) =>
      _setVisibility([source], visible);

  Future<void> _setVisibility(
    List<SourceSite> sources,
    bool visible, {
    String? family,
  }) async {
    if (sources.any((source) => _visibilityPending.contains(source.id))) return;
    _beginVisibilityChange();
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
      if (family != null) {
        await widget.store.setSourceFamilyVisible(family, sources, visible);
      } else {
        await widget.store.setSourcesVisible({
          for (final source in sources) source.id: visible,
        });
      }
      if (!mounted || epoch != widget.store.profileEpoch) return;
      for (final source in sources) {
        if (widget.store.allowsSource(source.id)) {
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
      _finishVisibilityChange();
      if (mounted) setState(() => _visibilityPending.removeAll(ids));
    }
  }

  Widget _familyVisibility(SourceGroup group) {
    final sources = group.sources;
    final enabled = sources
        .where((source) => widget.store.allowsSource(source.id))
        .length;
    final busy = sources.any(
      (source) => _visibilityPending.contains(source.id),
    );
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('visible-${group.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      color: colors.surfaceContainer,
      elevation: 0,
      shape: _sourceCardShape(),
      child: ListTile(
        title: Text(group.name),
        subtitle: Text('已开启 $enabled/${sources.length} · 子项在下方管理'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sources.any((source) => source.isDouyin))
              IconButton(
                tooltip: '统一配置抖音 Cookie',
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: busy ? null : _configureDouyin,
              ),
            if (sources.any((source) => source.isBilibili))
              IconButton(
                tooltip: '统一配置 Bilibili Cookie',
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: busy ? null : _configureBilibili,
              ),
            Switch(
              value: enabled > 0,
              onChanged: busy
                  ? null
                  : (visible) =>
                        _setVisibility(sources, visible, family: group.id),
            ),
          ],
        ),
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
    final epoch = widget.store.profileEpoch;
    final sources = List<SourceSite>.of(widget.store.sources);
    if (sources.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有已启用的站源')));
      return;
    }
    setState(() => _bulkOperation = operation);
    try {
      for (final source in sources) {
        if (!mounted) return;
        if (epoch != widget.store.profileEpoch) return;
        if (!widget.store.allowsSource(source.id)) continue;
        for (final active in sources) {
          if (!mounted || epoch != widget.store.profileEpoch) return;
          if (active.id == source.id || _statuses[active.id]?.running != true) {
            continue;
          }
          await _waitForSourceJob(active, epoch);
        }
        await _run(source, operation);
        await _waitForSourceJob(source, epoch);
      }
      if (mounted && epoch == widget.store.profileEpoch) {
        final label = operation == 'update' ? '更新' : '检测';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已完成所有已开启站源的$label')));
      }
    } finally {
      if (mounted) setState(() => _bulkOperation = null);
    }
  }

  Future<void> _waitForSourceJob(SourceSite source, int epoch) async {
    while (mounted &&
        epoch == widget.store.profileEpoch &&
        _statuses[source.id]?.running == true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || epoch != widget.store.profileEpoch) return;
      await _refreshSource(source);
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
      color: colors.surfaceContainer,
      elevation: 0,
      shape: _sourceCardShape(),
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
      final sources = SourceSite.values
          .where(
            (source) =>
                source.isDouyin ||
                source.groupId == 'huangguo' ||
                widget.store.allowsSource(source.id),
          )
          .toList();
      final heldSourceOrder = _heldSourceOrder;
      if (heldSourceOrder != null) {
        sources.sort((a, b) {
          int rank(SourceSite source) {
            final index = heldSourceOrder.indexOf(source.id);
            return index < 0
                ? heldSourceOrder.length + SourceSite.values.indexOf(source)
                : index;
          }

          return rank(a).compareTo(rank(b));
        });
      } else {
        sources.sort((a, b) {
          final aEnabled = widget.store.allowsSource(a.id);
          final bEnabled = widget.store.allowsSource(b.id);
          if (aEnabled != bEnabled) return aEnabled ? -1 : 1;
          final aFirst = a.id == widget.initialSource ? 0 : 1;
          final bFirst = b.id == widget.initialSource ? 0 : 1;
          final priority = aFirst.compareTo(bFirst);
          return priority != 0
              ? priority
              : SourceSite.values
                    .indexOf(a)
                    .compareTo(SourceSite.values.indexOf(b));
        });
        if (_visibilityOperations == 0) {
          _lastSourceOrder = sources.map((source) => source.id).toList();
        }
      }
      final visibleGroups = SourceSite.values
          .where((source) => widget.store.allowsSource(source.id))
          .map(
            (source) => source.isDouyin
                ? source.isSubscriptionTest
                      ? 'douyin-test-family'
                      : 'douyin-family'
                : source.isBilibili
                ? source.isSubscriptionTest
                      ? 'bilibili-test-family'
                      : 'bilibili-family'
                : source.groupId,
          )
          .toSet()
          .length;
      final totalGroups = SourceSite.values
          .map(
            (source) => source.isDouyin
                ? source.isSubscriptionTest
                      ? 'douyin-test-family'
                      : 'douyin-family'
                : source.isBilibili
                ? source.isSubscriptionTest
                      ? 'bilibili-test-family'
                      : 'bilibili-family'
                : source.groupId,
          )
          .toSet()
          .length;
      final viewPaddingBottom = MediaQuery.viewPaddingOf(context).bottom;
      final paddingBottom = MediaQuery.paddingOf(context).bottom;
      final bottomInset = viewPaddingBottom > paddingBottom
          ? viewPaddingBottom
          : paddingBottom;
      return Scaffold(
        appBar: AppBar(
          title: const Text('当前站源'),
          actions: [
            IconButton(
              tooltip: '一键更新',
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
                  Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    elevation: 0,
                    shape: _sourceCardShape(),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '顶栏可依次更新或检测所有已开启站源，卡片也可单独操作。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；“加载后续所有页”会逐页低频请求，同一时间只运行一个站源，最多连续加载 1000 页或 30 分钟。遇到限流、超时或错误会停止并保留已加载内容，也可随时手动停止。',
                      ),
                    ),
                  ),
                  _expandableSection(
                    section: 'source-visibility',
                    icon: Icons.visibility_outlined,
                    title: '显示的站源',
                    subtitle: '已显示 $visibleGroups/$totalGroups · 点击选择隐藏',
                    children: [
                      for (final group in _orderedManagementGroups(
                        SourceSite.values,
                      ))
                        if (group.id == 'douyin-family' ||
                            group.id == 'douyin-test-family' ||
                            group.id == 'bilibili-family' ||
                            group.id == 'bilibili-test-family' ||
                            group.id == 'huangguo')
                          _familyVisibility(group)
                        else
                          Card(
                            key: ValueKey('visible-${group.sources.first.id}'),
                            margin: const EdgeInsets.only(bottom: 8),
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainer,
                            elevation: 0,
                            shape: _sourceCardShape(),
                            child: ListTile(
                              title: Text(group.name),
                              trailing: Switch(
                                value: widget.store.allowsSource(
                                  group.sources.first.id,
                                ),
                                onChanged: (visible) =>
                                    _setVisible(group.sources.first, visible),
                              ),
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
                    else if (group.id == 'douyin-test-family')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _expandableSection(
                          section: 'source-group-douyin-test',
                          icon: Icons.video_library_outlined,
                          title: '抖音（测试版）',
                          subtitle: '独立测试来源 · 共用原版 Cookie',
                          children: [
                            for (final source in group.sources)
                              _sourceCard(source),
                          ],
                        ),
                      )
                    else if (group.id == 'bilibili-family')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _expandableSection(
                          section: 'source-group-bilibili',
                          icon: Icons.video_library_outlined,
                          title: 'Bilibili',
                          subtitle: '视频、直播 · 共用一个 Cookie',
                          children: [
                            for (final source in group.sources)
                              _sourceCard(source),
                          ],
                        ),
                      )
                    else if (group.id == 'bilibili-test-family')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _expandableSection(
                          section: 'source-group-bilibili-test',
                          icon: Icons.video_library_outlined,
                          title: 'Bilibili（测试版）',
                          subtitle: '独立测试来源 · 共用原版 Cookie',
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
    if ((source.isDouyin ||
            source.isBilibili ||
            source.groupId == 'huangguo') &&
        !visible) {
      return Card(
        key: ValueKey('source-${source.id}'),
        margin: const EdgeInsets.only(bottom: 16),
        color: Theme.of(context).colorScheme.surfaceContainer,
        elevation: 0,
        shape: _sourceCardShape(),
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
      color: colors.surfaceContainerLow,
      elevation: 0,
      shape: _sourceCardShape(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dns_outlined,
                  color: colors.onSurfaceVariant,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    source.id == SourceSite.douyin.id ? '抖音短视频' : source.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${status?.count ?? 0} ${source.isDouyinLive || SourceSite.providerIdFor(source.id) == 'bilibili-live' ? '个直播间' : '部'}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (source.isDouyin ||
                    source.isBilibili ||
                    source.groupId == 'huangguo')
                  Switch(
                    value: visible,
                    onChanged: _visibilityPending.contains(source.id)
                        ? null
                        : (value) => _setVisible(source, value),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '最近更新：${sourceTimestamp(status?.updatedAt)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (status != null &&
                      (status.count > 0 ||
                          status.page > 1 ||
                          status.totalPages > 0)) ...[
                    const SizedBox(height: 4),
                    Text(
                      sourcePageSummary(status),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
