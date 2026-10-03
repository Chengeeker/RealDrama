import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'source_status.dart';

Future<Map<String, dynamic>> _decodeDouyinResponse(List<int> bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

Future<Map<String, dynamic>> _decodeLiveCategories(List<int> bytes) =>
    Isolate.run(() {
      var text = utf8.decode(bytes);
      for (var pass = 0; pass < 2; pass++) {
        final marker = RegExp(r'"categoryData"\s*:').firstMatch(text);
        if (marker != null) {
          final start = text.indexOf('[', marker.end);
          if (start >= 0) {
            var depth = 0;
            var quoted = false;
            var escaped = false;
            for (var i = start; i < text.length; i++) {
              final char = text[i];
              if (escaped) {
                escaped = false;
                continue;
              }
              if (char == r'\') {
                escaped = true;
                continue;
              }
              if (char == '"') quoted = !quoted;
              if (quoted) continue;
              if (char == '[') depth++;
              if (char == ']' && --depth == 0) {
                return <String, dynamic>{
                  'categories': jsonDecode(text.substring(start, i + 1)),
                };
              }
            }
          }
        }
        text = text.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      }
      throw const DouyinFailure('官方直播分类未返回，请稍后重试');
    });

Future<Uint8List> _readDouyinBody(
  HttpClientResponse response,
  int limit,
) async {
  final builder = BytesBuilder(copy: false);
  await for (final block in response) {
    if (builder.length + block.length > limit)
      throw const DouyinFailure('响应超过处理上限');
    builder.add(block);
  }
  return builder.takeBytes();
}

bool _douyinHasMore(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = '$value'.trim().toLowerCase();
  if (text == 'true') return true;
  if (text == 'false' || text.isEmpty) return false;
  final parsed = int.tryParse(text);
  return parsed != null && parsed != 0;
}

List? _douyinAwemeRows(Map<String, dynamic> response) {
  final rows = response['aweme_list'];
  if (rows is List) return rows;
  final data = response['data'];
  if (data is Map && data['aweme_list'] is List) {
    return data['aweme_list'] as List;
  }
  if (data is List) {
    final wrapped = <Object?>[];
    for (final entry in data) {
      if (entry is Map && entry['aweme_info'] is Map) {
        wrapped.add(entry['aweme_info']);
      } else if (entry is Map && entry['aweme'] is Map) {
        wrapped.add(entry['aweme']);
      } else if (entry is Map && entry['aweme_id'] != null) {
        wrapped.add(entry);
      }
    }
    if (wrapped.isNotEmpty || data.isEmpty) return wrapped;
  }
  return null;
}

Map _douyinPageMetadata(Map<String, dynamic> response) {
  final data = response['data'];
  return data is Map ? data : response;
}

String _firstDouyinUrl(Object? value) {
  if (value is! Map) return '';
  final urls = value['url_list'];
  if (urls is! List) return '';
  for (final raw in urls) {
    final uri = Uri.tryParse('$raw');
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      return uri.toString();
    }
  }
  return '';
}

class DouyinComment {
  const DouyinComment({
    required this.id,
    required this.author,
    required this.avatar,
    required this.text,
    required this.likes,
  });

  final String id;
  final String author;
  final String avatar;
  final String text;
  final int likes;
}

class DouyinCommentPage {
  const DouyinCommentPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
    required this.total,
  });

  final List<DouyinComment> items;
  final String cursor;
  final bool hasMore;
  final int total;
}

class DouyinCreatorPage {
  const DouyinCreatorPage({
    required this.name,
    required this.avatar,
    required this.items,
    required this.cursor,
    required this.hasMore,
    this.userId = '',
    this.bio = '',
    this.likes,
    this.following,
    this.followers,
  });

  final String name;
  final String avatar;
  final List<Drama> items;
  final String cursor;
  final bool hasMore;
  final String userId;
  final String bio;
  final int? likes;
  final int? following;
  final int? followers;
}

class DouyinLiveRoom {
  const DouyinLiveRoom({required this.drama, required this.plan});

  final Drama drama;
  final PlaybackPlan plan;
}

