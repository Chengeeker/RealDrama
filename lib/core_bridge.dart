import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'subscription_runtime.dart';
import 'source_subscriptions.dart';
import 'bilibili_source.dart';
import 'douyin_source.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'app_build.dart';
import 'source_status.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libduanju_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
    );
  } else if (Platform.isIOS) {
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前首版支持 Android 手机和 Windows 电脑');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  void resetDouyin() {}
  Future<Map<String, dynamic>> bilibiliAccount() async =>
      throw AppFailure('当前环境不支持哔哩哔哩');
  Future<int> checkDouyin() async => throw AppFailure('当前环境不支持抖音');
  Future<int> checkDouyinLive() async => throw AppFailure('当前环境不支持抖音直播');
  Future<DouyinCreatorPage> douyinCreatorVideos(
    Drama drama, {
    String cursor = '0',
  }) async => throw AppFailure('当前环境不支持抖音主页');
  Future<DouyinCreatorPage> creatorVideos(Drama drama, {String cursor = '0'}) =>
      douyinCreatorVideos(drama, cursor: cursor);
  Future<DouyinCommentPage> douyinComments(
    Drama drama, {
    required String requestScope,
    String cursor = '0',
  }) async => throw AppFailure('当前环境不支持抖音评论');
  void cancelDouyinComments(String requestScope) {}
  Future<DouyinCommentPage> videoComments(
    Drama drama, {
    required String requestScope,
    String cursor = '0',
  }) => douyinComments(drama, requestScope: requestScope, cursor: cursor);
  void cancelVideoComments(String requestScope) =>
      cancelDouyinComments(requestScope);

  Future<DouyinLiveRoom> douyinLiveRoom(Drama drama) async =>
      throw AppFailure('当前环境不支持抖音直播');
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  Future<void> cancelHandoff() async {}
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload({String? requestKey}) async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    String? requestKey,
  }) async => null;
  Future<void> cancelCatalog() async {}
  Future<void> cancelCategories() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  Future<DramaDetail> detail(Drama drama);
  Future<DramaDetail> refreshDetail(Drama drama) => detail(drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  NativeRepository({this.background = false});
  final bool background;
  late final _subscriptions = SubscriptionRuntime(() => access);
  @override void resetDouyin() => _subscriptions.cancel(null);
  @override Future<int> checkDouyin() async => intValue((await _subscriptions.execute('douyin','check',{},configure:true))['count']);
  @override Future<int> checkDouyinLive() async => intValue((await _subscriptions.execute('douyin-live','check',{},configure:true))['count']);
  @override Future<Map<String,dynamic>> bilibiliAccount() => _subscriptions.execute('bilibili','account',{},configure:true);
  @override Future<DouyinCreatorPage> creatorVideos(Drama drama,{String cursor='0'}) async {
    final data = await _subscriptions.execute(drama.source,'creator',{'drama':drama.toJson(),'cursor':cursor});
    return DouyinCreatorPage(name:data['name'] as String? ?? drama.creatorName,avatar:data['avatar'] as String? ?? drama.creatorAvatar,items:CatalogPage.fromJson(data).items,cursor:'${data['cursor'] ?? '0'}',hasMore:data['hasMore']==true,userId:'${data['userId'] ?? drama.creatorId}',bio:data['bio'] as String? ?? '',likes:data['likes'] is num?intValue(data['likes']):null,following:data['following'] is num?intValue(data['following']):null,followers:data['followers'] is num?intValue(data['followers']):null);
  }
  @override Future<DouyinCreatorPage> douyinCreatorVideos(Drama drama,{String cursor='0'}) => creatorVideos(drama,cursor:cursor);
  @override Future<DouyinCommentPage> videoComments(Drama drama,{required String requestScope,String cursor='0'}) async {
    final data=await _subscriptions.execute(drama.source,'comments',{'drama':drama.toJson(),'cursor':cursor});
    return DouyinCommentPage(items:[for(final row in data['items'] as List? ?? const []) DouyinComment(id:'${row['id']}',author:'${row['author'] ?? ''}',avatar:'${row['avatar'] ?? ''}',text:'${row['text'] ?? ''}',likes:intValue(row['likes']))],cursor:'${data['cursor'] ?? '0'}',hasMore:data['hasMore']==true,total:intValue(data['total']));
  }
  @override Future<DouyinCommentPage> douyinComments(Drama drama,{required String requestScope,String cursor='0'}) => videoComments(drama,requestScope:requestScope,cursor:cursor);
  @override void cancelVideoComments(String requestScope) => _subscriptions.cancel(null,actions:{'comments'});
  @override void cancelDouyinComments(String requestScope) => cancelVideoComments(requestScope);
  @override Future<DouyinLiveRoom> douyinLiveRoom(Drama drama) async {
    final data=await _subscriptions.execute(drama.source,'live',{'drama':drama.toJson()});
    return DouyinLiveRoom(drama:data['drama'] is Map?Drama.fromJson(Map<String,dynamic>.from(data['drama'] as Map)):drama,plan:PlaybackPlan.fromJson(Map<String,dynamic>.from(data['plan'] as Map)));
  }
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => _call({'action': 'lan', 'command': command, 'lan': payload});

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    if (SourceSite.byId(drama.source).isDouyin) {
      throw AppFailure('抖音站源不支持设备互联');
    }
    final data = await _read('handoff', {
      'action': 'prepareHandoff',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': access != null && !access!.canDownload,
    });
    return PlaybackPlan.fromJson(data);
  }

  @override
  Future<void> cancelHandoff() => _cancelReads('handoff');

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelPreload({String? requestKey}) async {
    if (requestKey == null) {
      await _cancelReads('preload');
      return;
    }
    final sequence = _activeReads[requestKey];
    if (sequence == null) return;
    try {
      await _call({
        'action': 'cancelRead',
        'session': '$_readOwner:$requestKey',
        'sequence': sequence,
      });
    } catch (_) {}
  }

  @override Future<PlaybackPlan?> preload(Drama drama,Episode episode,{int quality=0,bool online=false,String? requestKey}) => resolve(drama,episode,quality:quality);
  @override Future<void> cancelCatalog() async => _subscriptions.cancel(null,actions:{'catalog'});
  @override Future<void> cancelCategories() async => _subscriptions.cancel(null,actions:{'categories'});
  @override Future<void> cancelSuggestions() async => _subscriptions.cancel(null,actions:{'suggestions'});
  @override Future<void> cancelRecommendations() async => _subscriptions.cancel(null,actions:{'recommendations'});

  @override Future<CatalogPage> recommendations(String genre,{bool more=false,bool force=false}) => _subscriptions.catalog('hongguo',category:genre,page:more?_subscriptions.cached('hongguo',genre).page+1:1,force:force);

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  final _sourceStatusReads = <String, Future<SourceStatus>>{};
  final _sourceStatusCache = <String, (DateTime, int?, SourceStatus)>{};

  Future<SourceStatus> _readSourceStatus(String source) async {
    final epoch = access?.profileEpoch;
    final response = await _call({'action': 'sourceStatus', 'source': source});
    final status = SourceStatus.fromJson(response);
    if (epoch == access?.profileEpoch) {
      _sourceStatusCache[source] = (DateTime.now(), epoch, status);
    }
    return status;
  }

  @override Future<SourceStatus> sourceStatus(String source) async { _authorize(source); return _subscriptions.status(source); }
  @override Future<SourceStatus> startSourceJob(String source,String operation,{Drama? drama}) async { _authorize(source);return _subscriptions.startJob(source,operation); }
  @override Future<SourceStatus> cancelSourceJob(String source) async { _subscriptions.cancel(source); return _subscriptions.status(source); }

  void _authorize(String source, {bool download = false}) {
    if (!SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
    }
  }

  @override
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    final sourceAction=input['action'];
    if({'rankingBoards'}.contains(sourceAction)) {
      final packages=SourceSubscriptions.instance.installed.where((item)=>item.capabilities.contains('rankings'));
      final rows=<dynamic>[];
      for(final item in packages){if(access?.allowsSource(item.id)==true){rows.addAll((await _subscriptions.execute(item.id,'rankingBoards',{}))['items'] as List? ?? []);}}
      return {'items':rows};
    }
    if({'metadata','rankings','recommendations','cachedRecommendations','suggestions','bilibiliAccount','bilibiliCreator','bilibiliComments'}.contains(sourceAction)) {
      final source=input['source'] as String? ?? (input['drama'] as Map?)?['source'] as String? ?? 'hongguo';
      return _subscriptions.execute(source,sourceAction as String,input);
    }

    try {
      final action = input['action'] as String;
      if (action == 'sourceJob' || action == 'cancelSourceJob') {
        _sourceStatusCache.remove(input['source']);
      }
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions') {
        _authorize('hongguo');
      }
      if ({
        'catalog',
        'cached',
        'categories',
        'sourceStatus',
        'sourceJob',
        'cancelSourceJob',
        'bilibiliAccount',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'prepareHandoff',
        'enqueueDownloads',
        'localPlayback',
        'bilibiliCreator',
        'bilibiliComments',
      }.contains(action)) {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final source =
          input['source'] as String? ??
          ((input['drama'] as Map?)?['source'] as String? ?? '');
      if (source == SourceSite.bilibili.id &&
          {
            'bilibiliAccount',
            'bilibiliCreator',
            'bilibiliComments',
            'catalog',
            'categories',
            'sourceJob',
            'detail',
            'metadata',
            'resolve',
            'preload',
            'prepareHandoff',
          }.contains(action)) {
        final profile = access?.profile.id;
        input['cookie'] = profile == null
            ? ''
            : await BilibiliSource.readCookie(profile) ?? '';
      }
      final body = jsonEncode(input);
      final response =
          await Isolate.run(
            () => jsonDecode(_nativeRequest(body)) as Map<String, dynamic>,
          ).timeout(
            Duration(
              seconds: action == 'moveDownloads'
                  ? 620
                  : action == 'preload'
                  ? 20
                  : 70,
            ),
          );
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'preload',
            'prepareHandoff',
            'bilibiliComments',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw AppFailure('站源响应超时，请重试');
    } catch (_) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
    });
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
    }
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override Future<List<CatalogCategory>> categories(String source,{bool force=false}) => _subscriptions.categories(source);
  @override Future<CatalogPage> catalog(String source,{int page=1,String query='',String category='',bool force=false}) => _subscriptions.catalog(source,page:page,query:query,category:category,force:force);
  @override Future<CatalogPage> cached(String source,{String category=''}) async => _subscriptions.cached(source,category);

  @override Future<String> cover(Drama drama,{bool force=false}) async { _authorize(drama.source);if(drama.cover.isEmpty)throw AppFailure('海报暂不可用');return drama.cover; }
  @override Future<DramaDetail> detail(Drama drama) async => DramaDetail.fromJson(await _subscriptions.execute(drama.source,'detail',{'drama':drama.toJson()}));
  @override Future<DramaDetail> refreshDetail(Drama drama) async => DramaDetail.fromJson(await _subscriptions.execute(drama.source,'detail',{'drama':drama.toJson(),'force':true}));
  @override Future<PlaybackPlan> resolve(Drama drama,Episode episode,{int quality=0}) async => PlaybackPlan.fromJson(await _subscriptions.execute(drama.source,'resolve',{'drama':drama.toJson(),'chapter':episode.raw,'index':episode.number,'quality':quality}));

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<Map<String, dynamic>> bilibiliAccount() =>
      _call({'action': 'bilibiliAccount', 'source': SourceSite.bilibili.id});

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({'action': 'downloads'});
    return (result['jobs'] as List? ?? [])
        .whereType<Map>()
        .map((value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)))
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    if (!SourceSite.byId(detail.drama.source).supportsDownloads) {
      throw AppFailure('哔哩哔哩站源当前不支持下载');
    }
    if (SourceSite.byId(detail.drama.source).isDouyin) {
      throw AppFailure('抖音站源当前不支持下载');
    }
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    if (!SourceSite.byId(detail.drama.source).supportsDownloads) {
      throw AppFailure('哔哩哔哩站源当前不支持下载');
    }
    if (SourceSite.byId(detail.drama.source).isDouyin) {
      throw AppFailure('抖音站源当前不支持下载');
    }
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
        if (expectedVersions.isNotEmpty) 'expectedVersions': expectedVersions,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    if (SourceSite.byId(drama.source).isDouyin) return null;
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override Future<PlaybackPlan> resolveOnline(Drama drama,Episode episode,{int quality=0}) => resolve(drama,episode,quality:quality);

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}
