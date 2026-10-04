import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core_bridge.dart';
import 'source_subscriptions.dart';
import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'app_haptics.dart';
import 'home_screen.dart';
import 'local_store.dart';
import 'profiles_screen.dart';
import 'media_library.dart';
import 'package_smoke.dart';
import 'lan_controller.dart';
import 'player_screen.dart';
import 'widgets.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'dart_simple_live / Douyin request signer',
    ], await rootBundle.loadString('assets/licenses/douyin_LICENSE.txt'));
  });
  LicenseRegistry.addLicense(() async* {
    for (final name in ['goja', 'cascadia']) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/licenses/${name}_LICENSE.txt'));
    }
  });
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  if (!Platform.isAndroid) MediaKit.ensureInitialized();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  final device = await AppDevice.detect();
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  final navigator = GlobalKey<NavigatorState>();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;

  int _sourceRevision = -1;
  void _sourcesChanged() {
    final subscriptions = SourceSubscriptions.instance;
    if (_sourceRevision == subscriptions.revision) return;
    _sourceRevision = subscriptions.revision;
    store?.refreshInstalledSources();
  }

  @override
  void dispose() {
    SourceSubscriptions.instance.removeListener(_sourcesChanged);
    WidgetsBinding.instance.removeObserver(this);
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    store?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() {
      error = null;
    });
    try {
      await SourceSubscriptions.instance.open();
      final startup = await Future.wait<Object>([
        SharedPreferences.getInstance(),
        repository.initialize().then((_) => true),
      ]);
      final preferences = startup.first as SharedPreferences;
      if (mounted) {
        setState(() {
          store = LocalStore(preferences);
          repository.access = store;
          SourceSubscriptions.instance.addListener(_sourcesChanged);
          MediaLibrary.attach(repository, store!);
          LanController.current?.dispose();
          final link = LanController(
            repository,
            store!,
            kind: device.television
                ? 'tv'
                : Platform.isWindows
                ? 'computer'
                : 'phone',
          );
          LanController.current = link;
          link.openPlayback = (request) async {
            final epoch = request.profileEpoch;
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                !link.receiving ||
                store!.profileEpoch != epoch ||
                !store!.allowsSource(request.detail.drama.source)) {
              throw StateError('当前用户不能接收播放');
            }
            await link.playbackHost?.stop();
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                store!.profileEpoch != epoch ||
                !link.receiving) {
              throw StateError('播放接收已取消');
            }
            final navigation = navigator.currentState;
            if (navigation == null) throw StateError('接收设备界面尚未就绪');
            unawaited(
              navigation.pushAndRemoveUntil<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    detail: request.detail,
                    initialIndex: request.index,
                    initialPosition: request.position,
                    repository: repository,
                    store: store!,
                    handoff: request,
                  ),
                ),
                (route) => route.isFirst,
              ),
            );
          };
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
    navigatorKey: navigator,
  );
}

class DuanjuApp extends StatefulWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<DuanjuApp> createState() => _DuanjuAppState();
}

class _DuanjuAppState extends State<DuanjuApp> {
  LocalStore? get store => widget.store;
  AppRepository get repository => widget.repository;
  bool get television => widget.television;
  String get version => widget.version;
  String? get bootstrapError => widget.bootstrapError;
  VoidCallback? get onRetry => widget.onRetry;
  GlobalKey<NavigatorState>? get navigatorKey => widget.navigatorKey;
  Object? _appearance;

  Object get _currentAppearance => (
    store?.themeMode,
    store?.themeSeed,
    store?.dynamicColor,
    store?.fontWeightAdjustment,
    store?.hapticFeedback,
    store?.locked,
    store?.profileEpoch,
  );

  @override
  void initState() {
    super.initState();
    _appearance = _currentAppearance;
    store?.addListener(_storeChanged);
  }

  @override
  void didUpdateWidget(DuanjuApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store?.removeListener(_storeChanged);
      store?.addListener(_storeChanged);
    }
    _appearance = _currentAppearance;
  }

  void _storeChanged() {
    final appearance = _currentAppearance;
    if (appearance == _appearance) return;
    setState(() => _appearance = appearance);
  }

  @override
  void dispose() {
    store?.removeListener(_storeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _application();

  Widget _application() {
    AppHaptics.enabled = store?.hapticFeedback ?? true;
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        navigatorKey: navigatorKey,
        title: appName,
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.lightFor(
          seed: store?.themeSeed ?? 'coral',
          dynamicScheme: store?.dynamicColor == true ? lightDynamic : null,
          fontWeightAdjustment: store?.fontWeightAdjustment ?? 0,
        ),
        darkTheme: AppTheme.darkFor(
          seed: store?.themeSeed ?? 'coral',
          dynamicScheme: store?.dynamicColor == true ? darkDynamic : null,
          fontWeightAdjustment: store?.fontWeightAdjustment ?? 0,
        ),
        themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
        builder: (context, child) {
          final tv = television;
          final theme = Theme.of(context);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(theme.brightness),
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: AppOrientationScope(
                television: tv,
                child: AppLayout(
                  television: tv,
                  version: version,
                  child: Theme(
                    data: tv ? televisionTheme(theme) : theme,
                    child: Shortcuts(
                      shortcuts: const {
                        SingleActivator(
                          LogicalKeyboardKey.select,
                          includeRepeats: false,
                        ): ActivateIntent(),
                        SingleActivator(
                          LogicalKeyboardKey.gameButtonA,
                          includeRepeats: false,
                        ): ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.goBack):
                            DismissIntent(),
                      },
                      child: FocusTraversalGroup(child: child!),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        home: store != null
            ? store!.locked
                  ? ProfilesScreen(store: store!, locked: true)
                  : HomeScreen(
                      key: ValueKey(
                        'profile-${store!.profile.id}-${store!.profileEpoch}',
                      ),
                      repository: repository,
                      store: store!,
                    )
            : bootstrapError == null
            ? const Scaffold()
            : Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_circle_fill_rounded,
                          color: Color(0xFFFF765F),
                          size: 72,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          bootstrapError ?? '正在打开$appName',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18),
                        ),
                        const SizedBox(height: 24),
                        if (bootstrapError == null)
                          const AppLoadingIndicator()
                        else
                          FilledButton(
                            onPressed: onRetry,
                            child: const Text('重新打开'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
