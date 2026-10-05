import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'tiktok_source.dart';

class TikTokSettingsScreen extends StatefulWidget {
  const TikTokSettingsScreen({
    super.key,
    required this.store,
    required this.repository,
  });

  final LocalStore store;
  final AppRepository repository;

  @override
  State<TikTokSettingsScreen> createState() => _TikTokSettingsScreenState();
}

class _TikTokSettingsScreenState extends State<TikTokSettingsScreen> {
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
      final saved = await TikTokSource.storage.read(
        key: TikTokSource.cookieKey(_profile),
      );
      if (_valid) {
        _cookie.text = saved ?? '';
        setState(
          () => _message = saved?.isNotEmpty == true
              ? '当前账号已保存 TikTok Cookie'
              : '尚未配置 TikTok Cookie',
        );
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
        await TikTokSource.storage.delete(
          key: TikTokSource.cookieKey(_profile),
        );
        if (mounted) _cookie.clear();
        if (_valid) setState(() => _message = '已清除本机保存的 TikTok Cookie');
      } else {
        final cookie = TikTokSource.normalizeCookie(_cookie.text);
        await TikTokSource.storage.write(
          key: TikTokSource.cookieKey(_profile),
          value: cookie,
        );
        if (!_valid) return;
        _cookie.text = cookie;
        if (action == 'save') {
          setState(() => _message = 'Cookie 已保存在本机安全存储');
        } else if (!widget.store.allowsSource(SourceSite.tiktok.id)) {
          setState(() => _message = 'Cookie 已保存。请先在“显示的站源”中启用 TikTok，再回来检测接口');
        } else {
          final page = await widget.repository.catalog(
            SourceSite.tiktok.id,
            category: 'recommend',
            force: true,
          );
          if (!_valid) return;
          setState(() => _message = '推荐信息流可用，返回 ${page.items.length} 条内容');
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
    appBar: AppBar(title: const Text('TikTok Cookie 登录')),
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
                Text('使用已登录账号', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'TikTok 信息流需要登录 Cookie。在 Edge 登录 TikTok 后，打开开发者工具的 Network，选中 www.tiktok.com 的信息流请求，从请求标头复制 Cookie 的完整值（Cookie: 后面的整行），不要复制 Set-Cookie。Cookie 按当前本机用户保存在设备安全存储，只发送到 www.tiktok.com；不会写入订阅包或配置备份，也不会转发给视频播放域名。请勿把 Cookie 发到聊天或公开位置。',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _cookie,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
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
                    labelText: '粘贴完整 Cookie 请求头值',
                    helperText:
                        '从开发者工具 Network 的请求标头复制 Cookie 值（允许重复字段）；需包含 sessionid 或 sessionid_ss。',
                    helperMaxLines: 2,
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
                      child: const Text('保存并检测推荐信息流'),
                    ),
                    OutlinedButton(
                      onPressed: _busy || _cookie.text.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(text: _cookie.text),
                              );
                              if (_valid) {
                                setState(() => _message = '已复制 Cookie');
                              }
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
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
