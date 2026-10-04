import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'models.dart';
import 'source_subscriptions.dart';
import 'source_status.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Request = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
String _sourceStep(String input, [String symbol = 'RealDramaSourceRequest']) {
  final library = Platform.isAndroid
      ? DynamicLibrary.open('libduanju_core.so')
      : Platform.isWindows
      ? DynamicLibrary.open(
          path.join(
            path.dirname(Platform.resolvedExecutable),
            'duanju_core.dll',
          ),
        )
      : DynamicLibrary.process();
  final request = library.lookupFunction<_NativeRequest, _Request>(symbol);
  final free = library.lookupFunction<_NativeFree, _Free>('DuanjuFree');
  final argument = input.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(argument);
    if (output == nullptr) throw const FormatException('站源运行环境不可用');
    return output.toDartString();
  } finally {
    malloc.free(argument);
    if (output != nullptr) free(output);
  }
}

Future<Map<String, dynamic>> _runSourceWorker(
  Map<String, dynamic> request, [
  String symbol = 'RealDramaSourceRequest',
]) => Isolate.run(
  () =>
      jsonDecode(_sourceStep(jsonEncode(request), symbol))
          as Map<String, dynamic>,
);

Future<String> _runSourceRaw(
  String body, [
  String symbol = 'RealDramaSourceRequest',
]) => Isolate.run(() => _sourceStep(body, symbol));

Future<String> _encodeCache(Map<String, dynamic> data) =>
    Isolate.run(() => jsonEncode(data));

Future<(Map<String, dynamic>, CatalogPage)> _readCatalogCache(
  String filePath,
  String legacyPath,
  bool allowLegacy,
  String source,
  String category,
) => Isolate.run(() {
  final input = File(filePath);
  Map<String, dynamic> data = {};
  if (input.existsSync() && input.lengthSync() <= 16 * 1024 * 1024) {
    data = jsonDecode(input.readAsStringSync()) as Map<String, dynamic>;
  } else if (allowLegacy) {
    final old = File(legacyPath);
    if (old.existsSync() && old.lengthSync() <= 32 * 1024 * 1024) {
      final legacy = jsonDecode(old.readAsStringSync()) as Map;
      final oldKey = category.isEmpty ? source : '$source|$category';
      final rows =
          (legacy['catalogs'] is Map
                  ? (legacy['catalogs'] as Map)[oldKey]
                  : legacy[oldKey])
              as List?;
      if (rows != null) {
        final states = legacy['states'] as Map? ?? {};
        final state = states[oldKey] as Map? ?? {};
        data = {
          ...Map<String, dynamic>.from(state),
          'items': rows.take(5000).toList(),
          'page': 1,
          'hasMore': true,
          'migrated': true,
          'warning': '旧目录已保留；订阅将重新建立后续分页',
        };
      }
    }
  }
  return (data, CatalogPage.fromJson(data));
});

class SubscriptionRuntime {
  static int _slots = 0;
  static final _waiters = <Completer<void>>[];
  static final _douyinRequestTails = <String, Future<void>>{};
  static final _douyinNextRequestAt = <String, DateTime>{};
  static final _douyinCooldownUntil = <String, DateTime>{};
  static Future<void> _acquire() async {
    if (_slots < 3) {
      _slots++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  static void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _slots--;
    }
  }

  SubscriptionRuntime(this.store) {
    SourceSubscriptions.instance.addListener(_accessChanged);
  }
  final LocalStore? Function() store;
  final _states = <String, Map<String, dynamic>>{};
  final _pages = <String, CatalogPage>{};
  final _pageMeta = <String, Map<String, dynamic>>{};
  final _cacheLoads = <String, Future<CatalogPage>>{};
  final _cacheWrites = <String, Future<void>>{};
  final _categoryCache =
      <String, ({DateTime fetchedAt, List<CatalogCategory> items})>{};
  final _categoryLoads = <String, Future<List<CatalogCategory>>>{};
  Future<void> _legacyTail = Future.value();
  LocalStore? _observedStore;
  int? _observedEpoch;
  int _observedVisibility = -1;
  int _observedRevision = -1;
  void _watch() {
    final current = store();
    if (!identical(current, _observedStore)) {
      _observedStore?.removeListener(_accessChanged);
      _observedStore = current;
      current?.addListener(_accessChanged);
    }
    _accessChanged();
  }

