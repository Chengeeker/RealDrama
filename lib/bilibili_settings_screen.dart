import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bilibili_source.dart';
import 'core_bridge.dart';
import 'local_store.dart';

class BilibiliSettingsScreen extends StatefulWidget {
  const BilibiliSettingsScreen({
    super.key,
    required this.store,
    required this.repository,
  });

  final LocalStore store;
  final AppRepository repository;

  @override
  State<BilibiliSettingsScreen> createState() => _BilibiliSettingsScreenState();
}

class _BilibiliSettingsScreenState extends State<BilibiliSettingsScreen> {
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
      final saved = await BilibiliSource.readCookie(_profile);
      if (_valid) {
        _cookie.text = saved ?? '';
        setState(
          () => _message = saved?.isNotEmpty == true
              ? '已保存 Cookie，可查看、复制或替换'
              : '未配置 Cookie，可匿名浏览公开内容',
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
        await BilibiliSource.storage.delete(
          key: BilibiliSource.cookieKey(_profile),
        );
        if (mounted) _cookie.clear();
        if (_valid) setState(() => _message = '已清除本机保存的 Bilibili Cookie');
      } else {
        if (action == 'save') {
          final cookie = BilibiliSource.normalizeCookie(_cookie.text);
          await BilibiliSource.storage.write(
            key: BilibiliSource.cookieKey(_profile),
            value: cookie,
          );
          if (!_valid) return;
          _cookie.text = cookie;
          setState(() => _message = 'Cookie 已保存在本机安全存储');
        } else {
          if (_cookie.text.trim().isNotEmpty) {
            final cookie = BilibiliSource.normalizeCookie(_cookie.text);
            await BilibiliSource.storage.write(
              key: BilibiliSource.cookieKey(_profile),
              value: cookie,
            );
            if (!_valid) return;
            _cookie.text = cookie;
          }
          final result = await widget.repository.bilibiliAccount();
          if (!_valid) return;
          final loggedIn = result['isLogin'] == true;
          final name = (result['name'] as String? ?? '').trim();
          setState(() {
            _message = loggedIn
                ? '接口可用，Cookie 登录有效${name.isEmpty ? '' : '：$name'}'
                : '接口可用，但当前未登录或 Cookie 已失效；公开内容仍可浏览，登录可解锁更多清晰度';
          });
        }
      }
    } catch (error) {
      if (_valid) {
        setState(
          () => _message = error is FormatException || error is AppFailure
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
    appBar: AppBar(title: const Text('Bilibili 账号与 Cookie')),
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
                  '可选 Cookie 登录',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '普通视频的公开推荐、排行、搜索和可访问内容可匿名读取。直播推荐、分区和播放的匿名可用性尚未实测；正在关注会使用已配置 Cookie 请求。登录网页后，在开发者工具的 Network 中选中 Bilibili API 请求，从请求标头复制完整 Cookie；需要包含 SESSDATA。Cookie 按当前本机用户保存在安全存储中，只发送到 api.bilibili.com 与 api.live.bilibili.com，不写入配置备份，也不会转发给视频 CDN。直播间访问、登录权限和会员内容仍由 Bilibili 控制。',
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
                    helperText: '字段名=字段值；多项用英文分号分隔。请勿手动修改字段值。',
                    helperMaxLines: 2,
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
                      child: const Text('检测登录与接口'),
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
                      child: const Text('清除 Cookie'),
                    ),
                  ],
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(_message),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
