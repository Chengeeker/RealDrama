import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';

class HanimeSource {
  static const storage = FlutterSecureStorage();
  static String cookieKey(String profile) => 'source.cookie.hanime.$profile';

  static String normalizeCookie(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const FormatException('请只粘贴 Cookie 请求头这一行');
    }
    final match = RegExp(
      r'^\s*cookie\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    final cookie = (match?.group(1) ?? value).trim();
    if (cookie.isEmpty ||
        cookie.length > 32768 ||
        RegExp(r'[^\x20-\x7e]').hasMatch(cookie)) {
      throw const FormatException('请粘贴单行完整 Cookie');
    }
    final names = <String>{};
    for (final part
        in cookie
            .split(';')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)) {
      final separator = part.indexOf('=');
      if (separator <= 0) {
        throw const FormatException('Cookie 字段格式无效');
      }
      final name = part.substring(0, separator).trim();
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name) ||
          !names.add(name)) {
        throw const FormatException('Cookie 字段名重复或格式无效');
      }
    }
    return cookie;
  }
}

class HanimeSettingsScreen extends StatefulWidget {
  const HanimeSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<HanimeSettingsScreen> createState() => _HanimeSettingsScreenState();
}

class _HanimeSettingsScreenState extends State<HanimeSettingsScreen> {
  static const _channel = MethodChannel('realdrama/hanime');
  final _cookie = TextEditingController();
  late final String _profile = widget.store.profile.id;
  late final int _epoch = widget.store.profileEpoch;
  bool _busy = true;
  bool _obscured = true;
  String _message = '';
  bool get _valid =>
      mounted && !widget.store.locked && widget.store.profileEpoch == _epoch;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final saved = await HanimeSource.storage.read(
        key: HanimeSource.cookieKey(_profile),
      );
      if (_valid) {
        _cookie.text = saved ?? '';
        setState(
          () => _message = saved?.isNotEmpty == true
              ? '已保存 Cookie，可替换或清除'
              : '未配置 Cookie；公开页面仍会尝试浏览器兼容请求',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取安全存储');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run({required bool clear}) async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      if (clear) {
        await HanimeSource.storage.delete(
          key: HanimeSource.cookieKey(_profile),
        );
        if (!_valid) return;
        _cookie.clear();
        setState(() => _message = '已清除本机保存的 Hanime Cookie');
      } else {
        final cookie = HanimeSource.normalizeCookie(_cookie.text);
        await HanimeSource.storage.write(
          key: HanimeSource.cookieKey(_profile),
          value: cookie,
        );
        if (!_valid) return;
        _cookie.text = cookie;
        setState(() => _message = 'Cookie 已保存在本机安全存储');
      }
    } catch (error) {
      if (_valid) {
        setState(
          () => _message = error is FormatException
              ? '${error.message}'
              : '操作失败，请检查设备安全存储',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyInApp() async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final value = await _channel.invokeMethod<String>('verifyCloudflare');
      if (value == null || !_valid) return;
      final cookie = HanimeSource.normalizeCookie(value);
      if (!RegExp(r'(?:^|;\s*)cf_clearance=').hasMatch(cookie)) {
        throw const FormatException('验证页面尚未提供 Cloudflare clearance Cookie');
      }
      await HanimeSource.storage.write(
        key: HanimeSource.cookieKey(_profile),
        value: cookie,
      );
      if (!_valid) return;
      _cookie.text = cookie;
      setState(() => _message = '已同步本机验证 Cookie，并保存在当前资料的安全存储');
    } on PlatformException {
      if (_valid)
        setState(() => _message = '无法打开应用内验证页，请更新 Android System WebView 后重试');
    } catch (error) {
      if (_valid) {
        setState(
          () => _message = error is FormatException
              ? error.message
              : '无法保存验证 Cookie，请检查设备安全存储',
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
    appBar: AppBar(title: const Text('Hanime Cookie 与验证')),
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
                  '可选 Cookie 与 Cloudflare 验证',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '优先使用应用内验证页，在当前 Android 设备和网络中打开 hanime1.me，完成页面要求的验证后点“同步 Cookie”。这样可避免直接复制其他浏览器的 Cloudflare 凭据时遇到设备或浏览器绑定问题。Cookie 只写入当前资料的安全存储，客户端仅向 hanime1.me 发送，不进入备份或诊断。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '应用不会自动解答验证码。手动粘贴 Cookie 仍可作为备用方式，但从其他浏览器复制的 Cloudflare Cookie 可能因设备、浏览器或网络变化而无效。',
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
                    labelText: '粘贴 Cookie 请求头的完整值',
                    helperText: '单行；字段名=字段值，多项用英文分号分隔。',
                    border: InputBorder.none,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (Platform.isAndroid)
                      FilledButton.icon(
                        onPressed: _busy ? null : _verifyInApp,
                        icon: const Icon(Icons.verified_user_outlined),
                        label: const Text('应用内验证并同步'),
                      ),
                    FilledButton(
                      onPressed: _busy ? null : () => _run(clear: false),
                      child: const Text('保存'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _run(clear: true),
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