  void _accessChanged() {
    final access = store();
    final revision = SourceSubscriptions.instance.revision;
    if (_observedEpoch == access?.profileEpoch &&
        _observedVisibility == access?.sourceVisibilityRevision &&
        _observedRevision == revision &&
        access?.locked != true)
      return;
    if (_observedEpoch != null) {
      cancel(null);
      _categoryCache.clear();
      _categoryLoads.clear();
    }
    _observedEpoch = access?.profileEpoch;
    _observedVisibility = access?.sourceVisibilityRevision ?? -1;
    _observedRevision = revision;
  }

  final _jobs = <String, Map<String, dynamic>>{};
  final _clients = <String, Set<HttpClient>>{};
  final _generation = <String, int>{};
  final _actionGeneration = <String, int>{};
  final _active = <String, String>{};
  final _activeActions = <String, String>{};
  final _cancelledRequests = <String>{};
  final _tails = <String, Future<void>>{};
  final _tailScopes = <String, String>{};
  final _httpReads = <String, Map<String, dynamic>>{};
  int _serial = 0;
  String _identity(String source) => '${store()?.profile.id}:$source';
  String _lane(String source, String action) => action == 'danmaku'
      ? ':danmaku'
      : source == 'bilibili' &&
            const {'detail', 'metadata', 'resolve'}.contains(action)
      ? ':playback'
      : '';
  String _cacheKey(String source, String category) =>
      '${_identity(source)}:$category';
  void _authorize(String source, int? epoch, String digest) {
    final access = store();
    if (access == null ||
        access.locked ||
        access.profileEpoch != epoch ||
        !access.allowsSource(source) ||
        SourceSubscriptions.instance.package(source)?.digest != digest)
      throw const FormatException('站源已关闭、更新或用户已切换');
  }

  Future<Map<String, dynamic>> execute(
    String source,
    String action,
    Map<String, dynamic> payload, {
    bool configure = false,
  }) {
    _watch();
    final scope = _identity(source);
    final queueKey = '$scope${_lane(source, action)}';
    final previous = _tails[queueKey] ?? Future.value();
    final epoch = store()?.profileEpoch;
    final package = SourceSubscriptions.instance.package(source);
    if (package == null)
      return Future.error(const FormatException('请先导入此站源的订阅包'));
    final generation = _generation[scope] ?? 0;
    final actionGeneration = _actionGeneration['$scope:$action'] ?? 0;
    final result = previous.then((_) {
      if (store()?.profileEpoch != epoch ||
          generation != (_generation[scope] ?? 0) ||
          actionGeneration != (_actionGeneration['$scope:$action'] ?? 0))
        throw const FormatException('请求已取消');
      return (() async {
        await _acquire();
        try {
          if (generation != (_generation[scope] ?? 0) ||
              actionGeneration != (_actionGeneration['$scope:$action'] ?? 0))
            throw const FormatException('请求已取消');
          return await _execute(package, action, payload, configure: configure);
        } finally {
          _release();
        }
      })();
    });
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _tails[queueKey] = tail;
    _tailScopes[queueKey] = scope;
    unawaited(
      tail.then((_) {
        if (identical(_tails[queueKey], tail)) {
          _tails.remove(queueKey);
          _tailScopes.remove(queueKey);
        }
      }),
    );
    return result;
  }