class DouyinFailure implements Exception {
  const DouyinFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class DouyinSource {
  DouyinSource({this.source = 'douyin'});
  final String source;
  String get defaultFeed => switch (source) {
    'douyin-series' => 'series:recommend',
    'douyin-theater' => 'vs:variety',
    _ => 'recommend',
  };

  static List<CatalogCategory> categoriesFor(String source) => switch (source) {
    'douyin-series' => [
      for (final entry in seriesChannels.entries)
        CatalogCategory(entry.key, entry.value.name.replaceFirst('短剧·', '')),
    ],
    'douyin-theater' => [
      for (final entry in theaterChannels.entries)
        CatalogCategory(entry.key, entry.value.name.replaceFirst('放映厅·', '')),
    ],
    _ => categories,
  };

  static const selectedChannels = <String, ({String name, String tag})>{
    'jingxuan': (name: '精选', tag: ''),
    'course': (name: '公开课', tag: '100000'),
    'film': (name: '影视', tag: '300215'),
    'game': (name: '游戏', tag: '300205'),
    'music': (name: '音乐', tag: '300209'),
    'theater': (name: '小剧场', tag: '300214'),
    'food': (name: '美食', tag: '300204'),
    'beauty': (name: '美妆穿搭', tag: '300222'),
    'vlog': (name: '生活vlog', tag: '300216'),
    'travel': (name: '旅行', tag: '300221'),
    'acg': (name: '二次元', tag: '300206'),
    'knowledge': (name: '知识', tag: '300213'),
    'child': (name: '亲子', tag: '300217'),
    'animal': (name: '动物', tag: '300220'),
    'sports': (name: '体育', tag: '300207'),
    'agriculture': (name: '三农', tag: '300219'),
    'car': (name: '汽车', tag: '300218'),
  };

  static const seriesChannels = <String, ({String name, String contentType})>{
    'series:recommend': (name: '短剧·推荐', contentType: ''),
    'series:rank': (name: '短剧·榜单', contentType: '1'),
    'series:love': (name: '短剧·爱情', contentType: '1940'),
    'series:drama': (name: '短剧·剧情', contentType: '1957'),
    'series:comeback': (name: '短剧·逆袭', contentType: '1944'),
    'series:twist': (name: '短剧·反转', contentType: '2092'),
    'series:family': (name: '短剧·亲情', contentType: '1941'),
    'series:grudge': (name: '短剧·恩怨', contentType: '2091'),
    'series:fantasy': (name: '短剧·玄幻', contentType: '1946'),
    'series:magic': (name: '短剧·奇幻', contentType: '1945'),
    'series:costume': (name: '短剧·古装', contentType: '1958'),
    'series:mystery': (name: '短剧·悬疑', contentType: '1950'),
    'series:friendship': (name: '短剧·友情', contentType: '1942'),
    'series:comedy': (name: '短剧·喜剧', contentType: '1956'),
    'series:crime': (name: '短剧·犯罪', contentType: '2088'),
    'series:thriller': (name: '短剧·惊悚', contentType: '1951'),
    'series:youth': (name: '短剧·青春', contentType: '1943'),
    'series:scifi': (name: '短剧·科幻', contentType: '1947'),
    'series:xianxia': (name: '短剧·仙侠', contentType: '1948'),
    'series:other': (name: '短剧·其他', contentType: '1959'),
  };

  static const theaterChannels =
      <String, ({String name, String albumType, String path})>{
        'vs:variety': (name: '放映厅·综艺', albumType: '4', path: 'vs'),
        'vs:tv': (name: '放映厅·电视剧', albumType: '2', path: 'tv'),
        'vs:movie': (name: '放映厅·电影', albumType: '1', path: 'movie'),
        'vs:documentary': (
          name: '放映厅·纪录片',
          albumType: '5',
          path: 'documentary',
        ),
        'vs:anime': (name: '放映厅·动画', albumType: '3', path: 'anime'),
      };

  bool _supportsFeed(String feed) => switch (source) {
    'douyin-series' => seriesChannels.containsKey(feed),
    'douyin-theater' => theaterChannels.containsKey(feed),
    _ =>
      feed == 'recommend' ||
          feed == 'follow' ||
          selectedChannels.containsKey(feed),
  };

  static List<CatalogCategory> get categories => [
    const CatalogCategory('recommend', '推荐'),
    const CatalogCategory('follow', '关注'),
    for (final entry in selectedChannels.entries)
      CatalogCategory(entry.key, entry.value.name),
  ];

  static const storage = FlutterSecureStorage();
  static const channel = MethodChannel('realdrama/douyin');
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';
  static String cookieKey(String profile) => 'douyin.cookie.$profile';
  static String normalizeCookie(String value) {
    final match = RegExp(
      r'^\s*cookie\s*:\s*(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(value);
    final cookie = (match?.group(1) ?? value).trim();
    if (cookie.isEmpty) return '';
    if (cookie.length > 32768 ||
        cookie.contains('\n') ||
        cookie.contains('\r') ||
        RegExp(r'[^\x20-\x7e]').hasMatch(cookie)) {
      throw const DouyinFailure('请粘贴完整 Cookie 值，不能包含其他请求头');
    }
    final parts = cookie
        .split(';')
        .map((part) => part.trim())
        .where(
          (part) =>
              part.isNotEmpty &&
              !{
                'douyin.com',
                '.douyin.com',
                'www.douyin.com',
              }.contains(part.toLowerCase()),
        )
        .toList();
    if (parts.any((part) => part.indexOf('=') <= 0)) {
      throw const DouyinFailure(
        'Cookie 中有缺少等号的字段。请复制网络请求头中的完整 Cookie 值，不要复制域名、表格或响应的 Set-Cookie。',
      );
    }
    final names = parts.map((part) => part.trim().split('=').first).toSet();
    if (!names.contains('sessionid') && !names.contains('sessionid_ss')) {
      throw const DouyinFailure('未找到登录会话，请复制登录抖音网页后的完整 Cookie');
    }
    return parts.join('; ');
  }

  String? _profile;
  int _generation = 0;
  int _jobGeneration = 0;
  final _clients = <HttpClient>{};
  final _clientsByScope = <String, Set<HttpClient>>{};
  final _scopeGenerations = <String, int>{};
  final _commentScopes = <String>{};
  void cancel({String? scope}) {
    if (scope == null) {
      _generation++;
      _jobGeneration++;
    } else {
      _scopeGenerations[scope] = (_scopeGenerations[scope] ?? 0) + 1;
      if (scope == 'douyin') _jobGeneration++;
    }
    if (scope == null || scope == 'douyin') {
      _catalogPending.clear();
      _catalogTails.clear();
      _catalogRevisions.clear();
    }
    if ((scope == null || scope == 'douyin') && _running) {
      _running = false;
      _stage = '已停止';
      _finished = DateTime.now();
    }
    final closing = scope == null
        ? _clients.toList()
        : (_clientsByScope.remove(scope)?.toList() ?? const <HttpClient>[]);
    for (final client in closing) {
      _clients.remove(client);
      client.close(force: true);
    }
    if (scope == null) {
      _clientsByScope.clear();
    }
  }

  final _rows = <String, Map<String, dynamic>>{};
  final _pages = <String, CatalogPage>{};
  final _followCursors = <int, String>{1: '0'};
  final _selectedOffsets = <int, String>{1: '0'};
  final _selectedSeen = <String, Set<String>>{};
  final _seriesOffsets = <String, Map<int, String>>{};
  final _theaterCursors = <String, Map<int, String>>{};
  final _seriesDetails = <String, DramaDetail>{};
  final _seriesEpisodeRows = <String, Map<String, dynamic>>{};
  final _coursePresented = <String>{};
  final _catalogPending = <String, Future<CatalogPage>>{};
  final _catalogRevisions = <String, int>{};
  final _catalogTails = <String, Future<CatalogPage>>{};
  DateTime? _updated;
  int _nextRefreshIndex = 1;
  String _health = '';
  bool _running = false;
  String _operation = '', _error = '', _stage = '';
  DateTime? _started, _finished;
  SourceStatus startJob(String profile, String operation) {
    _scope(profile);
    if (_running) return status(profile);
    _running = true;
    _operation = operation;
    _error = '';
    _stage = '正在获取推荐';
    _started = DateTime.now();
    _finished = null;
    final generation = _generation;
    final jobGeneration = _jobGeneration;
    final page = operation == 'more'
        ? (_pages['$defaultFeed:${_latestPage(defaultFeed)}']?.hasMore == true
              ? _latestPage(defaultFeed) + 1
              : 1)
        : 1;
    unawaited(() async {
      try {
        await catalog(profile, page: page, force: true);
        if (generation == _generation && jobGeneration == _jobGeneration) {
          _stage = '已完成';
        }
      } catch (error) {
        if (generation == _generation && jobGeneration == _jobGeneration) {
          _error = error is DouyinFailure ? error.message : '抖音请求失败，请检查网络与账号状态';
          _stage = '未完成';
        }
      } finally {
        if (generation == _generation && jobGeneration == _jobGeneration) {
          _running = false;
          _finished = DateTime.now();
        }
      }
    }());
    return status(profile);
  }

  void _trim() {
    while (_rows.length > 240) {
      _rows.remove(_rows.keys.first);
    }
    while (_seriesEpisodeRows.length > 240) {
      _seriesEpisodeRows.remove(_seriesEpisodeRows.keys.first);
    }
    while (_seriesDetails.length > 8) {
      _seriesDetails.remove(_seriesDetails.keys.first);
    }
  }

  void reset() {
    cancel();
    _rows.clear();
    _pages.clear();
    _catalogPending.clear();
    _selectedSeen.clear();
    _seriesOffsets.clear();
    _theaterCursors.clear();
    _seriesDetails.clear();
    _seriesEpisodeRows.clear();
    _coursePresented.clear();
    _selectedOffsets
      ..clear()
      ..[1] = '0';
    _followCursors
      ..clear()
      ..[1] = '0';
    _nextRefreshIndex = 1;
    _updated = null;
    _health = '';
    _operation = _error = _stage = '';
    _started = _finished = null;
  }

  void _scope(String profile) {
    if (_profile == profile) return;
    _profile = profile;
    reset();
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, String> query,
    String profile, {
    String host = 'www.douyin.com',
    String? referer,
    String requestScope = 'douyin',
    bool categoryPage = false,
    bool post = false,
  }) async {
    _scope(profile);
    if (!{'www.douyin.com', 'live.douyin.com'}.contains(host)) {
      throw const DouyinFailure('抖音请求域名无效');
    }
    final generation = _generation;
    final scopeGeneration = _scopeGenerations[requestScope] ?? 0;
    if (!Platform.isAndroid) throw const DouyinFailure('抖音站源当前仅支持 Android');
    final cookie = await storage.read(key: cookieKey(profile));
    if (cookie == null || cookie.isEmpty)
      throw const DouyinFailure('请先在站源管理中配置抖音 Cookie');
    final params = <String, String>{
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'version_code': '190600',
      'version_name': '19.6.0',
      'cookie_enabled': 'true',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '116.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '116.0.0.0',
      'os_name': 'Windows',
      'os_version': '10',
      'screen_width': '1920',
      'screen_height': '1080',
      'platform': 'PC',
      'pc_client_type': '1',
      'support_h265': '0',
      'support_dash': '0',
      ...query,
    };
    for (final item in cookie.split(';')) {
      final index = item.indexOf('=');
      if (index > 0 && item.substring(0, index).trim() == 'msToken') {
        params['msToken'] = item.substring(index + 1).trim();
      }
    }
    final uri = Uri.https(host, path, categoryPage ? null : params);
    final signature = categoryPage
        ? ''
        : await channel
              .invokeMethod<String>('sign', {
                'query': uri.query,
                'userAgent': userAgent,
              })
              .timeout(const Duration(seconds: 6));
    if (!categoryPage && (signature == null || signature.isEmpty))
      throw const DouyinFailure('抖音请求签名失败');
    final signed = categoryPage
        ? uri
        : Uri.parse(
            '${uri.toString()}&a_bogus=${Uri.encodeQueryComponent(signature!)}',
          );
    if (generation != _generation ||
        _profile != profile ||
        scopeGeneration != (_scopeGenerations[requestScope] ?? 0))
      throw const DouyinFailure('请求已取消');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _clients.add(client);
    _clientsByScope.putIfAbsent(requestScope, () => <HttpClient>{}).add(client);
    try {
      final pendingRequest = post
          ? client.postUrl(signed)
          : client.getUrl(signed);
      final request = await pendingRequest.timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cookieHeader, cookie);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        categoryPage ? 'text/html' : 'application/json',
      );
      request.headers.set(
        HttpHeaders.refererHeader,
        referer ??
            (host == 'live.douyin.com'
                ? 'https://live.douyin.com/'
                : 'https://www.douyin.com/?recommend=1'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        if (response.statusCode == 404 &&
            path == '/aweme/v2/web/module/feed/') {
          throw const DouyinFailure(
            '抖音精选分类接口返回 HTTP 404，网页请求方法、路径或参数可能已变更；不会用其他分栏内容替代',
          );
        }
        throw DouyinFailure('抖音请求失败（HTTP ${response.statusCode}），请检查登录状态或稍后重试');
      }
      final bytes = await _readDouyinBody(
        response,
        4 * 1024 * 1024,
      ).timeout(const Duration(seconds: 15));
      if (bytes.isEmpty)
        throw const DouyinFailure('抖音返回空响应，可能需要更新 Cookie 或在抖音网页完成验证');
      Map<String, dynamic> result;
      try {
        result = categoryPage
            ? await _decodeLiveCategories(bytes)
            : await _decodeDouyinResponse(bytes);
      } catch (_) {
        throw const DouyinFailure('抖音未返回视频数据，请在抖音网页确认账号状态');
      }
      if (intValue(result['status_code']) != 0)
        throw const DouyinFailure('抖音拒绝了请求，请更新 Cookie 或在网页完成验证');
      if (_profile != profile ||
          generation != _generation ||
          scopeGeneration != (_scopeGenerations[requestScope] ?? 0))
        throw const DouyinFailure('用户已切换，请重新加载');
      return result;
    } on TimeoutException {
      throw const DouyinFailure('抖音请求超时，请稍后重试');
    } on SocketException {
      throw const DouyinFailure('无法连接抖音，请检查网络');
    } on DouyinFailure {
      rethrow;
    } catch (_) {
      throw const DouyinFailure('抖音请求未完成，请检查网络与登录状态');
    } finally {
      _clients.remove(client);
      _clientsByScope[requestScope]?.remove(client);
      if (_clientsByScope[requestScope]?.isEmpty == true) {
        _clientsByScope.remove(requestScope);
      }
      client.close(force: true);
    }
  }

  Drama _drama(Map<String, dynamic> row, {String category = '短视频'}) {
    final id = '${row['aweme_id'] ?? ''}';
    final text = '${row['desc'] ?? ''}'.trim();
    final author = row['author'] is Map ? row['author'] as Map : const {};
    final video = row['video'] is Map ? row['video'] as Map : const {};
    final stats = row['statistics'] is Map
        ? row['statistics'] as Map
        : const {};
    final cover = video['cover'] is Map ? video['cover'] as Map : const {};
    final urls = cover['url_list'] is List
        ? cover['url_list'] as List
        : const [];
    return Drama(
      id: '$source:$id',
      source: source,
      sourceId: id,
      title: text.isEmpty ? '${author['nickname'] ?? '抖音视频'}' : text,
      description: text,
      cover: urls.isEmpty ? '' : '${urls.first}',
      episodes: 1,
      category: category,
      tags: [
        source == 'douyin-theater' ? '放映厅' : '短视频',
        if (category != '短视频') category,
      ],
      vip: false,
      heat: '${stats['digg_count'] ?? ''}',
      views: '${stats['play_count'] ?? ''}',
      creatorSecUid: '${author['sec_uid'] ?? ''}',
      creatorName: '${author['nickname'] ?? ''}',
      creatorId: '${author['unique_id'] ?? author['short_id'] ?? ''}',
      creatorAvatar: _firstDouyinUrl(
        author['avatar_thumb'] ?? author['avatar_medium'],
      ),
    );
  }

  Future<CatalogPage> catalog(
    String profile, {
    int page = 1,
    bool force = false,
    String category = '',
  }) async {
    _scope(profile);
    final feed = category.isEmpty || category == 'short_video'
        ? defaultFeed
        : category;
    if (feed == 'nearby' || feed == 'hot') {
      throw DouyinFailure(
        feed == 'nearby'
            ? '同城需要官方定位取流接口，当前网页接入尚不支持；不会改用推荐内容'
            : '热点视频流尚未接入，热搜榜不是视频流；不会改用推荐内容',
      );
    }
    if (!_supportsFeed(feed)) throw const DouyinFailure('不支持的抖音分栏，请重新选择');
    if (page < 1) throw const DouyinFailure('抖音页码无效');
    final cacheKey = '$feed:$page';
    final key = '$profile:$cacheKey';
    if (force && page == 1) {
      _catalogRevisions[feed] = (_catalogRevisions[feed] ?? 0) + 1;
      _catalogPending.removeWhere(
        (key, _) => key.startsWith('$profile:$feed:'),
      );
      _catalogTails.remove(feed);
    }
    if (!force && _catalogTails[feed] == null && _pages[cacheKey] != null) {
      return _pages[cacheKey]!;
    }
    final current = _catalogPending[key];
    if (current != null) return current;
    final generation = _generation;
    final scopeGeneration = _scopeGenerations['douyin'] ?? 0;
    final revision = _catalogRevisions[feed] ?? 0;
    void ensureCurrent() {
      if (generation != _generation ||
          _profile != profile ||
          scopeGeneration != (_scopeGenerations['douyin'] ?? 0) ||
          revision != (_catalogRevisions[feed] ?? 0)) {
        throw const DouyinFailure('请求已取消');
      }
    }

    final previous = _catalogTails[feed];
    final pending = (() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      ensureCurrent();
      if (!force && _pages[cacheKey] != null) return _pages[cacheKey]!;
      if (seriesChannels.containsKey(feed)) {
        return _seriesCatalog(profile, feed, page, ensureCurrent);
      }
      if (theaterChannels.containsKey(feed)) {
        return _theaterCatalog(profile, feed, page, ensureCurrent);
      }
      return selectedChannels.containsKey(feed)
          ? _selectedCatalog(profile, feed, page, ensureCurrent)
          : _ordinaryCatalog(profile, feed, page, ensureCurrent);
    })();
    _catalogPending[key] = pending;
    _catalogTails[feed] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_catalogPending[key], pending)) {
        _catalogPending.remove(key);
      }
      if (identical(_catalogTails[feed], pending)) {
        _catalogTails.remove(feed);
      }
    }
  }

  Future<CatalogPage> _ordinaryCatalog(
    String profile,
    String feed,
    int page,
    void Function() ensureCurrent,
  ) async {
    final cacheKey = '$feed:$page';
    final firstRefreshIndex = _nextRefreshIndex;
    _nextRefreshIndex += 3;
    final items = <Drama>[];
    final seen = <String>{};
    final retained = <String, Map<String, dynamic>>{};
    var hasMore = true;
    var followListWasPresent = false;
    var followResponseCount = 0;
    var cursor = page == 1 ? '0' : _followCursors[page];
    if (feed == 'follow' && cursor == null)
      throw const DouyinFailure('请从关注分栏第一页开始加载');
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0 && (!hasMore || items.length >= 12)) break;
      ensureCurrent();
      final feedQuery = feed == 'follow'
          ? <String, String>{'count': '20', 'cursor': cursor!, 'level': '1'}
          : <String, String>{
              'count': '20',
              'refresh_index': '${firstRefreshIndex + attempt}',
              'pull_type': page == 1 && attempt == 0 ? '2' : '1',
              'aweme_pc_rec_raw_data': '{"is_client":false}',
            };
      if (feed == 'follow' && (page > 1 || attempt > 0)) {
        feedQuery['pull_type'] = '2';
      }
      final response = await request(
        feed == 'follow'
            ? '/aweme/v1/web/follow/feed/'
            : '/aweme/v1/web/tab/feed/',
        feedQuery,
        profile,
        referer: feed == 'follow' ? 'https://www.douyin.com/follow' : null,
      );
      ensureCurrent();
      final rows = _douyinAwemeRows(response);
      if (feed == 'follow') {
        followListWasPresent |= rows != null;
        followResponseCount += rows?.length ?? 0;
      }
      for (final raw in rows?.whereType<Map>() ?? const <Map>[]) {
        final nested = raw['aweme_info'] is Map
            ? raw['aweme_info'] as Map
            : raw['aweme'] is Map
            ? raw['aweme'] as Map
            : raw;
        final row = Map<String, dynamic>.from(nested);
        final id = '${row['aweme_id'] ?? ''}';
        if (id.isEmpty ||
            row['is_ads'] == true ||
            intValue(row['is_ads']) == 1 ||
            row['video'] is! Map ||
            !seen.add(id) ||
            _variants(row).isEmpty) {
          continue;
        }
        final drama = _drama(row);
        retained[drama.id] = _compactRow(row);
        items.add(drama);
      }
      final metadata = _douyinPageMetadata(response);
      hasMore = _douyinHasMore(metadata['has_more']);
      if (feed == 'follow') {
        final next = '${metadata['max_cursor'] ?? metadata['cursor'] ?? ''}';
        hasMore = hasMore && next.isNotEmpty && next != cursor;
        cursor = next;
      }
    }
    if (items.isEmpty && feed != 'follow') {
      throw const DouyinFailure('抖音未返回可播放的普通视频，请检查 Cookie 或在网页完成验证');
    }
    ensureCurrent();
    _rows.addAll(retained);
    _trim();
    final result = CatalogPage(
      items,
      page: page,
      hasMore: hasMore,
      fresh: true,
      warning: items.isEmpty && feed == 'follow'
          ? !followListWasPresent
                ? '关注接口响应中没有识别到视频列表字段；重试会重新请求。若持续出现，可能是抖音网页接口结构已变化。'
                : followResponseCount > 0
                ? '关注接口返回了 $followResponseCount 条内容，但没有识别到可播放的视频地址。请重试；若持续出现，说明当前接口返回结构或播放地址格式有变化。'
                : '关注接口返回了空列表。重试会重新请求；若持续出现，请确认此账号关注列表中有可见作品。'
          : '',
    );
    if (feed == 'follow') {
      if (page == 1 && items.isNotEmpty) {
        _followCursors
          ..clear()
          ..[1] = '0';
      }
      if (hasMore && items.isNotEmpty) _followCursors[page + 1] = cursor!;
    }
    while (_followCursors.length > 21) {
      _followCursors.remove(_followCursors.keys.firstWhere((key) => key != 1));
    }
    if (page == 1 && items.isNotEmpty) {
      _pages.removeWhere((key, _) => key.startsWith('$feed:'));
    }
    // Do not pin an empty authenticated feed in the in-memory page cache;
    // revisiting the tab should make a fresh request.
    if (result.items.isNotEmpty) _pages[cacheKey] = result;
    while (_pages.length > 20) {
      _pages.remove(_pages.keys.first);
    }
    _updated = DateTime.now();
    _health = feed == 'follow' ? '已取得关注视频' : '已取得普通视频推荐';
    return result;
  }

  Future<CatalogPage> _selectedCatalog(
    String profile,
    String feed,
    int page,
    void Function() ensureCurrent,
  ) async {
    ensureCurrent();
    final channelInfo = selectedChannels[feed]!;
    final course = feed == 'course';
    var offset = page == 1 ? '0' : _selectedOffsets[page];
    if (course && offset == null) {
      throw const DouyinFailure('请从公开课第一页开始加载');
    }
    final seen = page == 1
        ? <String>{}
        : Set<String>.of(_selectedSeen[feed] ?? const <String>{});
    final courseIds = page == 1 ? <String>{} : Set<String>.of(_coursePresented);
    final items = <Drama>[];
    final retained = <String, Map<String, dynamic>>{};
    var hasMore = true;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0 && (!hasMore || items.length >= 12)) break;
      ensureCurrent();
      final initial = page == 1 && attempt == 0;
      final response = await request(
        course
            ? '/aweme/v1/web/douyin/select/tab/course/catagory/video/'
            : '/aweme/v2/web/module/feed/',
        course
            ? {
                'tab_id': 'screen_course_page',
                'offset': offset!,
                'size': '6',
                'tag_id_list': '[0,0,0]',
                'id_list': courseIds.join(','),
              }
            : {
                'module_id': '3003101',
                'count': initial ? '20' : '8',
                if (initial) 'refresh_index': '1',
                'pull_type': initial ? '0' : '2',
                'tag_id': channelInfo.tag,
                'refer_id': '',
                'refer_type': '10',
                'filterGids': '',
                'presented_ids': '',
                'awemePcRecRawData':
                    '{"is_xigua_user":0,"danmaku_switch_status":0,"is_client":false}',
                'Seo-Flag': '0',
              },
        profile,
        referer:
            'https://www.douyin.com/jingxuan'
            '${feed == 'jingxuan' ? '' : '/$feed'}',
        post: !course,
      );
      ensureCurrent();
      final rows = course ? response['video_items'] : response['aweme_list'];
      if (rows is! List) {
        throw const DouyinFailure('抖音精选响应缺少视频列表，请稍后重试');
      }
      hasMore = _douyinHasMore(response['has_more']);
      if (course) {
        final next = '${response['offset'] ?? ''}';
        hasMore =
            hasMore &&
            (int.tryParse(next) ?? -1) > (int.tryParse(offset!) ?? -1);
        offset = next;
      }
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final id = '${row['aweme_id'] ?? ''}';
        if (course && id.isNotEmpty) courseIds.add(id);
        if (id.isEmpty ||
            row['is_ads'] == true ||
            intValue(row['is_ads']) == 1 ||
            row['video'] is! Map ||
            seen.contains(id) ||
            _variants(row).isEmpty) {
          continue;
        }
        seen.add(id);
        final drama = _drama(row, category: channelInfo.name);
        items.add(drama);
        retained[drama.id] = _compactRow(row);
      }
    }
    ensureCurrent();
    if (items.isEmpty && page == 1) {
      throw DouyinFailure('${channelInfo.name}暂未返回可播放视频，请稍后重试或在网页完成验证');
    }
    _rows.addAll(retained);
    _trim();
    while (seen.length > 240) {
      seen.remove(seen.first);
    }
    _selectedSeen[feed] = seen;
    if (course) {
      while (courseIds.length > 240) {
        courseIds.remove(courseIds.first);
      }
      _coursePresented
        ..clear()
        ..addAll(courseIds);
      if (page == 1) {
        _selectedOffsets
          ..clear()
          ..[1] = '0';
      }
      if (hasMore) _selectedOffsets[page + 1] = offset!;
      while (_selectedOffsets.length > 21) {
        _selectedOffsets.remove(
          _selectedOffsets.keys.firstWhere((key) => key != 1),
        );
      }
    }
    final result = CatalogPage(
      items,
      page: page,
      hasMore: hasMore && items.isNotEmpty,
      fresh: true,
      warning: '',
    );
    if (page == 1) _pages.removeWhere((key, _) => key.startsWith('$feed:'));
    if (items.isNotEmpty) _pages['$feed:$page'] = result;
    while (_pages.length > 20) {
      _pages.remove(_pages.keys.first);
    }
    _updated = DateTime.now();
    _health = '已取得${channelInfo.name}视频';
    return result;
  }

  Future<CatalogPage> _seriesCatalog(
    String profile,
    String feed,
    int page,
    void Function() ensureCurrent,
  ) async {
    ensureCurrent();
    final channel = seriesChannels[feed]!;
    final offsets = _seriesOffsets.putIfAbsent(feed, () => {1: '0'});
    final offset = page == 1 ? '0' : offsets[page];
    if (offset == null) {
      throw const DouyinFailure('请从短剧分栏第一页开始加载');
    }
    final seen = page == 1
        ? <String>{}
        : Set<String>.of(_selectedSeen[feed] ?? const <String>{});
    final response = await request(
      '/aweme/v1/web/series/card/feed/',
      {
        'offset': offset,
        'count': '16',
        if (channel.contentType.isNotEmpty) 'content_type': channel.contentType,
      },
      profile,
      referer: 'https://www.douyin.com/series',
    );
    ensureCurrent();
    final rows = response['card_list'];
    if (rows is! List) {
      throw const DouyinFailure('抖音短剧响应缺少剧目列表，请稍后重试');
    }
    final items = <Drama>[];
    for (final raw in rows.whereType<Map>()) {
      final card = Map<String, dynamic>.from(raw);
      final seriesValue = card['series'] ?? card['series_info'];
      final series = seriesValue is Map
          ? Map<String, dynamic>.from(seriesValue)
          : card;
      final id = '${series['series_id'] ?? card['series_id'] ?? ''}';
      if (id.isEmpty || !seen.add(id)) continue;
      items.add(
        _seriesDrama(series, id: id, category: channel.name, fallback: card),
      );
    }
    final nextOffset = '${response['offset'] ?? ''}';
    final parsedNext = int.tryParse(nextOffset);
    final parsedOffset = int.tryParse(offset);
    final hasMore =
        _douyinHasMore(response['has_more']) &&
        parsedNext != null &&
        (parsedOffset == null || parsedNext > parsedOffset);
    ensureCurrent();
    while (seen.length > 240) {
      seen.remove(seen.first);
    }
    _selectedSeen[feed] = seen;
    if (page == 1) {
      offsets
        ..clear()
        ..[1] = '0';
      _pages.removeWhere((key, _) => key.startsWith('$feed:'));
    }
    if (hasMore) offsets[page + 1] = nextOffset;
    while (offsets.length > 21) {
      offsets.remove(offsets.keys.firstWhere((key) => key != 1));
    }
    final result = CatalogPage(
      items,
      page: page,
      hasMore: hasMore && items.isNotEmpty,
      fresh: true,
    );
    if (items.isEmpty && page == 1) {
      throw const DouyinFailure('抖音短剧分栏暂无剧目，请稍后重试');
    }
    if (items.isNotEmpty) _pages['$feed:$page'] = result;
    while (_pages.length > 20) {
      _pages.remove(_pages.keys.first);
    }
    _updated = DateTime.now();
    _health = '已取得${channel.name}';
    return result;
  }

  Drama _seriesDrama(
    Map<String, dynamic> series, {
    required String id,
    required String category,
    Map<String, dynamic> fallback = const {},
  }) {
    final authorValue = series['author'] ?? fallback['author'];
    final author = authorValue is Map ? authorValue : const {};
    final stats = series['stats'] is Map ? series['stats'] as Map : const {};
    final charge = series['charge_info'] is Map
        ? series['charge_info'] as Map
        : const {};
    final chargeCount = intValue(charge['charge_count']);
    final Object? chargedValue = series['is_charge_series'];
    final bool? vip = chargeCount > 0
        ? true
        : chargedValue == null
        ? null
        : intValue(chargedValue) > 0;
    final title = '${series['series_name'] ?? fallback['series_name'] ?? ''}'
        .trim();
    final description = '${series['desc'] ?? fallback['desc'] ?? ''}'.trim();
    final cover = _firstDouyinUrl(
      series['cover_url'] ?? series['cover'] ?? fallback['cover_url'],
    );
    final playCount = stats['play_vv'] ?? stats['play_count'] ?? '';
    return Drama(
      id: 'douyin-series:$id',
      source: source,
      sourceId: id,
      title: title.isEmpty ? '抖音短剧' : title,
      description: description,
      cover: cover,
      episodes: intValue(stats['total_episode']),
      category: category,
      vip: vip,
      views: '$playCount',
      heat: '$playCount',
      tags: ['短剧', category],
      creatorSecUid: '${author['sec_uid'] ?? ''}',
      creatorName: '${author['nickname'] ?? ''}',
      creatorId: '${author['unique_id'] ?? author['short_id'] ?? ''}',
      creatorAvatar: _firstDouyinUrl(
        author['avatar_thumb'] ?? author['avatar_medium'],
      ),
    );
  }

  Future<CatalogPage> _theaterCatalog(
    String profile,
    String feed,
    int page,
    void Function() ensureCurrent,
  ) async {
    ensureCurrent();
    final channel = theaterChannels[feed]!;
    final cursors = _theaterCursors.putIfAbsent(feed, () => {1: '0'});
    final requestedCursor = page == 1 ? '0' : cursors[page];
    if (requestedCursor == null) {
      throw const DouyinFailure('请从放映厅分栏第一页开始加载');
    }
    var cursor = requestedCursor;
    final seen = page == 1
        ? <String>{}
        : Set<String>.of(_selectedSeen[feed] ?? const <String>{});
    final items = <Drama>[];
    final retained = <String, Map<String, dynamic>>{};
    var hasMore = true;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0 && (!hasMore || items.length >= 12)) break;
      ensureCurrent();
      final response = await request(
        '/aweme/v1/web/lvideo/theater/feed',
        {
          'cursor': cursor,
          'count': '20',
          'custom_album_type': channel.albumType,
        },
        profile,
        referer: 'https://www.douyin.com/vschannel/${channel.path}',
      );
      ensureCurrent();
      final rows = response['aweme_list'];
      if (rows is! List) {
        throw const DouyinFailure('抖音放映厅响应缺少视频列表，请稍后重试');
      }
      final currentCursor = cursor;
      final nextCursor =
          '${response['next_cursor'] ?? response['cursor'] ?? ''}';
      hasMore =
          _douyinHasMore(response['has_more']) &&
          nextCursor.isNotEmpty &&
          nextCursor != currentCursor;
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final id = '${row['aweme_id'] ?? ''}';
        if (id.isEmpty ||
            row['is_ads'] == true ||
            intValue(row['is_ads']) == 1 ||
            row['video'] is! Map ||
            !seen.add(id) ||
            _variants(row).isEmpty) {
          continue;
        }
        final drama = _drama(row, category: channel.name);
        items.add(drama);
        retained[drama.id] = _compactRow(row);
      }
      cursor = nextCursor;
    }
    ensureCurrent();
    if (items.isEmpty && page == 1) {
      throw DouyinFailure('${channel.name}暂未返回可播放视频，请稍后重试或在网页完成验证');
    }
    _rows.addAll(retained);
    _trim();
    while (seen.length > 240) {
      seen.remove(seen.first);
    }
    _selectedSeen[feed] = seen;
    if (page == 1) {
      cursors
        ..clear()
        ..[1] = '0';
      _pages.removeWhere((key, _) => key.startsWith('$feed:'));
    }
    if (hasMore) cursors[page + 1] = cursor;
    while (cursors.length > 21) {
      cursors.remove(cursors.keys.firstWhere((key) => key != 1));
    }
    final result = CatalogPage(
      items,
      page: page,
      hasMore: hasMore && items.isNotEmpty,
      fresh: true,
    );
    if (items.isNotEmpty) _pages['$feed:$page'] = result;
    while (_pages.length > 20) {
      _pages.remove(_pages.keys.first);
    }
    _updated = DateTime.now();
    _health = '已取得${channel.name}视频';
    return result;
  }

  Map<String, dynamic> _compactRow(Map row) {
    Map<String, dynamic> pick(Map value, List<String> keys) => {
      for (final key in keys)
        if (value.containsKey(key)) key: value[key],
    };
    Map<String, dynamic> address(Object? value) => value is Map
        ? pick(value, ['url_list', 'height', 'data_size'])
        : <String, dynamic>{};
    final video = row['video'] is Map ? row['video'] as Map : const {};
    return {
      ...pick(row, ['aweme_id', 'desc']),
      'author': pick(row['author'] is Map ? row['author'] as Map : const {}, [
        'sec_uid',
        'nickname',
        'unique_id',
        'short_id',
        'avatar_thumb',
        'avatar_medium',
      ]),
      'statistics': pick(
        row['statistics'] is Map ? row['statistics'] as Map : const {},
        ['digg_count', 'play_count'],
      ),
      'video': {
        ...pick(video, ['height']),
        for (final field in [
          'cover',
          'play_addr_h264',
          'play_addr',
          'play_addr_lowbr',
          'play_addr_720p',
          'play_addr_265',
        ])
          if (video[field] is Map) field: address(video[field]),
        'bit_rate': [
          for (final rate
              in (video['bit_rate'] as List? ?? const []).whereType<Map>())
            {
              ...pick(rate, ['is_h265', 'bit_rate']),
              'play_addr': address(rate['play_addr']),
            },
        ],
      },
    };
  }

  int _latestPage(String feed) => _pages.entries
      .where((entry) => entry.key.startsWith('$feed:'))
      .fold(
        0,
        (latest, entry) =>
            latest > entry.value.page ? latest : entry.value.page,
      );

  CatalogPage cached(String profile, {String category = ''}) {
    _scope(profile);
    final feed = category.isEmpty || category == 'short_video'
        ? defaultFeed
        : category;
    if (!_supportsFeed(feed)) throw const DouyinFailure('当前抖音子项不支持该分类');
    final pages =
        _pages.entries
            .where((entry) => entry.key.startsWith('$feed:'))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) => a.page.compareTo(b.page));
    return CatalogPage(
      {
        for (final page in pages)
          for (final drama in page.items) drama.id: drama,
      }.values.toList(),
      hasMore: pages.lastOrNull?.hasMore ?? true,
      page: pages.lastOrNull?.page ?? 1,
    );
  }

  Future<DramaDetail> detail(
    Drama drama,
    String profile, {
    bool force = false,
  }) async {
    _scope(profile);
    if (drama.id.startsWith('douyin-series:')) {
      return _seriesDetail(drama, profile, force: force);
    }
    var row = force ? null : _rows[drama.id];
    if (row == null) {
      final response = await request('/aweme/v1/web/aweme/detail/', {
        'aweme_id': drama.sourceId.isEmpty
            ? drama.id.split(':').last
            : drama.sourceId,
      }, profile);
      if (response['aweme_detail'] is! Map)
        throw const DouyinFailure('抖音视频暂不可用或已删除');
      row = Map<String, dynamic>.from(response['aweme_detail'] as Map);
      _rows[drama.id] = _compactRow(row);
      _trim();
    }
    if (_variants(row).isEmpty) throw const DouyinFailure('抖音视频未返回可播放地址');
    return DramaDetail(_drama(row, category: drama.category), [
      Episode({'id': drama.sourceId, 'title': '播放视频', 'currentEpisode': 1}, 1),
    ]);
  }

  Future<DramaDetail> _seriesDetail(
    Drama drama,
    String profile, {
    bool force = false,
  }) async {
    _scope(profile);
    final seriesId = drama.sourceId.isEmpty
        ? drama.id.split(':').last
        : drama.sourceId;
    if (!RegExp(r'^\d+$').hasMatch(seriesId)) {
      throw const DouyinFailure('未取得有效的抖音短剧标识');
    }
    final cached = _seriesDetails[seriesId];
    if (!force && cached != null) {
      return DramaDetail(
        cached.drama.merge(drama),
        cached.episodes,
        warning: cached.warning,
      );
    }
    final detailResponse = await request(
      '/aweme/v1/web/series/detail/',
      {'series_id': seriesId},
      profile,
      referer: 'https://www.douyin.com/series',
    );
    final generation = _generation;
    void ensureCurrent() {
      if (generation != _generation || _profile != profile) {
        throw const DouyinFailure('请求已取消');
      }
    }

    ensureCurrent();
    if (detailResponse['series_info'] is! Map) {
      throw const DouyinFailure('抖音短剧详情响应缺少剧目信息');
    }
    final seriesInfo = Map<String, dynamic>.from(
      detailResponse['series_info'] as Map,
    );
    final nestedSeries = seriesInfo['series'];
    final metadata = nestedSeries is Map
        ? Map<String, dynamic>.from(nestedSeries)
        : seriesInfo;
    final stats = metadata['stats'] is Map
        ? metadata['stats'] as Map
        : const {};
    final charge = metadata['charge_info'] is Map
        ? metadata['charge_info'] as Map
        : const {};
    final totalEpisodes = intValue(stats['total_episode']);
    final chargeCount = intValue(charge['charge_count']);
    const maxDetailEpisodes = 120;
    const maxDetailBatches = maxDetailEpisodes ~/ 20;
    final targetCount = totalEpisodes <= 0 || totalEpisodes > maxDetailEpisodes
        ? maxDetailEpisodes
        : totalEpisodes;
    final episodesById = <String, ({int number, Episode episode})>{};
    final retainedRows = <String, Map<String, dynamic>>{};
    final seenCursors = <String>{'1'};
    var cursor = '1';
    var hasMore = true;
    var batch = 0;
    while (hasMore &&
        episodesById.length < targetCount &&
        batch < maxDetailBatches) {
      ensureCurrent();
      final response = await request(
        '/aweme/v1/web/series/aweme/',
        {'series_id': seriesId, 'cursor': cursor, 'count': '20'},
        profile,
        referer: 'https://www.douyin.com/series',
      );
      ensureCurrent();
      final rows = response['aweme_list'];
      if (rows is! List) {
        throw const DouyinFailure('抖音短剧详情未返回分集列表');
      }
      var added = 0;
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final episodeId = '${row['aweme_id'] ?? ''}';
        if (episodeId.isEmpty || episodesById.containsKey(episodeId)) continue;
        final basic = row['series_basic_info'] is Map
            ? row['series_basic_info'] as Map
            : const {};
        final number = intValue(
          basic['current_episode'] ??
              basic['episode'] ??
              row['current_episode'],
        );
        final episodeNumber = number > 0 ? number : episodesById.length + 1;
        final paid = _seriesEpisodeIsPaid(
          row,
          episodeNumber,
          totalEpisodes,
          chargeCount,
        );
        final title = '第$episodeNumber集';
        episodesById[episodeId] = (
          number: episodeNumber,
          episode: Episode({
            'id': episodeId,
            'title': title,
            'currentEpisode': episodeNumber,
            'vip': paid,
          }, episodeNumber),
        );
        if (!paid && row['video'] is Map) {
          retainedRows['$seriesId:$episodeId'] = _compactRow(row);
        }
        added++;
      }
      final nextCursor =
          '${response['max_cursor'] ?? response['cursor'] ?? ''}';
      hasMore =
          _douyinHasMore(response['has_more']) &&
          nextCursor.isNotEmpty &&
          nextCursor != cursor &&
          seenCursors.add(nextCursor) &&
          added > 0;
      cursor = nextCursor;
      batch++;
    }
    ensureCurrent();
    if (episodesById.isEmpty) {
      throw const DouyinFailure('抖音短剧没有返回可用分集');
    }
    final episodeRows = episodesById.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    final freshDrama = _seriesDrama(
      metadata,
      id: seriesId,
      category: drama.category.isEmpty ? '短剧' : drama.category,
    );
    final detail = DramaDetail(
      drama.merge(freshDrama),
      [for (final item in episodeRows) item.episode],
      warning: totalEpisodes > episodesById.length
          ? '抖音共标记$totalEpisodes集，本次接口最多返回${episodesById.length}集'
          : '',
    );
    _seriesEpisodeRows.addAll(retainedRows);
    _seriesDetails[seriesId] = detail;
    _trim();
    return detail;
  }

  bool _seriesEpisodeIsPaid(
    Map<String, dynamic> row,
    int episodeNumber,
    int totalEpisodes,
    int chargeCount,
  ) {
    for (final value in [
      row,
      if (row['series_paid_info'] is Map) row['series_paid_info'] as Map,
      if (row['entertainment_video_paid_way'] is Map)
        row['entertainment_video_paid_way'] as Map,
    ]) {
      for (final key in ['is_paid', 'is_charge', 'is_vip', 'is_locked']) {
        final flag = value[key];
        if (flag == true || intValue(flag) == 1) return true;
      }
    }
    if (totalEpisodes <= 0 || chargeCount <= 0) return false;
    return episodeNumber > totalEpisodes - chargeCount;
  }

  void cancelComments(String requestScope) {
    if (_commentScopes.contains(requestScope)) cancel(scope: requestScope);
  }

  Future<DouyinCommentPage> comments(
    Drama drama,
    String profile, {
    required String requestScope,
    String cursor = '0',
  }) async {
    if (drama.source != 'douyin') {
      throw const DouyinFailure('直播聊天不属于视频评论');
    }
    final id = drama.sourceId.isEmpty
        ? drama.id.split(':').last
        : drama.sourceId;
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw const DouyinFailure('未取得有效的视频标识');
    }
    _commentScopes.add(requestScope);
    final response =
        await request(
          '/aweme/v1/web/comment/list/',
          {'aweme_id': id, 'cursor': cursor, 'count': '20', 'item_type': '0'},
          profile,
          referer: 'https://www.douyin.com/video/$id',
          requestScope: requestScope,
        ).whenComplete(() {
          _commentScopes.remove(requestScope);
          _scopeGenerations.remove(requestScope);
          _clientsByScope.remove(requestScope);
        });
    final rows = response['comments'];
    if (rows is! List) {
      throw const DouyinFailure('评论接口未返回有效列表，请稍后重试');
    }
    final items = <DouyinComment>[];
    for (final row in rows.take(20).whereType<Map>()) {
      final user = row['user'] is Map ? row['user'] as Map : const {};
      final id = '${row['cid'] ?? ''}';
      final text = '${row['text'] ?? ''}';
      if (id.isEmpty || text.trim().isEmpty) continue;
      items.add(
        DouyinComment(
          id: id,
          author: '${user['nickname'] ?? '抖音用户'}',
          avatar: _firstDouyinUrl(
            user['avatar_thumb'] ?? user['avatar_medium'],
          ),
          text: text,
          likes: intValue(row['digg_count']),
        ),
      );
    }
    final next = '${response['cursor'] ?? ''}';
    return DouyinCommentPage(
      items: items,
      cursor: next,
      hasMore:
          _douyinHasMore(response['has_more']) &&
          next.isNotEmpty &&
          next != cursor &&
          rows.isNotEmpty,
      total: intValue(response['total']),
    );
  }

  Future<DouyinCreatorPage> creatorVideos(
    Drama drama,
    String profile, {
    String cursor = '0',
  }) async {
    _scope(profile);
    var current = _rows[drama.id];
    var creator = drama;
    if (creator.creatorSecUid.isEmpty && current != null)
      creator = _drama(current);
    if (creator.creatorSecUid.isEmpty) {
      final response = await request('/aweme/v1/web/aweme/detail/', {
        'aweme_id': drama.sourceId.isEmpty
            ? drama.id.split(':').last
            : drama.sourceId,
      }, profile);
      if (response['aweme_detail'] is! Map) {
        throw const DouyinFailure('无法读取视频作者信息');
      }
      current = Map<String, dynamic>.from(response['aweme_detail'] as Map);
      _rows[drama.id] = _compactRow(current);
      creator = _drama(current);
    }
    if (creator.creatorSecUid.isEmpty) {
      throw const DouyinFailure('这个视频没有可用的作者主页信息');
    }
    final scope = drama.source == 'douyin-live' ? 'douyin-live' : 'douyin';
    final profileRequest = cursor == '0'
        ? request(
                '/aweme/v1/web/user/profile/other/',
                {'sec_user_id': creator.creatorSecUid},
                profile,
                requestScope: scope,
              )
              .then<Map>((response) {
                return response['user'] is Map
                    ? response['user'] as Map
                    : const {};
              })
              .catchError((Object _) => <String, dynamic>{})
        : Future<Map>.value(const {});
    final response = await request(
      '/aweme/v1/web/aweme/post/',
      {
        'sec_user_id': creator.creatorSecUid,
        'max_cursor': cursor,
        'count': '18',
        'locate_query': 'false',
        'show_live_replay_strategy': '1',
        'need_time_list': '0',
        'time_list_query': '0',
        'whale_cut_token': '',
      },
      profile,
      requestScope: scope,
    );
    final rawItems = response['aweme_list'] as List? ?? const [];
    final items = <Drama>[];
    for (final raw in rawItems.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final id = '${row['aweme_id'] ?? ''}';
      if (id.isEmpty || row['video'] is! Map || _variants(row).isEmpty)
        continue;
      final item = _drama(row);
      _rows[item.id] = _compactRow(row);
      items.add(item);
    }
    _trim();
    final profileInfo = await profileRequest;
    final user = profileInfo.isNotEmpty
        ? profileInfo
        : response['user_info'] is Map
        ? response['user_info'] as Map
        : response['user'] is Map
        ? response['user'] as Map
        : const {};
    return DouyinCreatorPage(
      userId: '${user['unique_id'] ?? user['short_id'] ?? creator.creatorId}',
      bio: '${user['signature'] ?? ''}',
      likes: user['total_favorited'] == null
          ? null
          : intValue(user['total_favorited']),
      following: user['following_count'] == null
          ? null
          : intValue(user['following_count']),
      followers: user['follower_count'] == null
          ? null
          : intValue(user['follower_count']),
      name: '${user['nickname'] ?? creator.creatorName}',
      avatar:
          _firstDouyinUrl(user['avatar_thumb'] ?? user['avatar_medium']).isEmpty
          ? creator.creatorAvatar
          : _firstDouyinUrl(user['avatar_thumb'] ?? user['avatar_medium']),
      items: items,
      cursor: '${response['max_cursor'] ?? cursor}',
      hasMore: _douyinHasMore(response['has_more']),
    );
  }

  List<({int height, int codecPriority, int bitrate, String url})> _variants(
    Map row,
  ) {
    final video = row['video'];
    if (video is! Map) return const [];
    final result =
        <({int height, int codecPriority, int bitrate, String url})>[];
    void add(Map value, int height, {int codecPriority = 2, int bitrate = 0}) {
      for (final raw in value['url_list'] as List? ?? const []) {
        final uri = Uri.tryParse('$raw');
        if (uri != null &&
            uri.scheme == 'https' &&
            uri.userInfo.isEmpty &&
            uri.host.isNotEmpty) {
          if (!result.any((item) => item.url == '$raw')) {
            result.add((
              height: height,
              codecPriority: codecPriority,
              bitrate: bitrate > 0 ? bitrate : intValue(value['data_size']),
              url: '$raw',
            ));
          }
        }
      }
    }

    for (final (field, priority) in const [
      ('play_addr_h264', 4),
      ('play_addr', 3),
      ('play_addr_lowbr', 2),
      ('play_addr_720p', 2),
      ('play_addr_265', 1),
    ]) {
      if (video[field] is Map) {
        add(
          video[field] as Map,
          intValue(video['height']),
          codecPriority: priority,
        );
      }
    }

    for (final raw in video['bit_rate'] as List? ?? const []) {
      if (raw is Map && raw['play_addr'] is Map) {
        final addr = raw['play_addr'] as Map;
        add(
          addr,
          intValue(addr['height']) > 0
              ? intValue(addr['height'])
              : intValue(video['height']),
          codecPriority: raw['is_h265'] == true || intValue(raw['is_h265']) == 1
              ? 1
              : 4,
          bitrate: intValue(raw['bit_rate']),
        );
      }
    }
    result.sort((a, b) {
      final byHeight = b.height.compareTo(a.height);
      if (byHeight != 0) return byHeight;
      final byCodec = b.codecPriority.compareTo(a.codecPriority);
      if (byCodec != 0) return byCodec;
      return b.bitrate.compareTo(a.bitrate);
    });
    return result;
  }

  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode,
    String profile, {
    int quality = 0,
  }) async {
    _scope(profile);
    if (drama.id.startsWith('douyin-series:')) {
      if (episode.vip) {
        throw const DouyinFailure('该分集被抖音标记为付费内容，应用不会请求其播放地址');
      }
      final seriesId = drama.sourceId.isEmpty
          ? drama.id.split(':').last
          : drama.sourceId;
      var row = _seriesEpisodeRows['$seriesId:${episode.id}'];
      if (row == null) {
        await _seriesDetail(drama, profile, force: true);
        row = _seriesEpisodeRows['$seriesId:${episode.id}'];
      }
      if (row == null) {
        throw const DouyinFailure('抖音短剧分集暂未返回播放信息');
      }
      final variants = _variants(row);
      if (variants.isEmpty) {
        throw DouyinFailure(
          episode.vip ? '该短剧分集被抖音标记为付费或试看限制，未返回可播放地址' : '抖音短剧分集未返回可播放地址',
        );
      }
      final chosen = quality == 0
          ? variants.first
          : variants.firstWhere(
              (item) => item.height <= quality,
              orElse: () => variants.last,
            );
      return PlaybackPlan(
        url: chosen.url,
        quality: chosen.height,
        qualities: variants.map((item) => item.height).toSet().toList(),
        headers: const {
          'User-Agent': userAgent,
          'Referer': 'https://www.douyin.com/',
        },
      );
    }
    await detail(drama, profile);
    final variants = _variants(_rows[drama.id]!);
    final chosen = quality == 0
        ? variants.first
        : variants.firstWhere(
            (item) => item.height <= quality,
            orElse: () => variants.last,
          );
    return PlaybackPlan(
      url: chosen.url,
      quality: chosen.height,
      qualities: variants.map((item) => item.height).toSet().toList(),
      headers: const {
        'User-Agent': userAgent,
        'Referer': 'https://www.douyin.com/',
      },
    );
  }

  SourceStatus status(String profile) {
    _scope(profile);
    return SourceStatus.fromJson({
      'source': source,
      'count': source == 'douyin-series'
          ? _pages.values
                .expand((page) => page.items)
                .map((drama) => drama.id)
                .toSet()
                .length
          : _rows.length,
      'page': _latestPage(defaultFeed),
      'hasMore':
          _pages['$defaultFeed:${_latestPage(defaultFeed)}']?.hasMore ?? true,
      'updatedAt': _updated?.toIso8601String(),
      'stage': _stage.isEmpty ? _health : _stage,
      'running': _running,
      'operation': _operation,
      'error': _error,
      'startedAt': _started?.toIso8601String(),
      'finishedAt': _finished?.toIso8601String(),
      'health': {
        'state': _health.isEmpty ? 'idle' : 'catalogOnly',
        'sample': _health,
      },
    });
  }

  Future<String> cover(Drama drama) async {
    final uri = Uri.tryParse(drama.cover);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty)
      throw const DouyinFailure('视频封面不可用');
    final temporary = await getTemporaryDirectory();
    final directory = await Directory(
      '${temporary.path}/douyin-covers',
    ).create(recursive: true);
    final file = File(
      '${directory.path}/douyin-cover-${drama.sourceId.replaceAll(RegExp(r'[^0-9]'), '')}.img',
    );
    if (await file.exists()) return file.path;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) throw const DouyinFailure('视频封面暂不可用');
      final bytes = await _readDouyinBody(
        response,
        5 * 1024 * 1024,
      ).timeout(const Duration(seconds: 12));
      await file.writeAsBytes(bytes, flush: true);
      await _trimCovers(directory, file.path);
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  int _coverWrites = 0;
  Future<void> _trimCovers(Directory directory, String keep) async {
    if (++_coverWrites % 20 != 0) return;
    try {
      final rows = <({File file, FileStat stat})>[];
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File) rows.add((file: entry, stat: await entry.stat()));
      }
      rows.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
      var bytes = rows.fold<int>(0, (sum, row) => sum + row.stat.size);
      var count = rows.length;
      for (final row in rows) {
        if (count <= 120 && bytes <= 50 * 1024 * 1024) break;
        if (row.file.path == keep) continue;
        await row.file.delete();
        count--;
        bytes -= row.stat.size;
      }
    } on FileSystemException {}
  }
}

