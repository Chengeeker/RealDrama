import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';
import 'source_subscriptions.dart';

class SourceSubscriptionsScreen extends StatefulWidget {
  const SourceSubscriptionsScreen({
    super.key,
    required this.store,
    this.subscriptions,
  });
  final LocalStore store;
  final SourceSubscriptions? subscriptions;
  @override
  State<SourceSubscriptionsScreen> createState() =>
      _SourceSubscriptionsScreenState();
}

class _SourceSubscriptionsScreenState extends State<SourceSubscriptionsScreen> {
  late final manager = widget.subscriptions ?? SourceSubscriptions.instance;
  final address = TextEditingController(
    text: SourceSubscriptions.officialRepository,
  );
  SourceSubscriptionPreview? preview;
  final selected = <String>{};
  bool working = false;
  bool adding = false;
  bool get busy => working || manager.checking;
  String error = '';
  @override
  void initState() {
    super.initState();
    manager.addListener(changed);
    unawaited(run(manager.open));
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(changed);
    address.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      await action();
    } catch (exception) {
      if (mounted)
        setState(
          () => error = exception is FormatException
              ? exception.message.toString()
              : '操作失败，原站源与用户配置已保留',
        );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> load() => run(() async {
    setState(() {
      preview = null;
      selected.clear();
    });
    final result = await manager.preview(address.text);
    if (mounted) {
      setState(() {
        preview = result;
        selected.clear();
      });
    }
  });

  Future<void> updateAll() => run(() async {
    final count = await manager.updateAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 0 ? '在线订阅已是最新版本，本地导入不参与检查' : '已更新 $count 个订阅，本地导入不参与检查',
        ),
      ),
    );
  });

  Future<void> install() => run(() async {
    final current = preview;
    if (current == null) return;
    final epoch = widget.store.profileEpoch;
    final failures = <String>[];
    var installed = 0;
    for (final entry
        in current.entries
            .where((row) => selected.contains(row['id']))
            .toList()) {
      if (!mounted || epoch != widget.store.profileEpoch) break;
      try {
        await manager.install(current, entry);
        installed++;
        if (mounted) setState(() => selected.remove(entry['id']));
      } catch (exception) {
        final reason = exception is FormatException
            ? exception.message.toString()
            : exception is TimeoutException
            ? '下载超时，请重试'
            : exception is SocketException
            ? '网络连接失败，请检查网络'
            : exception is FileSystemException
            ? '本地保存失败，请检查存储权限和空间'
            : '站源解析或安装失败';
        failures.add('${entry['name']}：$reason');
      }
    }

    if (failures.isNotEmpty)
      throw FormatException('以下站源未导入，其余已保留：${failures.join('、')}');
    if (mounted && epoch == widget.store.profileEpoch) {
      setState(() {
        selected.clear();
        preview = null;
        adding = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加 $installed 个订阅，可在“启用与维护”中开启站源')),
      );
    }
  });
  Future<void> update(String id) => run(() async {
    final origin = manager.package(id)!.origin;
    final current = await manager.preview(origin);
    if (!mounted) return;
    final entry = current.entries
        .where((row) => SourceSubscriptions.entryContains(row, id))
        .firstOrNull;
    if (entry == null) throw const FormatException('上游已移除此站源，本地版本仍保留');
    if (entry['sha256'] == manager.package(id)!.digest) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此订阅已是最新版本')));
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('更新 ${entry['name']}'),
        content: SingleChildScrollView(
          child: Text(
            '版本：${manager.package(id)!.version} → ${entry['version']}\n${entry['changelog'] ?? ''}\n\n站源脚本由此订阅仓库提供。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('更新站源'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await manager.install(current, entry);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('订阅已更新')));
      }
    }
  });

  Future<void> remove(String id) => run(() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除站源'),
        content: const Text('移除订阅与站源程序。观看记录、收藏和本地账号配置保留，重新导入相同站源后仍可使用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (accepted == true) await manager.remove(id);
  });
  @override
  Widget build(BuildContext context) {
    final packages = manager.installed;
    final onlineCount = packages
        .where((item) => !item.origin.startsWith('local:'))
        .length;
    return Scaffold(
      appBar: AppBar(title: const Text('订阅与更新')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '已安装 ${packages.length} 个订阅',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('订阅用于安装和更新站源程序；内容列表与站源开关在“启用与维护”中管理。'),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('subscriptions-update-all'),
                    onPressed: busy || onlineCount == 0 ? null : updateAll,
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('检查并更新全部'),
                  ),
                  if (packages.isNotEmpty)
                    OutlinedButton.icon(
                      key: const ValueKey('subscriptions-add'),
                      onPressed: busy
                          ? null
                          : () => setState(() => adding = !adding),
                      icon: Icon(adding ? Icons.close : Icons.add),
                      label: Text(adding ? '收起添加' : '添加订阅'),
                    ),
                ],
              ),
              if (manager.updates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${manager.updates.length} 个订阅可更新'),
                ),
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('正在处理订阅，请稍候…'),
              ],
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (adding || packages.isEmpty) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '添加订阅',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: address,
                          enabled: !busy,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                            labelText: 'GitHub 仓库、订阅或单个站源链接',
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => load(),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: busy ? null : load,
                              icon: const Icon(Icons.cloud_download_outlined),
                              label: const Text('获取站源列表'),
                            ),
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => run(() async {
                                      final result = await FilePicker.pickFile(
                                        type: FileType.custom,
                                        allowedExtensions: ['json'],
                                      );
                                      final file = result?.path;
                                      if (file != null)
                                        await manager.importLocal(file);
                                    }),
                              icon: const Icon(Icons.file_open_outlined),
                              label: const Text('导入本地站源'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '导入后在设备本地运行，更新站源无需重新安装应用。请选择你信任的订阅仓库。Cookie 只保存在本机，不会上传到订阅仓库。导入保留已有开关设置，新站源可在站源管理中开启。',
                        ),
                      ],
                    ),
                  ),
                ),

                if (preview != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      preview!.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(
                                () => selected.addAll(
                                  preview!.entries.map(
                                    (entry) => entry['id'] as String,
                                  ),
                                ),
                              ),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() => selected.clear()),
                        child: const Text('清空选择'),
                      ),
                      FilledButton.icon(
                        onPressed: busy || selected.isEmpty ? null : install,
                        icon: const Icon(Icons.download_done_outlined),
                        label: Text('导入并订阅 ${selected.length} 个站源'),
                      ),
                    ],
                  ),
                  for (final entry in preview!.entries)
                    Card(
                      child: CheckboxListTile(
                        value: selected.contains(entry['id']),
                        onChanged: busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(entry['id'] as String);
                                } else {
                                  selected.remove(entry['id']);
                                }
                              }),
                        title: Text('${entry['name']} · ${entry['version']}'),
                        subtitle:
                            entry['children'] is List &&
                                (entry['children'] as List)
                                    .whereType<Map>()
                                    .isNotEmpty
                            ? Text(
                                '包含：${(entry['children'] as List).whereType<Map>().map((child) => child['name']).join('、')}',
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ],
              if (packages.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('尚未安装订阅。获取列表后选择站源，再点“导入并订阅”。'),
                ),
              for (final package in packages) _installedPackage(package),
              for (final issue in manager.problems.entries)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '${issue.key}：${issue.value}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _installedPackage(SourcePackage package) {
    final local = package.origin.startsWith('local:');
    final available = manager.updates[package.id];
    final previous = manager.previousVersion(package.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${package.name} · ${package.version}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '${package.name}更多操作',
                  enabled: !busy,
                  onSelected: (action) {
                    switch (action) {
                      case 'copy':
                        Clipboard.setData(
                          ClipboardData(
                            text: manager.independentLink(package.id),
                          ),
                        );
                      case 'rollback':
                        run(() => manager.rollback(package.id));
                      case 'remove':
                        remove(package.id);
                    }
                  },
                  itemBuilder: (_) => [
                    if (!local)
                      const PopupMenuItem(value: 'copy', child: Text('复制订阅链接')),
                    if (previous != null)
                      PopupMenuItem(
                        value: 'rollback',
                        child: Text('回退到 $previous'),
                      ),
                    const PopupMenuItem(value: 'remove', child: Text('移除订阅')),
                  ],
                ),
              ],
            ),
            if (package.isBundle && package.sources.isNotEmpty)
              Text(
                '包含：${package.sources.map((child) => child.name).join('、')}',
              ),
            const SizedBox(height: 4),
            Text(
              local
                  ? '本地导入 · 需重新导入文件更新'
                  : '在线订阅 · ${Uri.tryParse(package.origin)?.host ?? package.origin}',
            ),
            if (!local) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: ValueKey('subscription-update-${package.id}'),
                onPressed: busy ? null : () => update(package.id),
                icon: const Icon(Icons.update_rounded),
                label: Text(
                  available == null
                      ? '检查并更新此订阅'
                      : '更新到 ${available['version']}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
