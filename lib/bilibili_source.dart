import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BilibiliSource {
  static const storage = FlutterSecureStorage();

  static String cookieKey(String profile) => 'bilibili.cookie.$profile';

  static Future<String?> readCookie(String profile) =>
      storage.read(key: cookieKey(profile));

  static String normalizeCookie(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const FormatException('请只粘贴 Cookie 请求头这一行');
    }
    final match = RegExp(
      r'^\s*cookie\s*:\s*(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(value);
    final cookie = (match?.group(1) ?? value).trim();
    if (cookie.isEmpty ||
        cookie.length > 32768 ||
        cookie.contains('\n') ||
        cookie.contains('\r') ||
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
    final fields = <String, String>{};
    for (final part in parts) {
      final separator = part.indexOf('=');
      final name = part.substring(0, separator).trim();
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name) ||
          fields.containsKey(name)) {
        throw const FormatException('Cookie 字段名重复或格式无效');
      }
      fields[name] = part.substring(separator + 1).trim();
    }
    if (fields['SESSDATA']?.isNotEmpty != true) {
      throw const FormatException('未找到 SESSDATA，请复制已登录网页请求中的 Cookie');
    }
    return fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }
}