class DouyinLiveSource {
  DouyinLiveSource(this.web);

  final DouyinSource web;
  final _rows = <String, Map<String, dynamic>>{};
  final _pages = <String, CatalogPage>{};
  final _catalogPending = <String, Future<CatalogPage>>{};
  List<CatalogCategory>? _categories;
  Future<List<CatalogCategory>>? _categoriesPending;
  DateTime? _updated;
  bool _running = false;
  String _error = '', _stage = '';
  String _operation = '';
  DateTime? _started, _finished;
  int _generation = 0;

  void reset() {
    _generation++;
    web.cancel(scope: 'douyin-live');
    web.cancel(scope: 'douyin-live-categories');
    _rows.clear();
    _pages.clear();
    _catalogPending.clear();
    _categories = null;
    _categoriesPending = null;
    _updated = null;
    _running = false;
    _error = '';
    _stage = '';
    _operation = '';
    _started = null;
    _finished = null;
  }

  Future<List<CatalogCategory>> categories(
    String profile, {
    bool force = false,
  }) async {
    if (force) _categories = null;
    if (_categories != null) return _categories!;
    if (_categoriesPending != null) return _categoriesPending!;
    final generation = _generation;
    final pending = (() async {
      final response = await web.request(
        '/',
        {},
        profile,
        host: 'live.douyin.com',
        requestScope: 'douyin-live-categories',
        categoryPage: true,
      );
      if (generation != _generation) throw const DouyinFailure('请求已取消');
      final result = <CatalogCategory>[
        const CatalogCategory('recommend', '精选'),
        const CatalogCategory('follow', '关注'),
      ];
      final seen = <String>{'720:1'};
      void add(Object? value, int depth) {
        if (value is! Map || depth > 3 || result.length >= 80) return;
        final partition = value['partition'];
        if (partition is Map) {
          final id = '${partition['id_str'] ?? partition['id'] ?? ''}';
          final type = '${partition['type'] ?? ''}';
          final title = '${partition['title'] ?? ''}'.trim();
          if ((depth == 0 ||
                  {
                    '同城',
                    '游戏',
                    '明星',
                    '聊天',
                    '唱歌团播',
                    '颜值',
                    '派对',
                  }.contains(title)) &&
              RegExp(r'^\d+$').hasMatch(id) &&
              RegExp(r'^\d+$').hasMatch(type) &&
              title.isNotEmpty &&
              seen.add('$id:$type')) {
            result.add(CatalogCategory('partition:$id:$type', title));
          }
        }
        for (final child in value['sub_partition'] as List? ?? const []) {
          add(child, depth + 1);
        }
      }

      for (final item in response['categories'] as List? ?? const []) {
        add(item, 0);
      }
      if (result.length <= 2) throw const DouyinFailure('官方直播分类为空，请重新加载分类');
      _categories = result;
      return result;
    })();
    _categoriesPending = pending;
    try {
      return await pending;
    } finally {
      if (identical(_categoriesPending, pending)) _categoriesPending = null;
    }
  }

