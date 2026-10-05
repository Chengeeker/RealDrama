import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> create([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(Map.of(initial));
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('a new install only shows Red Fruit by default', () async {
    final store = await create();
    expect(store.sources.map((source) => source.id), ['hongguo']);
    expect(store.allowsSource('hongguo'), isTrue);
    expect(store.allowsSource('dsd'), isFalse);
  });

  test(
    'an explicitly saved empty hidden list keeps all sources visible',
    () async {
      final store = await create({'hiddenSources': jsonEncode([])});
      expect(
        store.sources.map((source) => source.id),
        SourceSite.values.map((source) => source.id),
      );
      expect(store.allowsSource('dsd'), allSourcesEnabled);
    },
  );

  test('a legacy selected source stays visible across a restart', () async {
    final store = await create({'source': 'dsd'});
    expect(
      store.sources.map((source) => source.id).toSet(),
      allSourcesEnabled ? {'hongguo', 'dsd'} : {'hongguo'},
    );
    expect(store.source, allSourcesEnabled ? 'dsd' : 'hongguo');
    final restarted = testStore(store.preferences);
    addTearDown(restarted.dispose);
    expect(restarted.source, allSourcesEnabled ? 'dsd' : 'hongguo');
  });

  test(
    'a hidden source stays hidden after restart and backup restore',
    () async {
      final store = await create();
      await store.setSourceVisible('dsd', true);
      await store.setSourceVisible('hongguo', false);
      expect(store.allowsSource('hongguo'), isFalse);

      final restarted = testStore(store.preferences);
      addTearDown(restarted.dispose);
      expect(restarted.allowsSource('hongguo'), isFalse);
      await restarted.setSourceVisible('hongguo', true);
      expect(restarted.allowsSource('hongguo'), isTrue);

      final backup = await store.exportBackup();
      await restarted.importBackup(backup);
      expect(restarted.allowsSource('hongguo'), isFalse);
    },
    skip: !allSourcesEnabled,
  );

  test(
    'a legacy profile without visibility settings uses the new default',
    () async {
      final store = await create({
        ...await gatePreferences(),
        'profiles': jsonEncode([
          LocalProfile(
            id: 'default',
            name: '管理员',
            admin: true,
            salt: '0' * 32,
            pinHash: '1' * 64,
          ).toJson(),
          const LocalProfile(
            id: 'viewer',
            name: '旧用户',
            sources: ['dsd'],
            download: false,
          ).toJson(),
        ]),
        'activeProfile': 'viewer',
      });
      expect(store.configurationError, isNull);
      expect(store.canDownload, isFalse);
      expect(store.sources.map((source) => source.id), ['hongguo']);
      expect(store.allowsSource('hongguo'), isTrue);
      expect(store.allowsSource('dsd'), isFalse);
    },
  );

  test('each profile keeps its own hidden sources', () async {
    final store = await create({
      'forceLogin': false,
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(id: 'viewer', name: '其他用户').toJson(),
      ]),
    });
    await store.setSourceVisible('dsd', true);
    await store.setSourceVisible('hongguo', false);
    await store.switchProfile('viewer');
    expect(store.allowsSource('hongguo'), isTrue);
    expect(store.allowsSource('dsd'), isFalse);
    await store.setSourceVisible('dsd', true);
    await store.setSourceVisible('hongguo', false);
    expect(store.allowsSource('hongguo'), isFalse);
    expect(store.allowsSource('dsd'), isTrue);
  }, skip: !allSourcesEnabled);

  test('the last visible source cannot be hidden', () async {
    final store = await create();
    for (final source in SourceSite.values.skip(1)) {
      await store.setSourceVisible(source.id, false);
    }
    await expectLater(
      store.setSourceVisible('hongguo', false),
      throwsStateError,
    );
    expect(store.allowsSource('hongguo'), isTrue);
  });
}