  Future<Map<String, dynamic>> _execute(
    SourcePackage package,
    String action,
    Map<String, dynamic> payload, {
    bool configure = false,
  }) async {
    final access = store();
    if (access == null || access.locked) throw const FormatException('请先解锁应用');
    final epoch = access.profileEpoch;
    final source = package.id, identity = _identity(package.id);
    if (!configure) _authorize(source, epoch, package.digest);
    final generation = _generation[identity] ?? 0;
    final actionGeneration = _actionGeneration['$identity:$action'] ?? 0;
    final id = '${DateTime.now().microsecondsSinceEpoch}:${++_serial}';
    _active[id] = identity;
    _activeActions[id] = action;
    final stateKey = '$identity:${package.digest}${_lane(source, action)}';
    var request = <String, dynamic>{
      'command': 'start',
      'id': id,
      'program': package.program,
      'action': action,
      'payload': {
        ...payload,
        'source': source,
        if (action == 'creator' && package.credentialGroup == 'douyin')
          'videoSource':
              ['douyin', 'douyin-theater']
                  .where(
                    (id) =>
                        SourceSite.isAvailable(id) && access.allowsSource(id),
                  )
                  .firstOrNull ??
              '',
      },
      'state': _states[stateKey] ?? <String, dynamic>{},
    };
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      for (var step = 0; step < 16; step++) {
        if (DateTime.now().isAfter(deadline) ||
            generation != (_generation[identity] ?? 0) ||
            actionGeneration != (_actionGeneration['$identity:$action'] ?? 0))
          throw const FormatException('站源请求超时或已取消');
        if (!configure) _authorize(source, epoch, package.digest);
        final stepRequest = request;
        final envelope = await _runSourceWorker(stepRequest);
        if (envelope['ok'] != true) {
          final status = envelope['httpStatus'];
          if (status is int && status >= 400 && status <= 599) {
            if (status == 401 || status == 403) {
              _states[stateKey]?.remove('token');
              _states[stateKey]?.remove('wbi');
            }
            throw FormatException('站源请求失败（HTTP $status），请检查网络或更新站源');
          }
          _states[stateKey]?.remove('token');
          _states[stateKey]?.remove('wbi');
          if (envelope['code'] == 'source_http' && status == 0)
            throw const FormatException('站源连接失败或超时，请稍后重试');
          throw FormatException(envelope['error'] as String? ?? '站源执行失败');
        }
        final data = Map<String, dynamic>.from(envelope['data'] as Map);
        if (data['done'] == true) {
          if (!configure) _authorize(source, epoch, package.digest);
          if (epoch != store()?.profileEpoch ||
              generation != (_generation[identity] ?? 0) ||
              actionGeneration != (_actionGeneration['$identity:$action'] ?? 0))
            throw const FormatException('请求已取消');
          final value = Map<String, dynamic>.from(data['value'] as Map? ?? {});
          if (value['state'] is Map) {
            _states[stateKey] = Map<String, dynamic>.from(
              value.remove('state') as Map,
            );
            while (_states.length > 64) {
              _states.remove(_states.keys.first);
            }
          }
          if (value['error'] is String)
            throw FormatException(value['error'] as String);
          return value;
        }
        final command = Map<String, dynamic>.from(data['value'] as Map);
        Object response;
        if (command['type'] == 'sign') {
          if (!Platform.isAndroid || package.credentialGroup != 'douyin')
            throw const FormatException('此签名能力当前仅支持 Android 抖音订阅');
          response =
              await const MethodChannel('realdrama/douyin')
                  .invokeMethod<String>('sign', {
                    'query': command['query'] as String,
                    'userAgent': command['userAgent'] as String,
                  })
                  .timeout(const Duration(seconds: 6)) ??
              '';
        } else if (command['type'] == 'http') {
          response = await _http(
            package,
            command,
            id,
            access.profile.id,
            deadline,
          );
        } else {
          throw const FormatException('站源请求了不支持的运行能力');
        }
        request = {'command': 'next', 'id': id, 'response': response};
      }
      throw const FormatException('站源单次请求次数过多');
    } finally {
      final read = _httpReads.remove(id);
      if (read != null) {
        try {
          await _runSourceRaw(
            jsonEncode({'action': 'cancelRead', ...read}),
            'DuanjuRequest',
          );
        } catch (_) {}
      }
      _active.remove(id);
      _activeActions.remove(id);
      _cancelledRequests.remove(id);
      for (final client in _clients.remove(id) ?? <HttpClient>{}) {
        client.close(force: true);
      }
      final body = jsonEncode({'command': 'cancel', 'id': id});
      try {
        await _runSourceRaw(body);
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _http(
    SourcePackage package,
    Map<String, dynamic> command,
    String id,
    String profile,
    DateTime deadline,
  ) async {
    var uri = Uri.parse(command['url'] as String);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !package.domains.contains(uri.host))
      throw const FormatException('站源请求超出声明域名');
    if (deadline.difference(DateTime.now()) <= Duration.zero)
      throw const FormatException('站源请求超时');
    String? cookie;
    if (command['credential'] == true) {
      if (!package.credentialDomains.contains(uri.host))
        throw const FormatException('禁止向此域名发送凭据');
      final group = package.credentialGroup;
      final key = group == 'douyin'
          ? 'douyin.cookie.$profile'
          : group == 'bilibili'
          ? 'bilibili.cookie.$profile'
          : 'source.cookie.$group.$profile';
      cookie = await const FlutterSecureStorage().read(key: key);
      if ((cookie == null || cookie.isEmpty) &&
          package.document['credentialRequired'] == true)
        throw const FormatException('请在站源管理中配置账号 Cookie');
    }
    if (command['sign'] == true) {
      if (package.credentialGroup != 'douyin' ||
          !Platform.isAndroid ||
          !package.credentialDomains.contains(uri.host))
        throw const FormatException('抖音签名目前仅支持 Android');
      final token = (cookie ?? '')
          .split(';')
          .map((item) => item.trim())
          .where((item) => item.startsWith('msToken='))
          .firstOrNull;
      final parameters = {
        ...uri.queryParameters,
        if (token != null) 'msToken': token.substring('msToken='.length),
      };
      uri = uri.replace(queryParameters: parameters);
      final signature = await const MethodChannel('realdrama/douyin')
          .invokeMethod<String>('sign', {
            'query': uri.query,
            'userAgent': (command['headers'] as Map?)?['User-Agent'] ?? '',
          })
          .timeout(const Duration(seconds: 6));
      if (signature == null || signature.isEmpty)
        throw const FormatException('抖音签名暂不可用');
      uri = uri.replace(
        query: '${uri.query}&a_bogus=${Uri.encodeComponent(signature)}',
      );
    }
    final body = command['body'];
    final read = {
      'session':
          'subscription:${sha256.convert(utf8.encode(_identity(package.id)))}${_lane(package.id, _activeActions[id] ?? '')}',
      'sequence': DateTime.now().microsecondsSinceEpoch + ++_serial,
    };
    _httpReads[id] = read;
    final request = <String, dynamic>{
      'action': 'subscriptionHttp',
      ...read,
      'subscriptionHttp': {
        'url': uri.toString(),
        'method': command['method'] ?? 'GET',
        'headers': command['headers'] ?? {},
        'binary': command['binary'] == true,
        'body': body == null
            ? ''
            : body is String
            ? body
            : jsonEncode(body),
        'domains': package.domains,
        'credentialDomains': package.credentialDomains,
        'cookie': cookie ?? '',
        'browser': package.document['browser'] == true,
        'background':
            _activeActions[id] == 'catalog' &&
            _jobs[_identity(package.id)]?['running'] == true,
      },
    };
    Future<Map<String, dynamic>> send() async {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw const FormatException('站源请求超时');
      final envelope = await _runSourceWorker(
        request,
        'DuanjuRequest',
      ).timeout(remaining);
      if (envelope['ok'] != true) return {'status': 0, 'text': ''};
      return Map<String, dynamic>.from(envelope['data'] as Map);
    }

    if (package.credentialGroup == 'douyin' &&
        const {
          'catalog',
          'categories',
          'search',
        }.contains(_activeActions[id])) {
      return _pacedDouyinRequest('$profile:douyin', id, deadline, send);
    }
    return send();
  }

  Future<Map<String, dynamic>> _pacedDouyinRequest(
    String key,
    String requestId,
    DateTime deadline,
    Future<Map<String, dynamic>> Function() send,
  ) async {
    final previous = _douyinRequestTails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _douyinRequestTails[key] = tail;
    try {
      await previous;
      if (_cancelledRequests.contains(requestId))
        throw const FormatException('请求已取消');
      final now = DateTime.now();
      final cooldown = _douyinCooldownUntil[key];
      if (cooldown != null && cooldown.isAfter(now)) {
        throw const FormatException('抖音接口请求较频繁，请稍后再试');
      }
      if (cooldown != null) _douyinCooldownUntil.remove(key);
      final nextRequestAt = _douyinNextRequestAt[key];
      if (nextRequestAt != null && nextRequestAt.isAfter(now)) {
        final delay = nextRequestAt.difference(now);
        if (now.add(delay).isAfter(deadline))
          throw const FormatException('抖音请求排队超时，请稍后重试');
        await Future<void>.delayed(delay);
      }
      if (_cancelledRequests.contains(requestId))
        throw const FormatException('请求已取消');
      if (DateTime.now().isAfter(deadline))
        throw const FormatException('抖音请求排队超时，请稍后重试');
      _douyinNextRequestAt[key] = DateTime.now().add(
        const Duration(milliseconds: 850),
      );
      final response = await send();
      final status = response['status'];
      final statusCode = status is num
          ? status.toInt()
          : int.tryParse('$status') ?? 0;
      if (statusCode == 403 || statusCode == 418 || statusCode == 429) {
        final retryAfter = response['retryAfter'] as String?;
        final retrySeconds = int.tryParse(retryAfter ?? '');
        var cooldown = retrySeconds != null && retrySeconds > 0
            ? Duration(seconds: retrySeconds.clamp(1, 1800).toInt())
            : const Duration(minutes: 1);
        if (retrySeconds == null && retryAfter != null) {
          try {
            final remaining = HttpDate.parse(
              retryAfter,
            ).difference(DateTime.now());
            if (!remaining.isNegative && remaining > Duration.zero) {
              cooldown = remaining > const Duration(minutes: 30)
                  ? const Duration(minutes: 30)
                  : remaining;
            }
          } catch (_) {}
        }
        final pauseUntil = DateTime.now().add(cooldown);
        _douyinCooldownUntil[key] = pauseUntil;
        _douyinNextRequestAt[key] = pauseUntil;
        final seconds = cooldown.inSeconds;
        throw FormatException('抖音接口拒绝或限制了请求，已暂停相关请求约 $seconds 秒，请稍后手动重试');
      }
      return response;
    } finally {
      release.complete();
      if (identical(_douyinRequestTails[key], tail)) {
        _douyinRequestTails.remove(key);
      }
    }
  }

  CatalogPage cached(String source, String category) =>
      _pages[_cacheKey(source, category)] ??
      CatalogPage([], hasMore: true, page: 1);
  Future<File> _cacheFile(String key) async => File(
    path.join(
      (await getApplicationSupportDirectory()).path,
      'source-subscriptions',
      'catalog-${sha256.convert(utf8.encode(key))}.json',
    ),
  );
  Future<CatalogPage> loadCached(String source, String category) async {
    final key = _cacheKey(source, category);
    if (_pages.containsKey(key)) return _pages[key]!;
    return _cacheLoads[key] ??=
        (() async {
          try {
            final file = await _cacheFile(key), filePath = file.path;

            final package = SourceSubscriptions.instance.package(source);
            final legacyPath = path.join(
              path.dirname(path.dirname(filePath)),
              'catalogs.json',
            );
            final allowLegacy =
                package != null &&
                package.credentialDomains.isEmpty &&
                package.document['credentialRequired'] != true;
            final previous = _legacyTail;
            final read = previous.then(
              (_) => _readCatalogCache(
                filePath,
                legacyPath,
                allowLegacy,
                source,
                category,
              ),
            );
            _legacyTail = read.then<void>(
              (_) {},
              onError: (Object _, StackTrace __) {},
            );

            final (data, parsed) = await read;

            if (data.isNotEmpty && key == _cacheKey(source, category)) {
              _pages[key] = parsed;
              _pageMeta[key] = Map<String, dynamic>.from(data)..remove('items');
              if (data['migrated'] == true) unawaited(_persist(key, data));
            }
          } catch (_) {}
          return cached(source, category);
        })().whenComplete(() {
          _cacheLoads.remove(key);
        });
  }

  Future<bool> _persist(String key, Map<String, dynamic> data) async {
    final previous = _cacheWrites[key] ?? Future<void>.value();
    final write = previous.catchError((Object _) {}).then((_) async {
      final file = await _cacheFile(key), filePath = file.path;

      final text = await _encodeCache(data);
      if (utf8.encode(text).length > 16 * 1024 * 1024)
        throw const FormatException('目录缓存超过大小限制');
      final temporary = File('$filePath.pending');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(filePath);
    });
    _cacheWrites[key] = write;
    try {
      await write;
      _pageMeta.putIfAbsent(key, () => {})['storageError'] = '';
      return true;
    } catch (_) {
      _pageMeta.putIfAbsent(key, () => {})['storageError'] =
          '目录未能保存，本次内容仍可浏览，请检查应用存储';
      return false;
    } finally {
      if (identical(_cacheWrites[key], write)) _cacheWrites.remove(key);
    }
  }

  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String category = '',
    String query = '',
    bool force = false,
  }) async {
    final key = _cacheKey(source, category);
    final result = await execute(source, query.isEmpty ? 'catalog' : 'search', {
      'page': page,
      'category': category,
      'query': query,
      'force': force,
    });
    final parsed = CatalogPage.fromJson({...result, 'page': page});
    if (query.isEmpty) {
      final items = (page > 1 || _pageMeta[key]?['migrated'] == true) && !force
          ? {
              ...{
                for (final item in cached(source, category).items)
                  item.id: item,
              },
              ...{for (final item in parsed.items) item.id: item},
            }.values.toList()
          : parsed.items;
      _pages[key] = CatalogPage(
        items.length > 5000 ? items.sublist(items.length - 5000) : items,
        hasMore: parsed.hasMore,
        page: page,
        warning: items.length > 5000
            ? '目录较大，本地只保留最近5000条；观看和下载记录不受影响'
            : parsed.warning,
        fresh: parsed.fresh,
      );
      _pageMeta[key] = {
        'page': page,
        'totalPages': result['totalPages'] ?? 0,
        'hasMore': parsed.hasMore,
        'storageError': '',
        'updatedAt': DateTime.now().toIso8601String(),
      };
      unawaited(
        _persist(key, {
          ..._pageMeta[key]!,
          'items': _pages[key]!.items.map((item) => item.toJson()).toList(),
        }),
      );
      while (_pages.length > 12) {
        _pages.remove(_pages.keys.first);
      }
    }
    return parsed;
  }

  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final key = _identity(source);
    final cached = _categoryCache[key];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) <
            const Duration(minutes: 5)) {
      return cached.items;
    }
    final active = _categoryLoads[key];
    if (active != null) return active;
    final request = () async {
      final result = await execute(source, 'categories', {});
      final items = List<CatalogCategory>.unmodifiable([
        for (final row in result['items'] as List? ?? [])
          CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
      ]);
      _categoryCache[key] = (fetchedAt: DateTime.now(), items: items);
      return items;
    }();
    _categoryLoads[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_categoryLoads[key], request)) _categoryLoads.remove(key);
    }
  }

  SourceStatus status(String source) {
    final key = _cacheKey(source, ''), prefix = '${_identity(source)}:';
    final ids = {
      for (final row in _pages.entries.where(
        (row) => row.key.startsWith(prefix),
      ))
        for (final item in row.value.items) item.id,
    };
    return SourceStatus.fromJson({
      'source': source,
      'count': ids.length,
      'page': cached(source, '').page,
      'hasMore': cached(source, '').hasMore,
      ...?_pageMeta[key],
      ...?_jobs[_identity(source)],
    });
  }

  SourceStatus startJob(String source, String operation) {
    final identity = _identity(source);
    if (_jobs[identity]?['running'] == true) return status(source);
    final generation = _generation[identity] ?? 0;
    final epoch = store()?.profileEpoch;
    final job = <String, dynamic>{
      'running': true,
      'operation': operation,
      'stage': operation == 'check' ? '正在检测连接' : '正在同步内容',
      'startedAt': DateTime.now().toIso8601String(),
    };
    _jobs[identity] = job;
    unawaited(() async {
      try {
        await loadCached(source, '');
        final initialCount = status(source).count;
        if (operation == 'retrySave') {
          final key = _cacheKey(source, '');
          final saved = await _persist(key, {
            ...?_pageMeta[key],
            'items': cached(
              source,
              '',
            ).items.map((item) => item.toJson()).toList(),
          });
          if (!saved) throw const FormatException('目录仍未保存');
          job['stage'] = '已保存';
          return;
        }
        if (operation == 'metadata' || operation == 'vipMetadata') {
          final entries = cached(source, '').items.take(20).toList();
          job['total'] = entries.length;
          for (final drama in entries) {
            if ((_generation[identity] ?? 0) != generation) return;
            final data = await execute(source, 'detail', {
              'drama': drama.toJson(),
            });
            final fresh = Drama.fromJson(
              Map<String, dynamic>.from(data['drama'] as Map),
            );
            final key = _cacheKey(source, '');
            final current = cached(source, '');
            _pages[key] = CatalogPage(
              current.items
                  .map((row) => row.id == fresh.id ? row.merge(fresh) : row)
                  .toList(),
              hasMore: current.hasMore,
              page: current.page,
            );
            job['completed'] = (job['completed'] as int? ?? 0) + 1;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          final key = _cacheKey(source, '');
          await _persist(key, {
            ...?_pageMeta[key],
            'items': cached(
              source,
              '',
            ).items.map((item) => item.toJson()).toList(),
          });
          if ((_pageMeta[key]?['storageError'] as String? ?? '').isNotEmpty) {
            throw const FormatException('资料已读取但目录未保存');
          }
          job['stage'] = '本次已补齐最多20部资料';
          return;
        }
        if (operation == 'check' || operation == 'checkCatalog') {
          final data = await execute(source, 'catalog', {
            'page': 1,
            'category': '',
          });
          final sample = CatalogPage.fromJson(data).items.firstOrNull;
          if (sample == null) throw const FormatException('没有可检测条目');
          final steps = <Map<String, dynamic>>[
            {'name': '目录', 'state': 'ok', 'message': '目录返回正常'},
          ];
          if (operation == 'check') {
            final detail = DramaDetail.fromJson(
              await execute(source, 'detail', {'drama': sample.toJson()}),
            );
            if (detail.episodes.isEmpty) throw const FormatException('未返回分集');
            final media = await execute(source, 'resolve', {
              'drama': detail.drama.toJson(),
              'chapter': detail.episodes.first.raw,
            });
            if (media['url'] is! String || (media['url'] as String).isEmpty)
              throw const FormatException('未返回媒体地址');
            steps.add({
              'name': '播放解析',
              'state': 'ok',
              'message': '取得媒体地址，尚未实际播放',
            });
          }
          job['health'] = {
            'checkedAt': DateTime.now().toIso8601String(),
            'state': operation == 'check' ? 'resolved' : 'catalogOnly',
            'sample': sample.title,
            'steps': steps,
          };
          job['stage'] = '已完成';
          return;
        }
        var page =
            (operation == 'more' || operation == 'allPages') &&
                cached(source, '').items.isNotEmpty
            ? (_pageMeta[_cacheKey(source, '')]?['migrated'] == true
                  ? 1
                  : cached(source, '').page + 1)
            : 1;
        final end = DateTime.now().add(const Duration(minutes: 10));
        do {
          if ((_generation[identity] ?? 0) != generation ||
              epoch != store()?.profileEpoch)
            return;
          await catalog(source, page: page);
          job['completed'] = page;
          job['stage'] = '已完成';
          job['added'] = (status(source).count - initialCount).clamp(0, 100000);
          if (operation != 'allPages' ||
              !cached(source, '').hasMore ||
              page >= 100 ||
              cached(source, '').items.length >= 5000 ||
              DateTime.now().isAfter(end)) {
            if (operation == 'allPages' && cached(source, '').hasMore) {
              job['stage'] = cached(source, '').items.length >= 5000
                  ? '已达到5000条缓存上限，可手动继续加载下一页'
                  : '本批加载已结束，剩余页可继续加载';
            }
            break;
          }
          page++;
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        } while (true);
      } catch (_) {
        if ((_generation[identity] ?? 0) == generation) {
          job['error'] = '站源请求失败，请检查网络或更新站源';
          job['stage'] = '未完成';
          if (operation == 'check' || operation == 'checkCatalog') {
            job['health'] = {
              'checkedAt': DateTime.now().toIso8601String(),
              'state': 'failed',
              'steps': [
                {'name': '检测', 'state': 'failed', 'message': '请求失败，请检查网络或更新站源'},
              ],
            };
          }
        }
      } finally {
        if (identical(_jobs[identity], job)) {
          job['running'] = false;
          job['finishedAt'] = DateTime.now().toIso8601String();
        }
      }
    }());
    return status(source);
  }

  void cancel(String? source, {Set<String>? actions}) {
    final identities = source == null
        ? {..._active.values, ..._tailScopes.values, ..._jobs.keys}
        : {_identity(source)};
    for (final identity in identities) {
      if (actions == null)
        _generation[identity] = (_generation[identity] ?? 0) + 1;
      if (actions != null)
        for (final action in actions) {
          _actionGeneration['$identity:$action'] =
              (_actionGeneration['$identity:$action'] ?? 0) + 1;
        }
      final job = _jobs[identity];
      if (job != null && actions == null) {
        job['running'] = false;
        job['stage'] = '已停止';
      }
      for (final entry
          in _active.entries
              .where(
                (row) =>
                    row.value == identity &&
                    (actions == null ||
                        actions.contains(_activeActions[row.key])),
              )
              .toList()) {
        _cancelledRequests.add(entry.key);
        for (final client in _clients.remove(entry.key) ?? <HttpClient>{}) {
          client.close(force: true);
        }
        final read = _httpReads[entry.key];
        if (read != null) {
          final cancellation = {'action': 'cancelRead', ...read};
          unawaited(
            _runSourceRaw(
              jsonEncode(cancellation),
              'DuanjuRequest',
            ).catchError((Object _) => ''),
          );
        }
        final body = jsonEncode({'command': 'cancel', 'id': entry.key});
        unawaited(_runSourceRaw(body).catchError((Object _) => ''));
      }
    }
  }
}
