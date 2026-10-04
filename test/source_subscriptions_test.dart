import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:duanju_app/subscription_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/source_subscriptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('imports packages through serial queue and restores registry', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rd-subscriptions-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => directory.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    final manager = SourceSubscriptions();
    for (final id in ['source-one', 'source-two']) {
      final file = File('${directory.path}/$id.json');
      await file.writeAsString(
        jsonEncode({
          'schema': 1,
          'api': 1,
          'engine': 'javascript-generator-v1',
          'id': id,
          'name': id,
          'version': '0.1.0',
          'domains': ['example.com'],
          'capabilities': ['catalog'],
          'program': 'function* run() { return {}; }',
        }),
      );
      await manager.importLocal(file.path);
    }
    expect(manager.installed.map((p) => p.id), ['source-one', 'source-two']);
    final restored = SourceSubscriptions();
    await restored.open();
    expect(restored.installed.map((p) => p.id), ['source-one', 'source-two']);
    expect(restored.problems, isEmpty);
  });
  test('reads catalog cache without sending runtime futures', () async {
    final directory = await Directory.systemTemp.createTemp('rd-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => directory.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    final cacheDirectory = await Directory(
      '${directory.path}/source-subscriptions',
    ).create();
    final digest = sha256.convert(utf8.encode('null:source-one:'));
    await File('${cacheDirectory.path}/catalog-$digest.json').writeAsString(
      jsonEncode({
        'items': [
          {'id': 'source-one:1', 'source': 'source-one', 'title': 'Test'},
        ],
        'page': 3,
        'hasMore': true,
      }),
    );

    final runtime = SubscriptionRuntime(() => null);

    final result = await runtime
        .loadCached('source-one', '')
        .timeout(const Duration(seconds: 5));

    expect(result.items.single.id, 'source-one:1');
    expect(result.page, 3);
    expect(result.hasMore, isTrue);
  });
}
