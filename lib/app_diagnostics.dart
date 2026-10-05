import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class AppDiagnostics {
  static Future<void> _queue = Future.value();
  static const _fields = {
    'time',
    'level',
    'event',
    'source',
    'operation',
    'code',
    'httpStatus',
    'host',
    'stage',
    'exceptionType',
    'scriptLine',
    'attempt',
  };

  static void record(String event, Map<String, Object?> fields) {
    final safe = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      for (final entry in fields.entries)
        if (_fields.contains(entry.key) && entry.value != null)
          entry.key: entry.value,
    };
    _queue = _queue
        .then((_) async {
          final root = await getApplicationSupportDirectory();
          final file = File(path.join(root.path, 'logs', 'client.log'));
          await file.parent.create(recursive: true);
          if (await file.exists() && await file.length() > 512 * 1024) {
            final backup = File('${file.path}.1');
            if (await backup.exists()) await backup.delete();
            await file.rename(backup.path);
          }
          await file.writeAsString(
            '${jsonEncode(safe)}\n',
            mode: FileMode.append,
          );
        })
        .catchError((Object _) {});
  }

  static String playbackCode(String error) {
    final status = RegExp(
      r'\b(401|403|404|408|429|500|502|503|504)\b',
    ).firstMatch(error);
    if (status != null) return 'http_${status.group(1)}';
    final lower = error.toLowerCase();
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'timeout';
    }
    if (lower.contains('decoder') || lower.contains('codec')) return 'decoder';
    if (lower.contains('format') || lower.contains('demux')) {
      return 'media_format';
    }
    if (lower.contains('network') || lower.contains('connection')) {
      return 'connection';
    }
    return 'player_error';
  }

  static Future<Uint8List> export(String version) async {
    await _queue;
    final root = await getApplicationSupportDirectory();
    return Isolate.run(() => _readExport(root.path, version));
  }

  static Future<Uint8List> _readExport(String directory, String version) async {
    final events = <Map<String, dynamic>>[];
    for (final name in [
      'app.log.2',
      'app.log.1',
      'app.log',
      'client.log.1',
      'client.log',
    ]) {
      final file = File(path.join(directory, 'logs', name));
      if (!await file.exists()) continue;
      final handle = await file.open();
      String content;
      try {
        final length = await handle.length();
        final start = length > 1024 * 1024 ? length - 1024 * 1024 : 0;
        await handle.setPosition(start);
        content = utf8.decode(
          await handle.read(length - start),
          allowMalformed: true,
        );
        if (start > 0) content = content.substring(content.indexOf('\n') + 1);
      } finally {
        await handle.close();
      }
      for (final line in const LineSplitter().convert(content)) {
        try {
          final value = jsonDecode(line);
          if (value is Map<String, dynamic>) {
            events.add({
              for (final key in _fields)
                if (value.containsKey(key)) key: value[key],
            });
          }
        } catch (_) {}
      }
    }
    return Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'version': version,
          'platform': Platform.operatingSystem,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'events': events,
        }),
      ),
    );
  }
}