  Map<String, String> _roomQuery({
    required int page,
    String partition = '720',
    String type = '1',
  }) => {
    'aid': '6383',
    'app_name': 'douyin_web',
    'live_id': '1',
    'device_platform': 'web',
    'language': 'zh-CN',
    'enter_from': 'link_share',
    'cookie_enabled': 'true',
    'screen_width': '1980',
    'screen_height': '1080',
    'browser_name': 'Chrome',
    'browser_version': '125.0.0.0',
    'count': '15',
    'offset': '${(page - 1) * 15}',
    'partition': partition,
    'partition_type': type,
    'req_from': '2',
  };

  SourceStatus startJob(String profile, String operation) {
    if (!{'update', 'more', 'check', 'checkCatalog'}.contains(operation)) {
      throw const DouyinFailure('抖音直播暂不支持此操作');
    }
    if (_running) return status();
    _running = true;
    _error = '';
    _operation = operation;
    _stage = '正在获取直播间';
    _started = DateTime.now();
    _finished = null;
    final generation = _generation;
    final page = operation == 'more' && _pages.isNotEmpty
        ? _latestPage('recommend') + 1
        : 1;
    unawaited(() async {
      try {
        await catalog(profile, page: page, force: true);
        if (generation == _generation) _stage = '已获取直播间';
      } catch (error) {
        if (generation == _generation) {
          _error = error.toString();
          _stage = '获取失败';
        }
      } finally {
        if (generation == _generation) {
          _running = false;
          _finished = DateTime.now();
        }
      }
    }());
    return status();
  }

