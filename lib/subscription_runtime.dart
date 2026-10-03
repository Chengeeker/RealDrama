import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;

import 'local_store.dart';
import 'models.dart';
import 'source_subscriptions.dart';
import 'source_status.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Request = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
String _sourceStep(String input) {
  final library = Platform.isAndroid ? DynamicLibrary.open('libduanju_core.so') : Platform.isWindows ? DynamicLibrary.open(path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll')) : DynamicLibrary.process();
  final request = library.lookupFunction<_NativeRequest,_Request>('RealDramaSourceRequest');
  final free = library.lookupFunction<_NativeFree,_Free>('DuanjuFree');
  final argument = input.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try { output = request(argument); if (output == nullptr) throw const FormatException('站源运行环境不可用'); return output.toDartString(); }
  finally { malloc.free(argument); if (output != nullptr) free(output); }
}

class SubscriptionRuntime {
  SubscriptionRuntime(this.store);
  final LocalStore? Function() store;
  final _states = <String, Map<String,dynamic>>{};
  final _pages = <String, CatalogPage>{};
  final _jobs = <String, Map<String,dynamic>>{};
  final _clients = <String, Set<HttpClient>>{};
  final _generation = <String,int>{};
  final _active = <String,String>{};
  final _tails = <String,Future<void>>{};
  int _serial = 0;
  String _identity(String source) => '${store()?.profile.id}:$source';
  void _authorize(String source, int? epoch, String digest) {
    final access = store();
    if (access == null || access.locked || access.profileEpoch != epoch || !access.allowsSource(source) || SourceSubscriptions.instance.package(source)?.digest != digest) throw const FormatException('站源已关闭、更新或用户已切换');
  }
  Future<Map<String,dynamic>> execute(String source, String action, Map<String,dynamic> payload, {bool configure = false}) {
    final scope = _identity(source);
    final previous = _tails[scope] ?? Future.value();
    final epoch = store()?.profileEpoch;
    final package = SourceSubscriptions.instance.package(source);
    if (package == null) return Future.error(const FormatException('请先导入此站源的订阅包'));
    final generation = _generation[scope] ?? 0;
    final result = previous.then((_) {
      if (store()?.profileEpoch != epoch || generation != (_generation[scope] ?? 0)) throw const FormatException('请求已取消');
      return _execute(package, action, payload, configure: configure);
    });
    final tail = result.then<void>((_) {}, onError: (Object _,StackTrace __) {});
    _tails[scope] = tail;
    unawaited(tail.then((_) { if (identical(_tails[scope], tail)) _tails.remove(scope); }));
    return result;
  }
  Future<Map<String,dynamic>> _execute(SourcePackage package, String action, Map<String,dynamic> payload, {bool configure = false}) async {
    final access = store();
    if (access == null || access.locked) throw const FormatException('请先解锁应用');
    final epoch = access.profileEpoch;
    final source = package.id, identity = _identity(package.id);
    if (!configure) _authorize(source, epoch, package.digest);
    final generation = _generation[identity] ?? 0;
    final id = '${DateTime.now().microsecondsSinceEpoch}:${++_serial}';
    _active[id] = identity;
    final stateKey = '$identity:${package.digest}:$action:${payload['category'] ?? ''}';
    var request = <String,dynamic>{'command': 'start','id': id,'program': package.program, 'action':action, 'payload': {...payload,'source':source}, 'state':_states[stateKey] ?? <String,dynamic>{}};
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      for (var step = 0; step < 16; step++) {
        if (DateTime.now().isAfter(deadline) || generation != (_generation[identity] ?? 0)) throw const FormatException('站源请求超时或已取消');
        if (!configure) _authorize(source, epoch, package.digest);
        final input = jsonEncode(request);
        final envelope = await Isolate.run(() => jsonDecode(_sourceStep(input)) as Map<String,dynamic>);
        if (envelope['ok'] != true) throw FormatException(envelope['error'] as String? ?? '站源执行失败');
        final data = Map<String,dynamic>.from(envelope['data'] as Map);
        if (data['done'] == true) {
          if (!configure) _authorize(source, epoch, package.digest);
          if (epoch != store()?.profileEpoch || generation != (_generation[identity] ?? 0)) throw const FormatException('请求已取消');
          final value = Map<String,dynamic>.from(data['value'] as Map? ?? {});
          if (value['state'] is Map) {
            _states[stateKey] = Map<String,dynamic>.from(value.remove('state') as Map);
            while (_states.length > 64) { _states.remove(_states.keys.first); }
          }
          if (value['error'] is String) throw FormatException(value['error'] as String);
          return value;
        }
        final command = Map<String,dynamic>.from(data['value'] as Map);
        Object response;
        if (command['type'] == 'sign') {
          if (!Platform.isAndroid || package.credentialGroup != 'douyin') throw const FormatException('此签名能力当前仅支持 Android 抖音订阅');
          response = await const MethodChannel('realdrama/douyin').invokeMethod<String>('sign', {'query':command['query'] as String, 'userAgent':command['userAgent'] as String}).timeout(const Duration(seconds: 6)) ?? '';
        } else if (command['type'] == 'http') {
          response = await _http(package, command, id, access.profile.id, deadline);
        } else { throw const FormatException('站源请求了不支持的运行能力'); }
        request = {'command':'next','id':id,'response':response};
      }
      throw const FormatException('站源单次请求次数过多');
    } finally {
      _active.remove(id);
      for (final client in _clients.remove(id) ?? <HttpClient>{}) { client.close(force:true); }
      final body = jsonEncode({'command':'cancel','id':id});
      try { await Isolate.run(() => _sourceStep(body)); } catch (_) {}
    }
  }
  Future<Map<String,dynamic>> _http(SourcePackage package, Map<String,dynamic> command, String id, String profile, DateTime deadline) async {
    final uri = Uri.parse(command['url'] as String);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443 || !package.domains.contains(uri.host)) throw const FormatException('站源请求超出声明域名');
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw const FormatException('站源请求超时');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    (_clients[id] ??= <HttpClient>{}).add(client);
    try {
      final addresses = await InternetAddress.lookup(uri.host).timeout(const Duration(seconds: 6));
      if (addresses.isEmpty || addresses.any(SourceSubscriptions.privateAddress)) throw const FormatException('站源不能访问本机或内网地址');
      final method = command['method'] as String? ?? 'GET';
      if (method != 'GET' && method != 'POST') throw const FormatException('站源请求方法不受支持');
      final request = await client.openUrl(method,uri).timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      for (final entry in (command['headers'] as Map? ?? {}).entries) {
        if (!{'user-agent','accept','referer','origin','content-type','x-gorgon','x-khronos','x-ss-req-ticket','x-ss-stub','sdk-version','x-xs-from-web'}.contains('${entry.key}'.toLowerCase())) throw const FormatException('站源请求头不受支持');
        request.headers.set('${entry.key}','${entry.value}');
      }
      if (command['credential'] == true) {
        if (!package.credentialDomains.contains(uri.host)) throw const FormatException('禁止向此域名发送凭据');
        final group = package.credentialGroup;
        final key = group == 'douyin' ? 'douyin.cookie.$profile' : group == 'bilibili' ? 'bilibili.cookie.$profile' : 'source.cookie.$group.$profile';
        final cookie = await const FlutterSecureStorage().read(key:key);
        if (cookie != null && cookie.isNotEmpty) request.headers.set(HttpHeaders.cookieHeader,cookie);
        else if (package.document['credentialRequired'] == true) throw const FormatException('请在站源管理中配置账号 Cookie');
      }
      final body = command['body'];
      if (body != null) {
        final text = body is String ? body : jsonEncode(body);
        if (utf8.encode(text).length > 1024 * 1024) throw const FormatException('请求数据过大');
        request.write(text);
      }
      final response = await request.close().timeout(remaining < const Duration(seconds:15) ? remaining : const Duration(seconds:15));
      final bytes = BytesBuilder(copy:false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.add(chunk);
        if (bytes.length > 8 * 1024 * 1024 || DateTime.now().isAfter(deadline)) throw const FormatException('站源响应过大或超时');
      }
      if (response.statusCode != 200) throw FormatException('站源请求失败（HTTP ${response.statusCode}）');
      final text = utf8.decode(bytes.takeBytes(),allowMalformed:true);
      return {'status':response.statusCode,'text':text};
    } finally { client.close(force:true); _clients[id]?.remove(client); }
  }
  CatalogPage cached(String source, String category) => _pages['${_identity(source)}:$category'] ?? CatalogPage([]);
  Future<CatalogPage> catalog(String source, {int page=1,String category='',String query='',bool force=false}) async {
    final key = '${_identity(source)}:$category';
    final result = await execute(source,'catalog',{'page':page,'category':category,'query':query,'force':force});
    final parsed = CatalogPage.fromJson({...result,'page':page});
    if (query.isEmpty) {
      final items = page > 1 && !force ? {...{for(final item in cached(source,category).items) item.id:item},...{for(final item in parsed.items) item.id:item}}.values.toList() : parsed.items;
      _pages[key] = CatalogPage(items.take(600).toList(),hasMore:parsed.hasMore,page:page,warning:parsed.warning);
      while (_pages.length > 12) { _pages.remove(_pages.keys.first); }
    }
    return parsed;
  }
  Future<List<CatalogCategory>> categories(String source) async {
    final result = await execute(source,'categories',{});
    return [for (final row in result['items'] as List? ?? []) CatalogCategory.fromJson(Map<String,dynamic>.from(row as Map))];
  }
  SourceStatus status(String source) => SourceStatus.fromJson({'source':source,'count':_pages.entries.where((row)=>row.key.startsWith('${_identity(source)}:')).fold<int>(0,(sum,row)=>sum+row.value.items.length),'page':cached(source,'').page,'hasMore':cached(source,'').hasMore,...?_jobs[_identity(source)]});
  SourceStatus startJob(String source,String operation) {
    final identity = _identity(source);
    if (_jobs[identity]?['running'] == true) return status(source);
    final generation = _generation[identity] ?? 0;
    final epoch = store()?.profileEpoch;
    final job = <String,dynamic>{'running':true,'operation':operation,'stage':operation=='check'?'正在检测连接':'正在同步内容'};
    _jobs[identity]=job;
    unawaited(() async {
      try {
        var page = operation == 'more' || operation == 'all' ? cached(source,'').page + 1 : 1;
        final end = DateTime.now().add(const Duration(minutes:10));
        do {
          if ((_generation[identity] ?? 0)!=generation || epoch != store()?.profileEpoch) return;
          final result = operation == 'check' ? await execute(source,'check',{}) : (await catalog(source,page:page)).items;
          job['completed']=page; job['stage']='已完成';
          if (operation!='all' || !cached(source,'').hasMore || page>=100 || DateTime.now().isAfter(end)) break;
          page++;
          await Future<void>.delayed(const Duration(milliseconds:1200));
        } while (true);
      } catch (_) { if ((_generation[identity] ?? 0)==generation) { job['error']='站源请求失败，请检查网络或更新站源';job['stage']='未完成'; } }
      finally { if (identical(_jobs[identity],job)) { job['running']=false; } }
    }());
    return status(source);
  }
  void cancel(String? source) {
    final identities = source == null ? {..._active.values,..._tails.keys,..._jobs.keys} : {_identity(source)};
    for (final identity in identities) {
      _generation[identity]=(_generation[identity] ?? 0)+1;
      final job=_jobs[identity]; if(job!=null){job['running']=false;job['stage']='已停止';}
      for(final entry in _active.entries.where((row)=>row.value==identity).toList()) {
        for(final client in _clients.remove(entry.key)??<HttpClient>{}){client.close(force:true);}
        final body=jsonEncode({'command':'cancel','id':entry.key});unawaited(Isolate.run(()=>_sourceStep(body)).catchError((Object _)=>''));
      }
    }
  }
}
