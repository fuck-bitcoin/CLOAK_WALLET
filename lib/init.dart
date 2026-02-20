import 'dart:io';

import 'accounts.dart';
import 'appsettings.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'theme/zashi_tokens.dart';

import 'coin/coins.dart';
import 'generated/intl/messages.dart';
import 'main.dart';
import 'pages/utils.dart';
import 'router.dart';

Future<void> initCoins() async {
  final dbPath = await getDbPath();
  Directory(dbPath).createSync(recursive: true);
  for (var coin in coins) {
    coin.init(dbPath);
  }
}

Future<void> restoreWindow() async {
  if (isMobile()) return;
  await windowManager.ensureInitialized();
  // Prevent the window from being closed by the OS implicitly (Wayland/WM quirks)
  // so the app doesn't exit unexpectedly when detached/backgrounded.
  await windowManager.setPreventClose(true);
  // Prevent maximize via snap gestures, title bar double-click, etc.
  await windowManager.setMaximizable(false);
  await windowManager.setFullScreen(false);

  final prefs = await SharedPreferences.getInstance();
  final width = prefs.getDouble('width');
  final height = prefs.getDouble('height');
  // Optional phone preview override via env, e.g. YW_PHONE_PREVIEW=iphone13
  Size? previewSize;
  final preview = Platform.environment['YW_PHONE_PREVIEW']?.toLowerCase();
  if (preview == 'iphone13') {
    previewSize = const Size(390, 844);
  } else if (preview == 'iphone14pro') {
    previewSize = const Size(393, 852);
  }

  // Get logical screen size for percentage-based default height
  double logicalScreenHeight = 900.0; // fallback
  try {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    logicalScreenHeight = view.physicalSize.height / view.devicePixelRatio;
  } catch (_) {}
  // Leave room for taskbar/panel
  final maxScreenHeight = (logicalScreenHeight * 0.90).clamp(600.0, 820.0);

  // Default: 67% of screen height so "See all >" and below are visible
  final defaultHeight = (logicalScreenHeight * 0.67).clamp(600.0, maxScreenHeight);
  final defaultSize = Size(390, defaultHeight);
  final desired = previewSize ??
      (width != null && height != null ? Size(width, height) : defaultSize);
  // Clamp to a reasonable phone preview range; if preview is set, honor exact height
  final clamped = previewSize != null
      ? Size((desired.width).clamp(320.0, 430.0).toDouble(), previewSize.height.clamp(600.0, maxScreenHeight))
      : Size(
          (desired.width).clamp(320.0, 430.0).toDouble(),
          (desired.height).clamp(600.0, maxScreenHeight).toDouble(),
        );
  WindowOptions windowOptions = WindowOptions(
    center: true,
    size: clamped,
    backgroundColor: const Color(0xFF121212),
    skipTaskbar: false,
    titleBarStyle:
        Platform.isMacOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setSize(clamped);
    await windowManager.setMaximizable(false);
    await windowManager.show();
    await windowManager.focus();
    // Nudge to front on some compositors
    await windowManager.setAlwaysOnTop(true);
    await Future.delayed(const Duration(milliseconds: 150));
    if (!alwaysOnTop.value) await windowManager.setAlwaysOnTop(false);
    // Persist the clamped size so subsequent launches use the phone-like height
    await prefs.setDouble('width', clamped.width);
    await prefs.setDouble('height', clamped.height);
  });
  // Some Wayland compositors ignore initial focus; try again after first frame
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
      await Future.delayed(const Duration(milliseconds: 400));
      if (!alwaysOnTop.value) await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
  });
  windowManager.addListener(_OnWindow());
}

class _OnWindow extends WindowListener {
  @override
  void onWindowResized() async {
    final s = await windowManager.getSize();
    final prefs = await SharedPreferences.getInstance();
    prefs.setDouble('width', s.width);
    prefs.setDouble('height', s.height);
  }

  @override
  void onWindowMaximize() async {
    // Immediately unmaximize — we don't want fullscreen/maximized state
    await windowManager.unmaximize();
  }

  @override
  void onWindowClose() async {
    // On desktop, prevent-close is enabled. Intercept the close event
    // so the app does not immediately shut down when backgrounded.
    await windowManager.hide();
  }
}

