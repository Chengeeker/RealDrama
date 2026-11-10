import 'dart:async';

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:duanju_app/source_subscriptions.dart';
import 'package:duanju_app/source_subscriptions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

SourcePackage fixturePackage(String id, String origin) => SourcePackage(
  {'id': id, 'name': id, 'version': '1.0', 'capabilities': <String>[]},
  origin,
  'installed',
  [],
);

class SubscriptionFixture extends SourceSubscriptions {
  final packages = <SourcePackage>[
    fixturePackage('online', 'https://example.com/subscription.json'),
    fixturePackage('local', 'local:source.json'),
  ];
  final requests = <String>[];
  final installs = <String>[];
  Completer<int>? pendingUpdate;
  String? failedInstall;
  String digest = 'installed';

  @override
  List<SourcePackage> get installed => packages;
  @override
  SourcePackage? package(String id) =>
      packages.where((p) => p.id == id).firstOrNull;
  @override
  Future<void> open() async {}
  @override
  Future<int> updateAll() async {
    requests.add('all');
    return pendingUpdate == null ? 0 : await pendingUpdate!.future;
  }

  @override
  Future<SourceSubscriptionPreview> preview(String input) async {
    requests.add(input);
    return SourceSubscriptionPreview(input, '测试订阅列表', [
      for (final id in ['online', 'second'])
        {'id': id, 'name': id, 'version': '2.0', 'sha256': digest},
    ]);
  }

  @override
  Future<void> install(
    SourceSubscriptionPreview preview,
    Map<String, dynamic> entry,
  ) async {
    final id = entry['id'] as String;
    installs.add(id);
    if (id == failedInstall) throw const FormatException('模拟下载失败');
  }
}

void main() {
  Future<void> show(WidgetTester tester, SubscriptionFixture manager) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SourceSubscriptionsScreen(store: store, subscriptions: manager),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'one bulk action blocks repeats and reports failures without losing installed rows',
    (tester) async {
      final manager = SubscriptionFixture()..pendingUpdate = Completer<int>();
      await show(tester, manager);
      expect(find.text('一键检测更新'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('online · 1.0'), findsOneWidget);
      final action = find.byKey(const ValueKey('subscriptions-update-all'));
      await tester.tap(action);
      await tester.pump();
      expect(tester.widget<FilledButton>(action).onPressed, isNull);
      manager.pendingUpdate!.completeError(
        const FormatException('已更新 0 个站源；网络连接失败'),
      );
      await tester.pumpAndSettle();
      expect(manager.requests, ['all']);
      expect(find.textContaining('网络连接失败'), findsOneWidget);
      expect(find.text('online · 1.0'), findsOneWidget);
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
    },
  );

  testWidgets(
    'single update checks only its origin and avoids reinstalling identical content',
    (tester) async {
      final manager = SubscriptionFixture();
      await show(tester, manager);
      await tester.tap(
        find.byKey(const ValueKey('subscription-update-online')),
      );
      await tester.pumpAndSettle();
      expect(manager.requests, ['https://example.com/subscription.json']);
      expect(manager.installs, isEmpty);
      expect(find.text('此订阅已是最新版本'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subscription-update-local')),
        findsNothing,
      );
      expect(find.text('本地导入 · 需重新导入文件更新'), findsOneWidget);
    },
  );

  testWidgets('partial import retries only failed selections', (tester) async {
    final manager = SubscriptionFixture()..failedInstall = 'second';
    await show(tester, manager);
    await tester.tap(find.byKey(const ValueKey('subscriptions-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取站源列表'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('全选'));
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.ensureVisible(find.text('导入并订阅 2 个站源'));
    await tester.tap(find.text('导入并订阅 2 个站源'));
    await tester.pumpAndSettle();
    expect(manager.installs, ['online', 'second']);
    expect(find.text('导入并订阅 1 个站源'), findsOneWidget);
    manager.failedInstall = null;
    await tester.ensureVisible(find.text('导入并订阅 1 个站源'));
    await tester.tap(find.text('导入并订阅 1 个站源'));
    await tester.pumpAndSettle();
    expect(manager.installs, ['online', 'second', 'second']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('local-only subscriptions cannot claim an online update', (
    tester,
  ) async {
    final manager = SubscriptionFixture()..packages.removeAt(0);
    await show(tester, manager);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('subscriptions-update-all')),
          )
          .onPressed,
      isNull,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'subscription layout fits narrow screens with large text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = testStore(await SharedPreferences.getInstance());
        final manager = SubscriptionFixture();
        addTearDown(store.dispose);
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: SourceSubscriptionsScreen(
              store: store,
              subscriptions: manager,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('本地导入 · 需重新导入文件更新'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(Divider), findsNothing);
      },
    );
  }

  testWidgets(
    'source maintenance and feed preferences have separate destinations without dividers',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = testStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final repository = FixtureRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: SourceManagementSettingsScreen(
            repository: repository,
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-feed-preferences')), findsNothing);
      expect(find.byType(Divider), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeFeedSettingsScreen(repository: repository, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-feed-preferences')),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsNothing);
    },
  );
}
