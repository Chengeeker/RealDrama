import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class SourcePackage {
  SourcePackage(this.document, this.origin, this.digest);
  final Map<String, dynamic> document;
  final String origin, digest;
  String get id => document['id'] as String;
  String get name => document['name'] as String;
  String get version => document['version'] as String;
  String get program => document['program'] as String;
  List<String> get domains => (document['domains'] as List).cast<String>();
  List<String> get credentialDomains => (document['credentialDomains'] as List? ?? const []).cast<String>();
  Set<String> get capabilities => (document['capabilities'] as List).cast<String>().toSet();
  String get credentialGroup => document['credentialGroup'] as String? ?? id;
  SourceSite get site => SourceSite(id, name, document['description'] as String? ?? '', capabilities: capabilities, family: document['family'] as String? ?? '', kind: document['kind'] as String? ?? 'drama');
  static SourcePackage parse(List<int> bytes, String origin, {String? expectedHash, String? expectedId}) {
    if (bytes.length > 2 * 1024 * 1024) throw const FormatException('站源包超过 2 MiB');
    final digest = sha256.convert(bytes).toString();
    if (expectedHash != null && digest != expectedHash) throw const FormatException('站源包校验失败，原版本已保留');
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> || value['schema'] != 1 || value['api'] != 1 || value['engine'] != 'javascript-generator-v1') throw const FormatException('站源协议不兼容，请先更新应用');
    for (final key in ['id', 'name', 'version', 'program']) {
      if (value[key] is! String || (value[key] as String).isEmpty) throw FormatException('站源缺少 $key');
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(value['id'] as String) || expectedId != null && value['id'] != expectedId) throw const FormatException('站源标识不匹配');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value['version'] as String)) throw const FormatException('站源版本格式无效');
    for (final key in ['domains', 'capabilities']) {
      if (value[key] is! List || (value[key] as List).any((item) => item is! String)) throw FormatException('站源 $key 格式无效');
    }
    final domains = (value['domains'] as List).cast<String>();
    if (domains.isEmpty || domains.length > 30 || domains.any((host) => !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) || !host.contains('.') || host.contains('..'))) throw const FormatException('站源域名声明无效');
    final credentials = value['credentialDomains'] ?? <String>[];
    if (credentials is! List || credentials.any((host) => host is! String || !domains.contains(host))) throw const FormatException('凭据域名必须在声明列表内');
    if ((value['program'] as String).length > 1500000) throw const FormatException('站源脚本过大');
    return SourcePackage(value, origin, digest);
  }
}

class SourceSubscriptionPreview {
  SourceSubscriptionPreview(this.origin, this.name, this.entries, {this.direct});
  final String origin, name;
  final List<Map<String, dynamic>> entries;
  final SourcePackage? direct;
}

