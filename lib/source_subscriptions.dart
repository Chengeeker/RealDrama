import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class SourcePackage {
  SourcePackage(this.document, this.origin, this.digest, this.bytes);
  final Map<String, dynamic> document;
  final String origin, digest;
  final List<int> bytes;
  String get id => document['id'] as String;
  String get name => document['name'] as String;
  String get version => document['version'] as String;
  String get program => document['program'] as String;
  List<String> get domains => (document['domains'] as List).cast<String>();
  List<String> get credentialDomains =>
      (document['credentialDomains'] as List? ?? const []).cast<String>();
  Set<String> get capabilities =>
      (document['capabilities'] as List).cast<String>().toSet();
  String get credentialGroup => document['credentialGroup'] as String? ?? id;
  bool get isBundle => document['children'] is List;
  late final List<SourcePackage> sources = isBundle
      ? List.unmodifiable(
          (document['children'] as List).map(
            (child) => SourcePackage(
              {
                ...document,
                ...Map<String, dynamic>.from(child as Map),
                'api': 1,
              }..remove('children'),
              origin,
              digest,
              bytes,
            ),
          ),
        )
      : [this];
  SourceSite get site => SourceSite(
    id,
    name,
    document['description'] as String? ?? '',
    capabilities: capabilities,
    family: document['family'] as String? ?? '',
    kind: document['kind'] as String? ?? 'drama',
  );
  static SourcePackage parse(
    List<int> bytes,
    String origin, {
    String? expectedHash,
    String? expectedId,
  }) {
    if (bytes.length > 4 * 1024 * 1024)
      throw const FormatException('站源包超过 4 MiB');
    final digest = sha256.convert(bytes).toString();
    if (expectedHash != null && digest != expectedHash)
      throw const FormatException('站源包校验失败，原版本已保留');
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['schema'] != 1 ||
        !(value['api'] == 1 ||
            value['api'] == 2 && value['children'] is List) ||
        value['engine'] != 'javascript-generator-v1')
      throw const FormatException('站源协议不兼容，请先更新应用');
    for (final key in ['id', 'name', 'version', 'program']) {
      if (value[key] is! String || (value[key] as String).isEmpty)
        throw FormatException('站源缺少 $key');
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(value['id'] as String) ||
        expectedId != null && value['id'] != expectedId)
      throw const FormatException('站源标识不匹配');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value['version'] as String))
      throw const FormatException('站源版本格式无效');
    for (final key in ['domains', 'capabilities']) {
      if (value[key] is! List ||
          (value[key] as List).any((item) => item is! String))
        throw FormatException('站源 $key 格式无效');
    }
    final domains = (value['domains'] as List).cast<String>();
    if (domains.isEmpty ||
        domains.length > 30 ||
        domains.any(
          (host) =>
              !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) ||
              !host.contains('.') ||
              host.contains('..'),
        ))
      throw const FormatException('站源域名声明无效');
    final credentials = value['credentialDomains'] ?? <String>[];
    if (credentials is! List ||
        credentials.any((host) => host is! String || !domains.contains(host)))
      throw const FormatException('凭据域名必须在声明列表内');
    if (value['browser'] == true && credentials.isNotEmpty)
      throw const FormatException('账号站源不能使用共享浏览器会话');
    final group = value['credentialGroup'] as String? ?? value['id'] as String;
    final protectedDomains = {
      'douyin': {'www.douyin.com', 'www-hj.douyin.com', 'live.douyin.com'},
      'bilibili': {'api.bilibili.com', 'api.live.bilibili.com'},
      'tiktok': {'www.tiktok.com'},
      'youtube': {'www.youtube.com'},
    };
    if (protectedDomains.containsKey(group) &&
        ((group == 'douyin' &&
                !{
                  'douyin',
                  'douyin-live',
                  'douyin-series',
                  'douyin-theater',
                }.contains(value['id'])) ||
            (group == 'bilibili' &&
                !{'bilibili', 'bilibili-live'}.contains(value['id'])) ||
            (group == 'tiktok' && value['id'] != 'tiktok') ||
            (group == 'youtube' && value['id'] != 'youtube')))
      throw const FormatException('订阅无权读取此账号组');
    final allowedCredentialDomains =
        group == 'bilibili' && value['id'] == 'bilibili-live'
        ? {'api.live.bilibili.com'}
        : protectedDomains[group];
    if (allowedCredentialDomains != null &&
        credentials.any((host) => !allowedCredentialDomains.contains(host)))
      throw const FormatException('账号凭据仅允许发送给对应官方域名');
    if ((value['program'] as String).length > 1500000)
      throw const FormatException('站源脚本过大');
    if (value.containsKey('children')) {
      final children = value['children'];
      if (children is! List || children.isEmpty || children.length > 20)
        throw const FormatException('组合站源子项数量无效');
      final ids = <String>{};
      for (final child in children) {
        if (child is! Map<String, dynamic> ||
            child.containsKey('children') ||
            child['id'] is! String ||
            !ids.add(child['id'] as String))
          throw const FormatException('组合站源有重复或无效子项');
        final definition = {...value, ...child, 'api': 1}..remove('children');
        final parsed = SourcePackage.parse(
          utf8.encode(jsonEncode(definition)),
          origin,
        );
        if (!parsed.domains.every(domains.contains))
          throw const FormatException('子项请求域名超出组合包权限');
      }
    }
    return SourcePackage(value, origin, digest, List.unmodifiable(bytes));
  }
}

