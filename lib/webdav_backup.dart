import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_store.dart';

class WebDavBackupScreen extends StatefulWidget {
  const WebDavBackupScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<WebDavBackupScreen> createState() => _WebDavBackupScreenState();
}

class _WebDavBackupScreenState extends State<WebDavBackupScreen> {
  static const _addressKey = 'webdavBackup.address';
  static const _usernameKey = 'webdavBackup.username';
  static const _passwordKey = 'webdavBackup.password';
  static const _secureStorage = FlutterSecureStorage();

  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final password = await _secureStorage.read(key: _passwordKey);
      if (!mounted) {
        return;
      }
      _address.text = preferences.getString(_addressKey) ?? '';
      _username.text = preferences.getString(_usernameKey) ?? '';
      _password.text = password ?? '';
      setState(() {});
    } catch (_) {
      if (mounted) {
        setState(() => _message = '无法读取设备中保存的 WebDAV 设置');
      }
    }
  }

  Future<WebDavBackupClient> _saveSettings() async {
    final client = WebDavBackupClient(
      address: _address.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
    );
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(_addressKey, client.address)) {
      throw StateError('无法保存 WebDAV 地址');
    }
    if (client.username.isEmpty) {
      await preferences.remove(_usernameKey);
    } else if (!await preferences.setString(_usernameKey, client.username)) {
      throw StateError('无法保存 WebDAV 用户名');
    }
    if (client.password.isEmpty) {
      await _secureStorage.delete(key: _passwordKey);
    } else {
      await _secureStorage.write(key: _passwordKey, value: client.password);
    }
    return client;
  }

  Future<void> _run(Future<String> Function(WebDavBackupClient) action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final client = await _saveSettings();
      final result = await action(client);
      if (mounted) {
        setState(() => _message = result);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = _friendlyError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _friendlyError(Object error) => switch (error) {
    WebDavBackupException() => error.message,
    FormatException() => error.message,
    StateError() => error.message,
    _ => 'WebDAV 操作失败：$error',
  };

  Future<void> _upload() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上传配置备份？'),
        content: const Text('将覆盖 WebDAV 文件地址中的旧备份。下载的视频不包含在配置备份中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('上传'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) {
      return;
    }
    await _run((client) async {
      final content = await widget.store.exportBackup();
      await client.upload(content);
      return '配置备份已上传';
    });
  }

  Future<void> _restore() async {
    await _run((client) async {
      final content = await client.download();
      final data = widget.store.validateBackup(content);
      if (!mounted) {
        return '已取消恢复';
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从 WebDAV 恢复？'),
          content: Text(
            '备份包含 ${(data['profiles'] as List).length} 个用户。恢复会替换本机用户、收藏、观看记录和偏好设置；已下载视频保留。',
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
      if (accepted != true || !mounted) {
        return '已取消恢复';
      }
      await widget.store.importBackup(content);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return '配置备份已恢复';
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 备份')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Card(
                color: colors.surfaceContainerLow,
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
                        '连接设置',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _address,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'WebDAV 文件地址',
                          hintText:
                              'https://dav.example.com/remote.php/dav/files/user/RealDrama.json',
                          helperText: '填写完整文件地址；上传会覆盖该文件。仅支持 HTTPS。',
                          helperMaxLines: 2,
                          border: InputBorder.none,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _username,
                        enabled: !_busy,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '用户名（可选）',
                          border: InputBorder.none,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPassword,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: '密码或应用专用密码（可选）',
                          helperText: '密码保存在设备安全存储中，不会写入配置备份。',
                          helperMaxLines: 2,
                          border: InputBorder.none,
                          suffixIcon: IconButton(
                            tooltip: _showPassword ? '隐藏密码' : '显示密码',
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _run((_) async => 'WebDAV 设置已保存'),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存连接设置'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                color: colors.surfaceContainerLow,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '手动备份',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '配置文件最多 8 MiB。远端使用单个 JSON 文件；恢复前会验证格式并再次确认。',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _upload,
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('上传配置备份'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _restore,
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('从 WebDAV 恢复'),
                      ),
                    ],
                  ),
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              if (_message != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(_message!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class WebDavBackupClient {
  WebDavBackupClient({
    required String address,
    required this.username,
    required this.password,
  }) : address = address.trim(),
       uri = _validateAddress(address.trim()) {
    if (username.contains(':') ||
        username.contains('\r') ||
        username.contains('\n')) {
      throw const FormatException('WebDAV 用户名不能包含冒号或换行符');
    }
    if (password.contains('\r') || password.contains('\n')) {
      throw const FormatException('WebDAV 密码不能包含换行符');
    }
  }

  static const _maxBytes = 8 * 1024 * 1024;
  static const _requestTimeout = Duration(seconds: 45);
  static const _streamTimeout = Duration(seconds: 30);

  final String address;
  final Uri uri;
  final String username;
  final String password;

  static Uri _validateAddress(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.isEmpty ||
        uri.pathSegments.last.isEmpty) {
      throw const FormatException('请输入有效的 HTTPS WebDAV 文件地址，不要把账号密码放进地址中');
    }
    return uri;
  }

  Future<void> upload(String content) async {
    final bytes = utf8.encode(content);
    if (bytes.length > _maxBytes) {
      throw const FormatException('备份文件超过 8 MiB 上限');
    }
    await _request<void>(
      'PUT',
      body: bytes,
      read: (response) async {
        await response.drain<void>();
      },
    );
  }

  Future<String> download() => _request<String>(
    'GET',
    read: (response) async {
      final bytes = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in response.timeout(_streamTimeout)) {
        size += chunk.length;
        if (size > _maxBytes) {
          throw const FormatException('远程备份超过 8 MiB 上限');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    },
  );

  Future<T> _request<T>(
    String method, {
    required Future<T> Function(HttpClientResponse) read,
    List<int>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (username.isNotEmpty || password.isNotEmpty) {
        final credentials = base64.encode(utf8.encode('$username:$password'));
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic $credentials',
        );
      }
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(_requestTimeout);
      final accepted = method == 'GET'
          ? response.statusCode == HttpStatus.ok
          : const {
              HttpStatus.ok,
              HttpStatus.created,
              HttpStatus.noContent,
            }.contains(response.statusCode);
      if (!accepted) {
        final statusCode = response.statusCode;
        await response.drain<void>();
        throw WebDavBackupException._status(statusCode);
      }
      return await read(response);
    } on TimeoutException {
      throw const WebDavBackupException('WebDAV 请求超时，请检查网络和服务器地址后重试');
    } on SocketException catch (error) {
      throw WebDavBackupException('无法连接 WebDAV 服务器：${error.message}');
    } on HttpException catch (error) {
      throw WebDavBackupException('WebDAV 网络请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}

class WebDavBackupException implements Exception {
  const WebDavBackupException(this.message);

  final String message;

  factory WebDavBackupException._status(int statusCode) =>
      WebDavBackupException(switch (statusCode) {
        HttpStatus.unauthorized => 'WebDAV 认证失败，请检查用户名和密码',
        HttpStatus.forbidden => 'WebDAV 拒绝访问，请检查账号权限',
        HttpStatus.notFound => '找不到 WebDAV 文件或父目录，请检查地址',
        HttpStatus.conflict => 'WebDAV 父目录不存在，请先在服务器创建目录',
        >= 300 && < 400 => 'WebDAV 服务器要求重定向，请改用最终 HTTPS 地址',
        _ => 'WebDAV 请求失败（HTTP $statusCode）',
      });

  @override
  String toString() => message;
}