void initNotifications() {
  AwesomeNotifications().initialize(
      'resource://drawable/res_notification',
      [
        NotificationChannel(
          channelKey: APP_NAME,
          channelName: APP_NAME,
          channelDescription: 'Notification channel for $APP_NAME',
          defaultColor: Color(0xFFB3F0FF),
          ledColor: Colors.white,
        )
      ],
      debug: false);
}

class App extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _AppState();
}

class _AppState extends State<App> {
  // Cache FlexThemeData — only recompute when palette/dark-mode actually changes.
  // FlexThemeData.dark/light() + copyWith() is expensive (resolves all M3 component
  // themes). Without caching, every Observer rebuild (triggered by settingsSeqno on
  // each sync cycle) recomputes the full ThemeData even when nothing theme-related changed.
  ThemeData? _cachedTheme;
  String? _cachedPaletteName;
  bool? _cachedDarkMode;

  // Zashi extensions are constant — compute once
  static final _zashiLight = ZashiThemeExt(
    tileRadius: 22,
    tilePadding: 14,
    quickGradTop: const Color(0xFFF4F4F4),
    quickGradBottom: const Color(0xFFE7E7E7),
    quickBorderColor: const Color(0x22000000),
    balanceAmountColor: const Color(0xFFBDBDBD),
  );
  static final _zashiDark = ZashiThemeExt(
    tileRadius: 22,
    tilePadding: 14,
    quickGradTop: const Color(0xFF3A3737),
    quickGradBottom: const Color(0xFF232121),
    quickBorderColor: const Color(0x33000000),
    balanceAmountColor: const Color(0xFFBDBDBD),
  );

  // Env-based preview size (only depends on environment, never changes at runtime)
  static final Size? _previewSize = () {
    final p = Platform.environment['YW_PHONE_PREVIEW']?.toLowerCase();
    if (p == 'iphone13') return const Size(390, 844);
    if (p == 'iphone14pro') return const Size(393, 852);
    return null;
  }();

  ThemeData _resolveTheme() {
    final paletteName = appSettings.palette.name;
    final isDark = appSettings.palette.dark;
    if (_cachedTheme != null &&
        paletteName == _cachedPaletteName &&
        isDark == _cachedDarkMode) {
      return _cachedTheme!;
    }
    FlexScheme scheme;
    try {
      scheme = FlexScheme.values.byName(paletteName);
    } catch (_) {
      scheme = FlexScheme.mandyRed;
    }
    final baseTheme = isDark
        ? FlexThemeData.dark(scheme: scheme)
        : FlexThemeData.light(scheme: scheme);
    _cachedTheme = baseTheme.copyWith(
      useMaterial3: true,
      appBarTheme: baseTheme.appBarTheme.copyWith(
        scrolledUnderElevation: 0,
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: MaterialStateColor.resolveWith(
          (_) => baseTheme.highlightColor,
        ),
      ),
    );
    _cachedPaletteName = paletteName;
    _cachedDarkMode = isDark;
    return _cachedTheme!;
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      try {
        aaSequence.settingsSeqno;
        final theme = _resolveTheme();

      return MaterialApp.router(
        locale: Locale(appSettings.language),
        title: APP_NAME,
        debugShowCheckedModeBanner: false,
        theme: theme.copyWith(extensions: [_zashiLight]),
        darkTheme: theme.copyWith(extensions: [_zashiDark]),
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        scrollBehavior: _DesktopTouchScrollBehavior(),
        builder: (context, child) {
          final size = _previewSize;
          if (size != null && !isMobile() && child != null) {
            final mq = MediaQuery.of(context);
            final mqData = mq.copyWith(
              size: size,
              // Keep other metrics; we only force logical width/height
            );
            return Center(
              child: MediaQuery(
                data: mqData,
                child: SizedBox(width: size.width, height: size.height, child: child),
              ),
            );
          }
          return child ?? const SizedBox.shrink();
        },
        localizationsDelegates: [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FormBuilderLocalizations.delegate,
        ],
        supportedLocales: [
          Locale('en'),
          Locale('es'),
          Locale('pt'),
          Locale('fr'),
        ],
        routerConfig: router,
      );
      } catch (e, st) {
        // Surface the real error to the console instead of the generic Observer message
        debugPrint('Observer build error (App root): ' + e.toString() + '\n' + st.toString());
        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('Something went wrong starting the app.'),
            ),
          ),
        );
      }
    });
  }
}

class _DesktopTouchScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}