Future<SourcePackage> parseSourcePackage(
  List<int> bytes,
  String origin, {
  String? expectedHash,
  String? expectedId,
}) => Isolate.run(
  () => SourcePackage.parse(
    bytes,
    origin,
    expectedHash: expectedHash,
    expectedId: expectedId,
  ),
);

Future<dynamic> decodeSubscription(List<int> bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)));

class SourceSubscriptionPreview {
  SourceSubscriptionPreview(
    this.origin,
    this.name,
    this.entries, {
    this.direct,
  });
  final String origin, name;
  final List<Map<String, dynamic>> entries;
  final SourcePackage? direct;
}

class SourceSubscriptions extends ChangeNotifier {
  static final instance = SourceSubscriptions();
  static const officialRepository =
      'https://github.com/Chengeeker/RealDrama-Subscription';
  final _installed = <String, SourcePackage>{};
  final _records = <String, Map<String, dynamic>>{};
  final updates = <String, Map<String, dynamic>>{};
  final problems = <String, String>{};
  final _pending = <String>{};
  late Directory _directory;
  Future<void>? _opening;
  Future<void> _tail = Future.value();
  bool checking = false;
  int revision = 0;
  List<SourcePackage> get installed => List.unmodifiable(_installed.values);
  final _sources = <String, SourcePackage>{};
  List<SourcePackage> get sourcePackages => List.unmodifiable(_sources.values);
  SourcePackage? package(String id) => _sources[id] ?? _installed[id];
  static bool entryContains(Map<String, dynamic> entry, String id) =>
      entry['id'] == id ||
      (entry['children'] as List? ?? const []).whereType<Map>().any(
        (child) => child['id'] == id,
      );
  String? _owner(String id) => _installed.containsKey(id)
      ? id
      : _installed.values
            .where((item) => item.sources.any((child) => child.id == id))
            .firstOrNull
            ?.id;
  bool busy(String id) => _pending.contains(id);
  String independentLink(String id) =>
      _records[id]?['url'] as String? ?? _installed[id]?.origin ?? '';
  String? previousVersion(String id) =>
      _records[_owner(id)]?['previousVersion'] as String?;
  Future<void> open() => _opening ??= _load();
  Future<void> _load() async {
    _directory = Directory(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'source-subscriptions',
      ),
    );
    await _directory.create(recursive: true);
    for (final name in ['registry.json', 'registry.previous.json']) {
      final file = File(path.join(_directory.path, name));
      if (!await file.exists()) continue;
      try {
        if ((await file.stat()).size > 512 * 1024)
          throw const FormatException('站源注册表过大');
        final value = jsonDecode(await file.readAsString());
        if (value is! List || value.length > 100)
          throw const FormatException('注册表格式无效');
        final packages = <String, SourcePackage>{};
        final sourceIds = <String>{};
        final records = <String, Map<String, dynamic>>{};
        final failures = <String, String>{};
        for (final row in value) {
          if (row is! Map) continue;
          final record = Map<String, dynamic>.from(row);
          try {
            final id = record['id'] as String;
            final digest = record['digest'] as String;
            final origin = record['origin'] as String;
            if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
                records.containsKey(id))
              throw const FormatException('注册表路径或标识无效');
            final bytes = await _packageFile(id, digest).readAsBytes();
            final package = await parseSourcePackage(
              bytes,
              origin,
              expectedHash: digest,
              expectedId: id,
            );
            final ids = package.sources.map((child) => child.id).toSet();
            if (ids.any(sourceIds.contains))
              throw const FormatException('本地订阅有重复子源');
            sourceIds.addAll(ids);
            packages[id] = package;
            records[id] = record;
          } catch (_) {
            failures['${record['id']}'] = '本地站源损坏，请重新导入；原用户配置仍保留';
          }
        }
        if (value.isNotEmpty && packages.isEmpty)
          throw const FormatException('订阅程序无法读取');
        if (name == 'registry.previous.json') {
          await file.copy(path.join(_directory.path, 'registry.json'));
          problems['registry'] = '已恢复上一次的订阅配置，请核对站源版本';
        } else {
          problems.remove('registry');
        }
        _installed.addAll(packages);
        _records.addAll(records);
        problems.addAll(failures);
        break;
      } catch (_) {
        problems['registry'] = '本地订阅无法读取，请重新导入；原用户数据仍保留';
      }
    }
    _publish();
  }

  File _packageFile(String id, String digest) =>
      File(path.join(_directory.path, '$id-$digest.json'));
  void _publish() {
    revision++;
    _sources.clear();
    for (final item in installed) {
      for (final child in item.sources) {
        _sources[child.id] = child;
      }
    }
    SourceSite.registerInstalled(
      sourcePackages.map((item) => item.site).toList(),
    );
    notifyListeners();
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<int>> _fetch(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment)
      throw const FormatException('订阅仅支持无凭据的 HTTPS 地址');
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 8));
    if (addresses.isEmpty || addresses.any(privateAddress))
      throw const FormatException('订阅不支持本机或内网地址');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'RealDrama-Subscription/1');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200)
        throw FormatException('订阅请求失败（HTTP ${response.statusCode}）');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 12))) {
        builder.add(chunk);
        if (builder.length > 4 * 1024 * 1024)
          throw const FormatException('订阅内容过大');
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  static bool privateAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4)
      return bytes[0] == 0 ||
          bytes[0] == 10 ||
          bytes[0] == 127 ||
          bytes[0] >= 224 ||
          bytes[0] == 169 && bytes[1] == 254 ||
          bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
          bytes[0] == 192 && bytes[1] == 168 ||
          bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    if (bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return privateAddress(InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return address.isLoopback ||
        address.isLinkLocal ||
        bytes[0] & 0xfe == 0xfc ||
        bytes.every((byte) => byte == 0);
  }

  Future<Uri> _normalize(String text) async {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https')
      throw const FormatException('请填写 HTTPS 仓库、订阅或站源地址');
    if (uri.host != 'github.com') return uri;
    final segments = uri.pathSegments.where((item) => item.isNotEmpty).toList();
    if (segments.length < 2 || uri.hasQuery || uri.userInfo.isNotEmpty)
      throw const FormatException('GitHub 仓库地址无效');
    final owner = segments[0],
        repo = segments[1].replaceFirst(RegExp(r'\.git$'), '');
    if (segments.length >= 5 && segments[2] == 'blob')
      return Uri.https(
        'raw.githubusercontent.com',
        '$owner/$repo/${segments.sublist(3).join('/')}',
      );
    if (segments.length != 2) throw const FormatException('请填写仓库根地址或具体文件链接');
    final metadata =
        jsonDecode(
              utf8.decode(
                await _fetch(
                  Uri.https('api.github.com', '/repos/$owner/$repo'),
                ),
              ),
            )
            as Map;
    final branch = metadata['default_branch'] as String?;
    if (branch == null || branch.isEmpty)
      throw const FormatException('仓库没有默认分支');
    return Uri.https(
      'raw.githubusercontent.com',
      '/$owner/$repo/$branch/subscription.json',
    );
  }

  Future<SourceSubscriptionPreview> preview(String text) async {
    await open();
    final origin = await _normalize(text);
    var requestUri = origin;
    if (origin.host == 'raw.githubusercontent.com' &&
        origin.pathSegments.isNotEmpty &&
        origin.pathSegments.last == 'subscription.json') {
      requestUri = origin.replace(
        queryParameters: {
          ...origin.queryParameters,
          '_rd': DateTime.now().microsecondsSinceEpoch.toString(),
        },
      );
    }
    final bytes = await _fetch(requestUri).timeout(const Duration(seconds: 35));
    final document = await decodeSubscription(bytes);
    if (document is! Map) throw const FormatException('订阅格式无效');
    if (document['engine'] != null) {
      final originText = origin.toString();
      final package = await parseSourcePackage(bytes, originText);
      return SourceSubscriptionPreview(originText, package.name, [
        {...package.document, 'url': originText, 'sha256': package.digest},
      ], direct: package);
    }
    if (document['schema'] != 1 ||
        document['sources'] is! List ||
        (document['sources'] as List).length > 100)
      throw const FormatException('仓库缺少兼容的 subscription.json');
    final entries = <Map<String, dynamic>>[], ids = <String>{};
    for (final row in document['sources'] as List) {
      final entry = Map<String, dynamic>.from(row as Map);
      final id = entry['id'] as String? ?? '';
      final hash = entry['sha256'] as String? ?? '';
      final address = origin.resolve(entry['url'] as String? ?? '');
      if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id) ||
          !ids.add(id) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          address.scheme != 'https' ||
          address.host != origin.host ||
          address.userInfo.isNotEmpty ||
          entry['version'] is! String ||
          entry['name'] is! String)
        throw const FormatException('订阅目录有重复标识、跨域地址或无效校验值');
      entries.add({...entry, 'url': address.toString()});
    }
    return SourceSubscriptionPreview(
      origin.toString(),
      document['name'] as String? ?? '站源订阅',
      entries,
    );
  }

  Future<void> install(
    SourceSubscriptionPreview preview,
    Map<String, dynamic> entry,
  ) => _serialize(() async {
    final id = entry['id'] as String;
    if (_records.length >= 100 && !_records.containsKey(id))
      throw const FormatException('最多安装 100 个站源');
    if (_records[id] != null && _records[id]!['origin'] != preview.origin)
      throw const FormatException('已有同名站源来自另一订阅，请先移除后再导入');
    _pending.add(id);
    notifyListeners();
    try {
      final bytes = preview.direct == null
          ? await _fetch(Uri.parse(entry['url'] as String))
          : preview.direct!.bytes;
      final origin = preview.origin;
      final expectedHash = preview.direct == null
          ? entry['sha256'] as String
          : null;
      final package = await parseSourcePackage(
        bytes,
        origin,
        expectedHash: expectedHash,
        expectedId: id,
      );
      if (package.version != entry['version'])
        throw const FormatException('站源版本与目录不一致');
      for (final field in ['domains', 'credentialDomains', 'capabilities']) {
        if (entry[field] is List &&
            !setEquals(
              (entry[field] as List).toSet(),
              (package.document[field] as List? ?? []).toSet(),
            ))
          throw const FormatException('站源权限与订阅目录不一致');
      }
      if (entry['children'] is List &&
          !setEquals(
            (entry['children'] as List)
                .whereType<Map>()
                .map((child) => child['id'])
                .toSet(),
            package.sources.map((child) => child.id).toSet(),
          ))
        throw const FormatException('组合包子项与目录不一致');
      if (_installed[id]?.digest == package.digest) return;
      final memberIds = package.sources.map((child) => child.id).toSet();
      final replaced = _installed.values
          .where(
            (old) =>
                old.id == id ||
                old.sources.any((child) => memberIds.contains(child.id)),
          )
          .map((old) => old.id)
          .toSet();
      for (final key in replaced) {
        if (_records[key]!['origin'] != preview.origin)
          throw const FormatException('组合包子项来自另一订阅，请先移除冲突订阅');
        if (!_installed[key]!.sources.every(
          (child) => memberIds.contains(child.id),
        ))
          throw const FormatException('组合包与已有子项不完整匹配，原订阅已保留');
      }
      if (package.sources.length +
              _sources.length -
              replaced.fold<int>(
                0,
                (count, key) => count + _installed[key]!.sources.length,
              ) >
          100)
        throw const FormatException('最多安装 100 个子源');
      final previousMembers = [
        for (final key in replaced) _snapshotRecord(_records[key]!),
      ];
      final output = _packageFile(id, package.digest);
      await output.writeAsBytes(bytes, flush: true);
      final old = _records[id];
      final record = <String, dynamic>{
        'id': id,
        'origin': preview.origin,
        'url': entry['url'] ?? preview.origin,
        'digest': package.digest,
        'version': package.version,
        if (old != null) 'previousDigest': old['digest'],
        if (previousMembers.isNotEmpty)
          'previousVersion': old?['version'] ?? '拆分订阅',
        if (previousMembers.isNotEmpty) 'previousMembers': previousMembers,
      };
      final next = {..._records}
        ..removeWhere((key, _) => replaced.contains(key));
      next[id] = record;
      await _save(next);
      for (final key in replaced) {
        _records.remove(key);
        _installed.remove(key);
        updates.remove(key);
        problems.remove(key);
      }
      _records[id] = record;
      _installed[id] = package;
      updates.remove(id);
      problems.remove(id);
      _publish();
      await _prune(id);
    } finally {
      _pending.remove(id);
      notifyListeners();
    }
  });
  Future<void> importLocal(String filePath) async {
    await open();
    final file = File(filePath);
    if ((await file.stat()).size > 4 * 1024 * 1024)
      throw const FormatException('站源文件过大');
    final bytes = await file.readAsBytes();
    final origin = 'local:${path.basename(filePath)}';
    final package = await parseSourcePackage(bytes, origin);
    final preview = SourceSubscriptionPreview(
      package.origin,
      package.name,
      [],
      direct: package,
    );
    await install(preview, {'id': package.id, 'version': package.version});
  }

  Map<String, dynamic> _snapshotRecord(Map<String, dynamic> row) => {...row}
    ..remove('previousMembers')
    ..remove('previousDigest')
    ..remove('previousVersion');

  Future<void> _save(Map<String, Map<String, dynamic>> records) async {
    final temporary = File(path.join(_directory.path, 'registry.pending'));
    await temporary.writeAsString(
      jsonEncode(records.values.toList()),
      flush: true,
    );
    final current = File(path.join(_directory.path, 'registry.json'));
    if (await current.exists())
      await current.copy(path.join(_directory.path, 'registry.previous.json'));
    await temporary.rename(current.path);
  }

  Future<void> rollback(String id) => _serialize(() async {
    final owner = _owner(id);
    if (owner == null) return;
    final old = _records[owner]!;
    final members = (old['previousMembers'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    if (members.isEmpty) {
      final previous = old['previousDigest'] as String?;
      if (previous == null) return;
      members.add({
        ...old,
        'digest': previous,
        'version': old['previousVersion'],
      });
    }
    final restored = <String, SourcePackage>{};
    final records = <String, Map<String, dynamic>>{};
    for (final member in members) {
      final row = Map<String, dynamic>.from(member);
      final key = row['id'] as String;
      final digest = row['digest'] as String;
      if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(key) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          restored.containsKey(key))
        throw const FormatException('回退记录无效，当前订阅已保留');
      restored[key] = await parseSourcePackage(
        await _packageFile(key, digest).readAsBytes(),
        row['origin'] as String,
        expectedHash: digest,
        expectedId: key,
      );
      records[key] = row;
    }
    final ids = restored.values
        .expand((item) => item.sources)
        .map((item) => item.id)
        .toSet();
    final removed = _installed.values
        .where(
          (item) =>
              item.id == owner ||
              item.sources.any((child) => ids.contains(child.id)),
        )
        .map((item) => item.id)
        .toSet();
    final currentMembers = [
      for (final key in removed) _snapshotRecord(_records[key]!),
    ];
    final first = records.keys.first;
    records[first] = {
      ...records[first]!,
      'previousMembers': currentMembers,
      'previousVersion': _installed[owner]!.version,
    };
    final next = {..._records}..removeWhere((key, _) => removed.contains(key));
    next.addAll(records);
    await _save(next);
    for (final key in removed) {
      _installed.remove(key);
      updates.remove(key);
      problems.remove(key);
    }
    _records
      ..clear()
      ..addAll(next);
    _installed.addAll(restored);
    _publish();
  });
  Future<void> remove(String id) => _serialize(() async {
    final next = {..._records}..remove(id);
    await _save(next);
    _records.remove(id);
    _installed.remove(id);
    updates.remove(id);
    problems.remove(id);
    _publish();
    await _prune(id);
  });
  Future<void> _prune(String id) async {
    final keep = {
      _records[id]?['digest'],
      _records[id]?['previousDigest'],
      for (final row
          in (_records[id]?['previousMembers'] as List? ?? const [])
              .whereType<Map>())
        if (row['id'] == id) row['digest'],
    };
    try {
      final backup = File(path.join(_directory.path, 'registry.previous.json'));
      if (await backup.exists() && (await backup.stat()).size <= 512 * 1024) {
        final rows = jsonDecode(await backup.readAsString()) as List;
        for (final row in rows.whereType<Map>().where(
          (row) => row['id'] == id,
        )) {
          keep.add(row['digest']);
          keep.add(row['previousDigest']);
        }
      }
    } catch (_) {}
    await for (final file in _directory.list()) {
      if (file is File &&
          path.basename(file.path).startsWith('$id-') &&
          path.extension(file.path) == '.json') {
        final digest = path
            .basenameWithoutExtension(file.path)
            .substring(id.length + 1);
        if (!keep.contains(digest)) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> checkUpdatesIfDue() async {
    await open();
    if (_records.isEmpty || checking) return;
    final marker = File(path.join(_directory.path, 'updates.checked'));
    try {
      if (await marker.exists() &&
          DateTime.now().difference(await marker.lastModified()) <
              const Duration(hours: 24))
        return;
      await marker.writeAsString(DateTime.now().toIso8601String(), flush: true);
    } catch (_) {}
    await checkUpdates();
  }

  Future<void> checkUpdates() async {
    if (checking) return;
    checking = true;
    notifyListeners();
    try {
      for (final origin
          in _records.values.map((row) => row['origin'] as String).toSet()) {
        if (origin.startsWith('local:')) continue;
        try {
          final value = await preview(origin);
          problems.remove(origin);
          for (final entry in value.entries) {
            final owners = _installed.values.where(
              (item) =>
                  _records[item.id]?['origin'] == origin &&
                  item.sources.any((child) => entryContains(entry, child.id)),
            );
            for (final owner in owners) {
              final id = owner.id;
              if (entry['sha256'] != _installed[id]?.digest) {
                updates[id] = entry;
              } else {
                updates.remove(id);
              }
            }
          }
        } catch (_) {
          problems[origin] = '检查更新失败，已安装的站源仍可使用';
        }
      }
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<int> updateAll() async {
    await open();
    if (checking) throw const FormatException('正在检查或更新站源，请稍后重试');
    final origins = _records.values
        .map((record) => record['origin'] as String)
        .where((origin) => !origin.startsWith('local:'))
        .toSet();
    if (origins.isEmpty) return 0;
    checking = true;
    notifyListeners();
    var updatedCount = 0;
    final failures = <String>[];
    try {
      for (final origin in origins) {
        SourceSubscriptionPreview previewValue;
        try {
          previewValue = await preview(origin);
          problems.remove(origin);
        } catch (exception) {
          problems[origin] = '检查更新失败，已安装的站源仍可使用';
          failures.add('$origin：${_updateFailure(exception)}');
          continue;
        }
        final originIds = _records.entries
            .where((entry) => entry.value['origin'] == origin)
            .map((entry) => entry.key)
            .toSet();
        for (final id in originIds) {
          updates.remove(id);
        }
        for (final entry in previewValue.entries) {
          final id = entry['id'] as String;
          if (!_installed.values.any(
            (item) =>
                originIds.contains(item.id) &&
                item.sources.any((child) => entryContains(entry, child.id)),
          ))
            continue;
          if (entry['sha256'] == _installed[id]?.digest) continue;
          updates[id] = entry;
          try {
            await install(previewValue, entry);
            updatedCount++;
          } catch (exception) {
            failures.add('${entry['name']}：${_updateFailure(exception)}');
          }
        }
      }
    } finally {
      checking = false;
      notifyListeners();
    }
    if (failures.isNotEmpty) {
      throw FormatException(
        '已更新 $updatedCount 个站源；以下项目失败：${failures.join('、')}',
      );
    }
    return updatedCount;
  }

  String _updateFailure(Object exception) {
    if (exception is FormatException) return exception.message.toString();
    if (exception is TimeoutException) return '请求超时';
    if (exception is SocketException) return '网络连接失败';
    if (exception is FileSystemException) return '本地保存失败，请检查空间';
    return '更新失败';
  }

  Future<void> update(String id) async {
    final origin = _records[id]!['origin'] as String;
    final value = await preview(origin);
    final entry = value.entries
        .where((row) => entryContains(row, id))
        .firstOrNull;
    if (entry == null) throw const FormatException('上游已移除此站源，保留本地版本');
    await install(value, entry);
  }
}