class SourceSubscriptions extends ChangeNotifier {
  static final instance = SourceSubscriptions();
  static const officialRepository = 'https://github.com/Chengeeker/RealDrama-Subscription';
  final _installed = <String, SourcePackage>{};
  final _records = <String, Map<String, dynamic>>{};
  final updates = <String, Map<String, dynamic>>{};
  final problems = <String, String>{};
  final _pending = <String>{};
  late Directory _directory;
  Future<void>? _opening;
  Future<void> _tail = Future.value();
  bool checking = false;
  List<SourcePackage> get installed => List.unmodifiable(_installed.values);
  SourcePackage? package(String id) => _installed[id];
  bool busy(String id) => _pending.contains(id);
  String? previousVersion(String id) => _records[id]?['previousVersion'] as String?;
  Future<void> open() => _opening ??= _load();
  Future<void> _load() async {
    _directory = Directory(path.join((await getApplicationSupportDirectory()).path, 'source-subscriptions'));
    await _directory.create(recursive: true);
    final file = File(path.join(_directory.path, 'registry.json'));
    if (await file.exists()) {
      final stat = await file.stat();
      if (stat.size > 512 * 1024) throw const FormatException('站源注册表过大');
      final rows = jsonDecode(await file.readAsString()) as List;
      for (final row in rows.take(100)) {
        final record = Map<String, dynamic>.from(row as Map);
        try {
          final id = record['id'] as String;
          final digest = record['digest'] as String;
          if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) throw const FormatException('注册表路径无效');
          final package = SourcePackage.parse(await _packageFile(id, digest).readAsBytes(), record['origin'] as String, expectedHash: digest, expectedId: id);
          _installed[id] = package;
          _records[id] = record;
        } catch (_) { problems['${record['id']}'] = '本地站源损坏，请重新导入；原用户配置仍保留'; }
      }
    }
    _publish();
  }
  File _packageFile(String id, String digest) => File(path.join(_directory.path, '$id-$digest.json'));
  void _publish() {
    SourceSite.registerInstalled(installed.map((item) => item.site).toList());
    notifyListeners();
  }
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
  Future<List<int>> _fetch(Uri uri) async {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443 || uri.hasFragment) throw const FormatException('订阅仅支持无凭据的 HTTPS 地址');
    final addresses = await InternetAddress.lookup(uri.host).timeout(const Duration(seconds: 8));
    if (addresses.isEmpty || addresses.any(privateAddress)) throw const FormatException('订阅不支持本机或内网地址');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'RealDrama-Subscription/1');
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw FormatException('订阅请求失败（HTTP ${response.statusCode}）');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 12))) {
        builder.add(chunk);
        if (builder.length > 2 * 1024 * 1024) throw const FormatException('订阅内容过大');
      }
      return builder.takeBytes();
    } finally { client.close(force: true); }
  }
  static bool privateAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) return bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 || bytes[0] == 169 && bytes[1] == 254 || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 || bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    return address.isLoopback || address.isLinkLocal || bytes[0] & 0xfe == 0xfc || bytes.every((byte) => byte == 0);
  }
  Future<Uri> _normalize(String text) async {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https') throw const FormatException('请填写 HTTPS 仓库、订阅或站源地址');
    if (uri.host != 'github.com') return uri;
    final segments = uri.pathSegments.where((item) => item.isNotEmpty).toList();
    if (segments.length < 2 || uri.hasQuery || uri.userInfo.isNotEmpty) throw const FormatException('GitHub 仓库地址无效');
    final owner = segments[0], repo = segments[1].replaceFirst(RegExp(r'\.git$'), '');
    if (segments.length >= 5 && segments[2] == 'blob') return Uri.https('raw.githubusercontent.com', '$owner/$repo/${segments.sublist(3).join('/')}');
    if (segments.length != 2) throw const FormatException('请填写仓库根地址或具体文件链接');
    final metadata = jsonDecode(utf8.decode(await _fetch(Uri.https('api.github.com', '/repos/$owner/$repo')))) as Map;
    final branch = metadata['default_branch'] as String?;
    if (branch == null || branch.isEmpty) throw const FormatException('仓库没有默认分支');
    return Uri.https('raw.githubusercontent.com', '/$owner/$repo/$branch/subscription.json');
  }
  Future<SourceSubscriptionPreview> preview(String text) async {
    await open();
    final uri = await _normalize(text);
    final bytes = await _fetch(uri).timeout(const Duration(seconds: 35));
    final document = jsonDecode(utf8.decode(bytes));
    if (document is! Map) throw const FormatException('订阅格式无效');
    if (document['engine'] != null) {
      final package = SourcePackage.parse(bytes, uri.toString());
      return SourceSubscriptionPreview(uri.toString(), package.name, [{...package.document, 'url': uri.toString(), 'sha256': package.digest}], direct: package);
    }
    if (document['schema'] != 1 || document['sources'] is! List || (document['sources'] as List).length > 100) throw const FormatException('仓库缺少兼容的 subscription.json');
    final entries = <Map<String, dynamic>>[], ids = <String>{};
    for (final row in document['sources'] as List) {
      final entry = Map<String, dynamic>.from(row as Map);
      final id = entry['id'] as String? ?? '';
      final hash = entry['sha256'] as String? ?? '';
      final address = uri.resolve(entry['url'] as String? ?? '');
      if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) || !ids.add(id) || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) || address.scheme != 'https' || address.host != uri.host || address.userInfo.isNotEmpty || entry['version'] is! String || entry['name'] is! String) throw const FormatException('订阅目录有重复标识、跨域地址或无效校验值');
      entries.add({...entry, 'url': address.toString()});
    }
    return SourceSubscriptionPreview(uri.toString(), document['name'] as String? ?? '站源订阅', entries);
  }
  Future<void> install(SourceSubscriptionPreview preview, Map<String, dynamic> entry) => _serialize(() async {
    final id = entry['id'] as String;
    if (_records[id] != null && _records[id]!['origin'] != preview.origin) throw const FormatException('已有同名站源来自另一订阅，请先移除后再导入');
    _pending.add(id); notifyListeners();
    try {
      final bytes = preview.direct == null ? await _fetch(Uri.parse(entry['url'] as String)) : utf8.encode(jsonEncode(preview.direct!.document));
      final package = preview.direct == null ? SourcePackage.parse(bytes, preview.origin, expectedHash: entry['sha256'] as String, expectedId: id) : SourcePackage.parse(bytes, preview.origin, expectedId: id);
      if (package.version != entry['version']) throw const FormatException('站源版本与目录不一致');
      if (_installed[id]?.digest == package.digest) return;
      final output = _packageFile(id, package.digest);
      await output.writeAsBytes(bytes, flush: true);
      final old = _records[id];
      final record = <String,dynamic>{'id': id, 'origin': preview.origin, 'digest': package.digest, 'version': package.version, if (old != null) 'previousDigest': old['digest'], if (old != null) 'previousVersion': old['version']};
      final next = {..._records, id: record};
      await _save(next);
      _records[id] = record; _installed[id] = package;
      updates.remove(id); problems.remove(id);
      _publish();
      await _prune(id);
    } finally { _pending.remove(id); notifyListeners(); }
  });
  Future<void> importLocal(String filePath) async {
    await open();
    final file = File(filePath);
    if ((await file.stat()).size > 2 * 1024 * 1024) throw const FormatException('站源文件过大');
    final package = SourcePackage.parse(await file.readAsBytes(), 'local:${path.basename(filePath)}');
    final preview = SourceSubscriptionPreview(package.origin, package.name, [], direct: package);
    await install(preview, {'id': package.id, 'version': package.version});
  }
  Future<void> _save(Map<String, Map<String,dynamic>> records) async {
    final temporary = File(path.join(_directory.path, 'registry.pending'));
    await temporary.writeAsString(jsonEncode(records.values.toList()), flush: true);
    await temporary.rename(path.join(_directory.path, 'registry.json'));
  }
  Future<void> rollback(String id) => _serialize(() async {
    final old = _records[id]!;
    final previous = old['previousDigest'] as String?;
    if (previous == null) return;
    final package = SourcePackage.parse(await _packageFile(id, previous).readAsBytes(), old['origin'] as String, expectedHash: previous, expectedId: id);
    final record = {...old, 'digest': previous, 'version': package.version, 'previousDigest': old['digest'], 'previousVersion': old['version']};
    await _save({..._records, id: record});
    _records[id] = record; _installed[id] = package; _publish();
  });
  Future<void> remove(String id) => _serialize(() async {
    final next = {..._records}..remove(id);
    await _save(next);
    _records.remove(id); _installed.remove(id); updates.remove(id); problems.remove(id); _publish();
    await _prune(id);
  });
  Future<void> _prune(String id) async {
    final keep = {_records[id]?['digest'], _records[id]?['previousDigest']};
    await for (final file in _directory.list()) {
      if (file is File && path.basename(file.path).startsWith('$id-') && path.extension(file.path) == '.json') {
        final digest = path.basenameWithoutExtension(file.path).substring(id.length + 1);
        if (!keep.contains(digest)) { try { await file.delete(); } catch (_) {} }
      }
    }
  }
  Future<void> checkUpdates() async {
    if (checking) return;
    checking = true; notifyListeners();
    try {
      for (final origin in _records.values.map((row) => row['origin'] as String).toSet()) {
        if (origin.startsWith('local:')) continue;
        try {
          final value = await preview(origin);
          for (final entry in value.entries) {
            final id = entry['id'] as String;
            if (_records[id]?['origin'] == origin && entry['sha256'] != _installed[id]?.digest) updates[id] = entry;
          }
        } catch (_) { problems[origin] = '检查更新失败，已安装的站源仍可使用'; }
      }
    } finally { checking = false; notifyListeners(); }
  }
  Future<void> update(String id) async {
    final origin = _records[id]!['origin'] as String;
    final value = await preview(origin);
    final entry = value.entries.where((row) => row['id'] == id).firstOrNull;
    if (entry == null) throw const FormatException('上游已移除此站源，保留本地版本');
    await install(value, entry);
  }
}
