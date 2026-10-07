import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'models.dart';

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

class DouyinCommentEmoji {
  const DouyinCommentEmoji({required this.name, required this.url});

  final String name;
  final String url;
}

class DouyinCommentPage {
  const DouyinCommentPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
    required this.total,
    this.emojis = const [],
  });

  final List<DouyinComment> items;
  final String cursor;
  final bool hasMore;
  final int total;
  final List<DouyinCommentEmoji> emojis;
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
  static const storage = FlutterSecureStorage();
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
}
