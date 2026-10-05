import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class YouTubeSource {
  static const storage = FlutterSecureStorage();

  static String cookieKey(String profile) => 'source.cookie.youtube.$profile';

  static String normalizeCookie(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const FormatException('请只输入 Cookie 请求头这一行');
    }
    final match = RegExp(
      r'^\s*(?:(?:cookie|youtube)\s*[:：]\s*)?(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    final cookie = (match?.group(1) ?? value).trim();
    if (cookie.isEmpty ||
        cookie.length > 32768 ||
        RegExp(r'[^\x20-\x7e]').hasMatch(cookie)) {
      throw const FormatException('Cookie 格式无效，请输入单行请求头值');
    }
    final parts = cookie
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.any((part) => part.indexOf('=') <= 0)) {
      throw const FormatException('Cookie 字段格式无效');
    }
    final fields = <String>[];
    var hasSapisid = false;
    for (final part in parts) {
      final separator = part.indexOf('=');
      final name = part.substring(0, separator).trim();
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
        throw const FormatException('Cookie 字段名格式无效');
      }
      final value = part.substring(separator + 1).trim();
      if (name == 'SAPISID' && value.isNotEmpty) hasSapisid = true;
      fields.add('$name=$value');
    }
    if (!hasSapisid) {
      throw const FormatException('Cookie 中缺少 SAPISID 授权字段');
    }
    return fields.join('; ');
  }
}
