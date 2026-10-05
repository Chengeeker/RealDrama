import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'youtube_source.dart';

class YouTubeSettingsScreen extends StatefulWidget {
  const YouTubeSettingsScreen({
    super.key,
    required this.store,
    required this.repository,
  });

  final LocalStore store;
  final AppRepository repository;

  @override
  State<YouTubeSettingsScreen> createState() => _YouTubeSettingsScreenState();
}

class _YouTubeSettingsScreenState extends State<YouTubeSettingsScreen> {
  final _cookie = TextEditingController();
  late final String _profile;
  late final int _epoch;
  bool _busy = true;
  bool _hasCookie = false;
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
      final saved = await YouTubeSource.storage.read(
        key: YouTubeSource.cookieKey(_profile),
      );
      if (_valid) {
        setState(() {
          _hasCookie = saved?.isNotEmpty == true;
          _message = _hasCookie
              ? '当前用户已配置 YouTube Cookie'
              : '尚未配置 YouTube Cookie';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取设备安全存储');
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
        await YouTubeSource.storage.delete(
          key: YouTubeSource.cookieKey(_profile),
        );
        _cookie.clear();
        if (_valid) {
          setState(() {
            _hasCookie = false;
            _message = '已清除本机保存的 YouTube Cookie';
          });
        }
        return;
      }
      final cookie = YouTubeSource.normalizeCookie(_cookie.text);
      await YouTubeSource.storage.write(
        key: YouTubeSource.cookieKey(_profile),
        value: cookie,
      );
      _cookie.clear();
      if (!_valid) return;
      setState(() => _hasCookie = true);
      if (action == 'save') {
        setState(() => _message = 'Cookie 已保存在本机安全存储');
      } else if (!widget.store.allowsSource(SourceSite.youtube.id)) {
        setState(() => _message = 'Cookie 已保存。启用 YouTube 后可检测信息流');
      } else {
        final page = await widget.repository.catalog(
          SourceSite.youtube.id,
          category: '',
          force: true,
        );
        if (_valid) {
          setState(
            () => _message = 'YouTube 信息流可用，返回 ${page.items.length} 条内容',
          );
        }
      }
    } catch (error) {
      if (_valid) {
        setState(
          () => _message = error is FormatException
              ? error.message.toString()
              : error is AppFailure
              ? '$error'
              : '操作失败，请检查网络或设备安全存储',
        );
      }
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
    appBar: AppBar(title: const Text('YouTube Cookie 设置')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('使用本机账号', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'YouTube 信息流需要登录态。只在本机输入你自行准备的一行 Cookie 请求头值；应用不会读取或复制 Edge Cookie，也不要把 Cookie 发到聊天。Cookie 按当前用户保存在设备安全存储，请求时只发送到 www.youtube.com，并临时生成授权头；不会写入订阅包、备份或日志，也不会发送给播放 CDN。',
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
                    labelText: '单行 Cookie 请求头值',
                    helperText:
                        '从开发者工具 Network 的请求标头复制 Cookie 值；需包含 SAPISID，可带 Cookie: 前缀。',
                    border: const OutlineInputBorder(),
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
                      child: const Text('保存并检测信息流'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _run('clear'),
                      child: const Text('清除 Cookie'),
                    ),
                  ],
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(_message),
                ],
                if (_hasCookie && _message.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('本机安全存储中已有 Cookie；为保护凭据，不在输入框中回显。'),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
