import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core_bridge.dart';
import 'douyin_source.dart';
import 'local_store.dart';
import 'models.dart';

class DouyinSettingsScreen extends StatefulWidget {
  const DouyinSettingsScreen({
    super.key,
    required this.store,
    required this.repository,
    this.source = SourceSite.douyin,
  });
  final LocalStore store;
  final AppRepository repository;
  final SourceSite source;
  @override
  State<DouyinSettingsScreen> createState() => _DouyinSettingsScreenState();
}

class _DouyinSettingsScreenState extends State<DouyinSettingsScreen> {
  final _cookie = TextEditingController();
  late final String _profile;
  late final int _epoch;
  bool _busy = true;
  bool _obscured = true;
  String _message = '';
  bool get _valid =>
      mounted && !widget.store.locked && widget.store.profileEpoch == _epoch;
  @override
  void initState() {
    super.initState();
    _profile = widget.store.profile.id;
    _epoch = widget.store.profileEpoch;
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final saved = await DouyinSource.storage.read(
        key: DouyinSource.cookieKey(_profile),
      );
      if (_valid) {
        _cookie.text = saved ?? '';
        setState(
          () => _message = saved?.isNotEmpty == true
              ? '已保存 Cookie，可查看、复制或替换'
              : '尚未配置 Cookie',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取安全存储');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(String action) async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      if (action == 'clear') {
        if (widget.store.sources.every((source) => source.isDouyin)) {
          await widget.store.setSourceVisible('hongguo', true);
        }
        if (!_valid) return;
        await widget.store.setSourcesVisible({
          for (final source in SourceSite.values.where(
            (source) => source.isDouyin,
          ))
            source.id: false,
        });
        if (!_valid) return;
        await DouyinSource.storage.delete(
          key: DouyinSource.cookieKey(_profile),
        );
        if (mounted) _cookie.clear();
        widget.repository.resetDouyin();
        if (_valid) setState(() => _message = '已清除 Cookie 并关闭抖音站源');
      } else {
        if (_cookie.text.trim().isNotEmpty) {
          final cookie = DouyinSource.normalizeCookie(_cookie.text);
          await DouyinSource.storage.write(
            key: DouyinSource.cookieKey(_profile),
            value: cookie,
          );
          if (_valid) _cookie.text = cookie;
          widget.repository.resetDouyin();
        }
        if (!_valid) return;
        final saved = await DouyinSource.storage.read(
          key: DouyinSource.cookieKey(_profile),
        );
        if (saved?.isNotEmpty != true) throw const DouyinFailure('请先输入 Cookie');
        if (action == 'check') {
          final count = await widget.repository.checkDouyin();
          if (!_valid) return;

          if (_valid)
            setState(() => _message = '已获取 ${count} 条可解析视频；子项开关可在站源管理中设置。');
        } else if (action == 'check-live') {
          final count = await widget.repository.checkDouyinLive();
          if (!_valid) return;

          if (_valid)
            setState(() => _message = '已获取 ${count} 个直播间；子项开关可在站源管理中设置。');
        } else if (_valid) {
          setState(() => _message = 'Cookie 已安全保存；点击检测验证推荐接口');
        }
      }
    } catch (error) {
      if (_valid)
        setState(
          () => _message = error is DouyinFailure || error is AppFailure
              ? '$error'
              : '操作失败，请检查网络或设备安全存储',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('抖音账号与 Cookie')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cookie 登录',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '登录抖音网页版，打开开发者工具 → 网络（Network），刷新页面并选中 www.douyin.com 或 live.douyin.com 的接口请求，在请求标头（Request Headers）中复制 Cookie 的整段值。不要复制 Cookie 表格、单个字段值或响应里的 Set-Cookie。短视频、直播、短剧与放映厅共用这份 Cookie；仅保存在本机安全存储，不进入配置备份。登录过期或需要验证时，在网页处理后重新复制。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _cookie,
                  enabled: !_busy,
                  obscureText: _obscured,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      tooltip: _obscured ? '显示 Cookie' : '隐藏 Cookie',
                      onPressed: () => setState(() => _obscured = !_obscured),
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                    labelText: '粘贴请求头 Cookie 的完整值',
                    helperText: '字段名=字段值；多项用英文分号分隔。不要手动解码或修改字段值。',
                    helperMaxLines: 3,
                    border: InputBorder.none,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : () => _run('save'),
                      child: const Text('保存'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _run('check'),
                      child: const Text('检测短视频'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _run('check-live'),
                      child: const Text('检测直播'),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              if (_cookie.text.isEmpty) return;
                              await Clipboard.setData(
                                ClipboardData(text: _cookie.text),
                              );
                              if (_valid)
                                setState(() => _message = '已复制 Cookie');
                            },
                      child: const Text('复制 Cookie'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _run('clear'),
                      child: const Text('清除登录'),
                    ),
                  ],
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (_message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_message),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '抖音短视频提供推荐流、作品主页与在线播放；抖音直播提供直播间目录和独立直播播放器。短视频、直播、短剧与放映厅共用 Cookie，当前不支持下载。网页接口可能调整，保存 Cookie 不代表接口检测已通过。',
        ),
      ],
    ),
  );
}
