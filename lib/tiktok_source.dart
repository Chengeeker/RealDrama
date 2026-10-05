import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TikTokSource {
  static const storage = FlutterSecureStorage();

  static String cookieKey(String profile) => 'source.cookie.tiktok.$profile';

  static String normalizeCookie(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const FormatException('请只粘贴 Cookie 请求头这一行');
    }
    final match = RegExp(
      r'^\s*(?:(?:cookie|tiktok|抖音)\s*[:：]\s*)?(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    final cookie = (match?.group(1) ?? value).trim();
    if (cookie.isEmpty ||
        cookie.length > 32768 ||
        RegExp(r'[^\x20-\x7e]').hasMatch(cookie)) {
      throw const FormatException('请粘贴单行完整 Cookie，不能包含其他请求头');
    }
    final parts = cookie
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.any((part) => part.indexOf('=') <= 0)) {
      throw const FormatException('Cookie 字段格式无效，请复制请求头中的完整值');
    }
    final fields = <String>[];
    var hasSession = false;
    for (final part in parts) {
      final separator = part.indexOf('=');
      final name = part.substring(0, separator).trim();
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
        throw const FormatException('Cookie 字段名格式无效');
      }
      final fieldValue = part.substring(separator + 1).trim();
      if (const {'sessionid', 'sessionid_ss'}.contains(name.toLowerCase()) &&
          fieldValue.isNotEmpty) {
        hasSession = true;
      }
      fields.add('$name=$fieldValue');
    }
    if (!hasSession) {
      throw const FormatException('未找到有效登录会话，请复制已登录网页请求中的完整 Cookie');
    }
    return fields.join('; ');
  }
}