  void cancel() {
    if (!_running) return;
    _generation++;
    _running = false;
    _stage = '已停止';
    _finished = DateTime.now();
    web.cancel(scope: 'douyin-live');
  }

  Future<CatalogPage> catalog(
    String profile, {
    int page = 1,
    bool force = false,
    String category = '',
  }) async {
    final feed = category.isEmpty ? 'recommend' : category;
    if (feed != 'recommend' &&
        feed != 'follow' &&
        !RegExp(r'^partition:\d+:\d+$').hasMatch(feed))
      throw const DouyinFailure('此直播分栏尚未接入');
    final key = '$feed:$page';
    if (!force && _pages[key] != null) return _pages[key]!;
    final pending = _catalogPending[key];
    if (pending != null) return pending;
    final generation = _generation;
    final request = _loadCatalog(profile, page, generation, feed);
    _catalogPending[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_catalogPending[key], request)) {
        _catalogPending.remove(key);
      }
    }
  }

  Future<CatalogPage> _loadCatalog(
    String profile,
    int page,
    int generation,
    String feed,
  ) async {
    final ownsRunning = !_running;
    if (ownsRunning) _running = true;
    _error = '';
    _stage = '正在获取直播间';
    try {
      final partition = feed.startsWith('partition:')
          ? feed.split(':').sublist(1)
          : ['720', '1'];
      final response = await web.request(
        feed == 'follow'
            ? '/webcast/web/feed/follow/'
            : '/webcast/web/partition/detail/room/v2/',
        feed == 'follow'
            ? {'scene': 'aweme_pc_follow_top'}
            : _roomQuery(
                page: page,
                partition: partition[0],
                type: partition[1],
              ),
        profile,
        host: feed == 'follow' ? 'www.douyin.com' : 'live.douyin.com',
        referer: feed == 'follow' ? 'https://www.douyin.com/follow' : null,
        requestScope: 'douyin-live',
      );
      if (generation != _generation) throw const DouyinFailure('请求已取消');
      final data = response['data'] is Map ? response['data'] as Map : const {};
      final rawRooms = data['data'] as List? ?? const [];
      final items = <Drama>[];
      for (final value in rawRooms.whereType<Map>()) {
        if (feed == 'follow' &&
            (value['is_recommend'] == true ||
                intValue(value['is_recommend']) == 1))
          continue;
        final room = value['room'] is Map ? value['room'] as Map : const {};
        final owner = room['owner'] is Map ? room['owner'] as Map : const {};
        final id = '${value['web_rid'] ?? ''}';
        if (id.isEmpty || room.isEmpty) continue;
        final cover = _firstDouyinUrl(room['cover']);
        final title = '${room['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        final drama = Drama(
          id: 'douyin-live:$id',
          source: 'douyin-live',
          sourceId: id,
          title: title,
          description: '${owner['nickname'] ?? ''}',
          cover: cover,
          episodes: 1,
          category: '直播',
          tags: const ['直播'],
          vip: false,
          creatorName: '${owner['nickname'] ?? ''}',
          creatorSecUid: '${owner['sec_uid'] ?? owner['sec_user_id'] ?? ''}',
          creatorId: '${owner['unique_id'] ?? owner['short_id'] ?? ''}',
          creatorAvatar: _firstDouyinUrl(owner['avatar_thumb']),
        );
        _rows[drama.id] = Map<String, dynamic>.from(value);
        items.add(drama);
      }
      if (items.isEmpty && feed != 'follow')
        throw const DouyinFailure('该分栏暂未返回直播间');
      while (_rows.length > 180) {
        _rows.remove(_rows.keys.first);
      }
      final hasMore = feed == 'follow'
          ? false
          : data.containsKey('has_more')
          ? _douyinHasMore(data['has_more'])
          : rawRooms.length >= 15;
      final result = CatalogPage(
        items,
        hasMore: hasMore,
        page: page,
        fresh: true,
        warning: items.isEmpty && feed == 'follow'
            ? '当前账号关注的作者暂无可播放直播，请确认 Cookie 对应账号'
            : '',
      );
      if (page == 1 && items.isNotEmpty) {
        _pages.removeWhere((key, _) => key.startsWith('$feed:'));
      }
      _pages['$feed:$page'] = result;
      while (_pages.length > 12) {
        _pages.remove(_pages.keys.first);
      }
      _updated = DateTime.now();
      _stage = '已获取直播间';
      return result;
    } catch (error) {
      if (generation == _generation) {
        _error = error.toString();
        _stage = '获取失败';
      }
      rethrow;
    } finally {
      if (ownsRunning) _running = false;
    }
  }

  int _latestPage(String feed) => _pages.entries
      .where((entry) => entry.key.startsWith('$feed:'))
      .fold(
        0,
        (latest, entry) =>
            latest > entry.value.page ? latest : entry.value.page,
      );

  CatalogPage cached({String category = ''}) {
    final feed = category.isEmpty ? 'recommend' : category;
    final pages =
        _pages.entries
            .where((entry) => entry.key.startsWith('$feed:'))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) => a.page.compareTo(b.page));
    return CatalogPage(
      {
        for (final page in pages)
          for (final drama in page.items) drama.id: drama,
      }.values.toList(),
      hasMore: pages.lastOrNull?.hasMore ?? true,
      page: pages.lastOrNull?.page ?? 1,
    );
  }

  Drama _roomDrama(Map<String, dynamic> value) {
    final room = value['room'] is Map ? value['room'] as Map : const {};
    final owner = room['owner'] is Map ? room['owner'] as Map : const {};
    final id = '${value['web_rid'] ?? ''}';
    return Drama(
      id: 'douyin-live:$id',
      source: 'douyin-live',
      sourceId: id,
      title: '${room['title'] ?? '抖音直播'}',
      description: '${owner['nickname'] ?? ''}',
      cover: _firstDouyinUrl(room['cover']),
      episodes: 1,
      category: '直播',
      tags: const ['直播'],
      vip: false,
      creatorName: '${owner['nickname'] ?? ''}',
      creatorSecUid: '${owner['sec_uid'] ?? owner['sec_user_id'] ?? ''}',
      creatorId: '${owner['unique_id'] ?? owner['short_id'] ?? ''}',
      creatorAvatar: _firstDouyinUrl(owner['avatar_thumb']),
    );
  }

  Future<Map<String, dynamic>> _readRoom(String profile, Drama drama) async {
    final webRid = drama.sourceId.isEmpty
        ? drama.id.split(':').last
        : drama.sourceId;
    final response = await web.request(
      '/webcast/room/web/enter/',
      {
        'aid': '6383',
        'app_name': 'douyin_web',
        'live_id': '1',
        'device_platform': 'web',
        'language': 'zh-CN',
        'browser_language': 'zh-CN',
        'browser_platform': 'Win32',
        'browser_name': 'Chrome',
        'browser_version': '125.0.0.0',
        'web_rid': webRid,
        'msToken': '',
      },
      profile,
      host: 'live.douyin.com',
      referer: 'https://live.douyin.com/$webRid',
      requestScope: 'douyin-live',
    );
    final data = response['data'] is Map ? response['data'] as Map : const {};
    final rooms = data['data'] as List? ?? const [];
    if (rooms.isEmpty || rooms.first is! Map) {
      throw const DouyinFailure('直播间信息已失效，可能已下播');
    }
    final room = Map<String, dynamic>.from(rooms.first as Map);
    if (data['user'] is Map) {
      room['owner'] = {
        if (room['owner'] is Map)
          ...Map<String, dynamic>.from(room['owner'] as Map),
        ...Map<String, dynamic>.from(data['user'] as Map),
      };
    }
    return room;
  }

  Future<Drama> creator(String profile, Drama drama) async {
    if (drama.creatorSecUid.isNotEmpty) return drama;
    final cached = _rows[drama.id];
    if (cached != null) {
      final value = _roomDrama(cached);
      if (value.creatorSecUid.isNotEmpty) return value;
    }
    final room = await _readRoom(profile, drama);
    final value = _roomDrama({'room': room, 'web_rid': drama.sourceId});
    if (value.creatorSecUid.isEmpty) throw const DouyinFailure('直播间未返回作者主页标识');
    return drama.merge(value);
  }

  Future<DouyinLiveRoom> room(String profile, Drama drama) async {
    final webRid = drama.sourceId.isEmpty
        ? drama.id.split(':').last
        : drama.sourceId;
    final room = await _readRoom(profile, drama);
    if (intValue(room['status']) != 2) {
      throw const DouyinFailure('该直播间当前未开播');
    }
    final stream = room['stream_url'] is Map
        ? Map<String, dynamic>.from(room['stream_url'] as Map)
        : <String, dynamic>{};
    final plan = _playbackPlan(stream, webRid);
    final owner = room['owner'] is Map ? room['owner'] as Map : const {};
    final cover = _firstDouyinUrl(room['cover']);
    return DouyinLiveRoom(
      drama: Drama(
        id: 'douyin-live:$webRid',
        source: 'douyin-live',
        sourceId: webRid,
        title: '${room['title'] ?? drama.title}',
        description: '${owner['nickname'] ?? drama.description}',
        cover: cover.isEmpty ? drama.cover : cover,
        episodes: 1,
        category: '直播',
        tags: const ['直播'],
        vip: false,
        creatorName: '${owner['nickname'] ?? drama.creatorName}',
        creatorSecUid:
            '${owner['sec_uid'] ?? owner['sec_user_id'] ?? drama.creatorSecUid}',
        creatorId:
            '${owner['unique_id'] ?? owner['short_id'] ?? drama.creatorId}',
        creatorAvatar: _firstDouyinUrl(owner['avatar_thumb']).isEmpty
            ? drama.creatorAvatar
            : _firstDouyinUrl(owner['avatar_thumb']),
      ),
      plan: plan,
    );
  }

  PlaybackPlan _playbackPlan(Map<String, dynamic> stream, String webRid) {
    final liveCore = stream['live_core_sdk_data'] is Map
        ? stream['live_core_sdk_data'] as Map
        : const {};
    final pullData = liveCore['pull_data'] is Map
        ? liveCore['pull_data'] as Map
        : const {};
    final options = pullData['options'] is Map
        ? pullData['options'] as Map
        : const {};
    final qualities = options['qualities'] as List? ?? const [];
    final rawStreamData = pullData['stream_data'];
    Map streamData = const {};
    if (rawStreamData is Map) {
      streamData = rawStreamData['data'] is Map
          ? rawStreamData['data'] as Map
          : rawStreamData;
    } else if (rawStreamData is String &&
        rawStreamData.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(rawStreamData) as Map;
        streamData = decoded['data'] is Map ? decoded['data'] as Map : decoded;
      } on FormatException {}
    }
    final sorted = qualities.whereType<Map>().toList()
      ..sort((a, b) => intValue(b['level']).compareTo(intValue(a['level'])));
    String selected = '';
    for (final quality in sorted) {
      final sdkKey = '${quality['sdk_key'] ?? ''}';
      final item = streamData[sdkKey];
      final main = item is Map && item['main'] is Map
          ? item['main'] as Map
          : const {};
      final hls = _secureStreamUrl(main['hls']);
      final flv = _secureStreamUrl(main['flv']);
      if (hls.isNotEmpty || flv.isNotEmpty) {
        selected = hls.isNotEmpty ? hls : flv;
        break;
      }
    }
    if (selected.isEmpty) {
      for (final value in streamData.values) {
        final main = value is Map && value['main'] is Map
            ? value['main'] as Map
            : const {};
        final hls = _secureStreamUrl(main['hls']);
        final flv = _secureStreamUrl(main['flv']);
        selected = hls.isNotEmpty ? hls : flv;
        if (selected.isNotEmpty) break;
      }
    }
    if (selected.isEmpty) {
      selected = _secureStreamUrl(stream['hls_pull_url']);
    }
    if (selected.isEmpty) {
      for (final mapKey in const ['hls_pull_url_map', 'flv_pull_url']) {
        final urls = stream[mapKey];
        if (urls is Map) {
          for (final url in urls.values) {
            selected = _secureStreamUrl(url);
            if (selected.isNotEmpty) break;
          }
        }
        if (selected.isNotEmpty) break;
      }
    }
    if (selected.isEmpty) throw const DouyinFailure('直播间没有返回可播放线路');
    return PlaybackPlan(
      url: selected,
      headers: {
        'User-Agent': DouyinSource.userAgent,
        'Referer': 'https://live.douyin.com/$webRid',
      },
      quality: sorted.isEmpty ? 0 : intValue(sorted.first['level']),
    );
  }

  String _secureStreamUrl(Object? value) {
    final uri = Uri.tryParse('${value ?? ''}');
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty)
      return '';
    return uri.toString();
  }

  SourceStatus status() {
    final lastPage = _pages.isEmpty ? null : _pages[_pages.keys.last];
    return SourceStatus.fromJson({
      'source': 'douyin-live',
      'count': _rows.length,
      'page': _latestPage('recommend'),
      'hasMore': lastPage?.hasMore ?? false,
      'updatedAt': _updated?.toIso8601String(),
      'stage': _stage,
      'running': _running,
      'operation': _operation.isEmpty ? 'catalog' : _operation,
      'error': _error,
      'startedAt': _started?.toIso8601String(),
      'finishedAt': _finished?.toIso8601String(),
      'health': {
        'state': _error.isNotEmpty
            ? 'failed'
            : _updated == null
            ? 'idle'
            : 'catalogOnly',
        'sample': _error.isNotEmpty ? _error : _stage,
      },
    });
  }
}
