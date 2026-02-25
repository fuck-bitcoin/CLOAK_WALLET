import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloak_wallet/router.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import '../../accounts.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/cloak_db.dart';
import '../../cloak/signature_provider_state.dart';
import 'accounts/send.dart';
import 'cloak/auth_request_sheet.dart';
import 'settings.dart';
import 'utils.dart';
import 'utils.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../settings.pb.dart';
import '../store2.dart';
import '../init.dart';

class SplashPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _SplashState();
}

class _SplashState extends State<SplashPage> {
  late final s = S.of(context);
  final progressKey = GlobalKey<_LoadProgressState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future(() async {
        // Ensure window size/visibility is set once, so splash and main share the same window
        await restoreWindow();
        GetIt.I.registerSingleton<S>(S.of(context));
        if (!appSettings.hasMemo()) appSettings.memo = s.sendFrom(APP_NAME);
        // await _setupMempool();
        final applinkUri = await _registerURLHandler();
        final quickAction = await _registerQuickActions();
        _initWallets();
        await _restoreActive();
        initSyncListener();
        // _initForegroundTask();
        _initBackgroundSync();
        _initAccel();
        final protectOpen = appSettings.protectOpen;
        if (protectOpen) {
          await authBarrier(context);
        }
        appStore.initialized = true;
        if (applinkUri != null)
          handleUri(applinkUri);
        else if (quickAction != null)
          handleQuickAction(context, quickAction);
        else
          GoRouter.of(context).go('/account');
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // Invisible: we now start directly at /account; keep logic for background init if routed here
    return const SizedBox.shrink();
  }

  Future<Uri?> _registerURLHandler() async {
    _setProgress(0.3, 'Register Payment URI handlers');
    return await registerURLHandler();

    // TODO
    // if (Platform.isWindows) {
    //   for (var c in coins) {
    //     registerProtocolHandler(c.currency, arguments: ['%s']);
    //   }
    // }
  }

  Future<String?> _registerQuickActions() async {
    _setProgress(0.4, 'Register App Launcher actions');
    String? launchPage;
    if (isMobile()) {
      final quickActions = QuickActions();
      await quickActions.initialize((quick_action) {
        launchPage = quick_action;
      });
      Future.microtask(() {
        final s = S.of(this.context);
        List<ShortcutItem> shortcuts = [];
        for (var c in coins) {
          final ticker = c.ticker;
          shortcuts.add(ShortcutItem(
              type: '${c.coin}.receive',
              localizedTitle: s.receive(ticker),
              icon: 'receive'));
          shortcuts.add(ShortcutItem(
              type: '${c.coin}.send',
              localizedTitle: s.sendCointicker(ticker),
              icon: 'send'));
        }
        quickActions.setShortcutItems(shortcuts);
      });
    }
    return launchPage;
  }

  void _initWallets() async {
    for (var c in coins) {
      final coin = c.coin;
      _setProgress(0.5 + 0.1 * coin, 'Initializing ${c.ticker}');

      try {
        await CloakWalletManager.init(dbPassword: appStore.dbPassword);
        if (await CloakWalletManager.walletExists()) {
          await CloakWalletManager.loadWallet();
          await refreshCloakAccountsCache();
        } else {
          // Auto-restore if we have a seed in the DB but no wallet file
          final account = await CloakDb.getFirstAccount();
          if (account != null && account['seed'] != null && (account['seed'] as String).isNotEmpty) {
            await CloakWalletManager.restoreWallet(
              account['name'] as String,
              account['seed'] as String,
            );
            await CloakWalletManager.loadWallet();
            await refreshCloakAccountsCache();
          }
        }
      } catch (e) {
        print('[Splash] Error initializing wallet: $e');
        // Continue to next coin — don't crash splash screen
      }
    }
  }

  Future<void> _restoreActive() async {
    _setProgress(0.8, 'Load Active Account');
    final prefs = await SharedPreferences.getInstance();
    final a = ActiveAccount2.fromPrefs(prefs);
    a?.let((a) {
      setActiveAccount(a.coin, a.id);
      aa.update(syncStatus2.latestHeight);
    });
  }

  _initAccel() {
    // Disabled tilt-to-hide balance feature; eyeball toggle controls visibility now.
    return;
  }

  void _setProgress(double progress, String message) {
    progressKey.currentState!.setValue(progress, message);
  }

  _initBackgroundSync() {
    if (!isMobile()) return;
    logger.d('${appSettings.backgroundSync}');

    Workmanager().initialize(
      backgroundSyncDispatcher,
    );
    if (appSettings.backgroundSync != 0)
      Workmanager().registerPeriodicTask(
        'sync',
        'background-sync',
        constraints: Constraints(
          networkType: appSettings.backgroundSync == 1
              ? NetworkType.unmetered
              : NetworkType.connected,
        ),
      );
    else
      Workmanager().cancelAll();
  }
}

class LoadProgress extends StatefulWidget {
  LoadProgress({Key? key}) : super(key: key);

  @override
  State<LoadProgress> createState() => _LoadProgressState();
}

class _LoadProgressState extends State<LoadProgress> {
  var _value = 0.0;
  String _message = "";

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = S.of(context);
    final textTheme = t.textTheme;
    return Scaffold(
        body: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Image.asset('assets/icon.png', height: 64),
                  SizedBox(height: 24),
                  Text(s.loading, style: textTheme.headlineMedium),
                  SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: LinearProgressIndicator(value: _value),
                  ),
                  SizedBox(height: 12),
                  Text(_message, style: textTheme.labelMedium, textAlign: TextAlign.center),
                ])));
  }

  void setValue(double v, String message) {
    setState(() {
      _value = v;
      _message = message;
    });
  }
}

StreamSubscription? subUniLinks;

bool setActiveAccountOf(int coin) {
  final coinSettings = CoinSettingsExtension.load(coin);
  final id = coinSettings.account;
  if (id == 0) return false;
  setActiveAccount(coin, id);
  return true;
}

void handleUri(Uri uri) {
  final scheme = uri.scheme;
  final host = uri.host;

  // Handle authentication deep links from mobile browsers
  // Format: cloak://auth?origin=app.cloak.today&callback=https://...
  // Format: cloak://login?origin=app.cloak.today
  if (scheme == 'cloak' && (host == 'auth' || host == 'login' || uri.path == '/auth' || uri.path == '/login')) {
    _handleAuthDeepLink(uri);
    return;
  }

  // Handle payment URIs (original behavior)
  try {
    final coinDef = coins.firstWhere((c) => c.currency == scheme);
    final coin = coinDef.coin;
    if (setActiveAccountOf(coin)) {
      SendContext? sc = SendContext.fromPaymentURI(uri.toString());
      final context = rootNavigatorKey.currentContext!;
      GoRouter.of(context).go('/account/quick_send', extra: sc);
    }
  } catch (e) {
    logger.w('Unknown URI scheme: $scheme');
  }
}

/// Handle authentication deep links from mobile browsers
/// This allows app.cloak.today to authenticate via deep link on Android
void _handleAuthDeepLink(Uri uri) {
  final origin = uri.queryParameters['origin'] ?? 'Unknown';
  final callback = uri.queryParameters['callback'];
  final esr = uri.queryParameters['esr'];

  // Check if wallet is view-only
  if (CloakWalletManager.isViewOnly) {
    logger.w('Auth request rejected: view-only wallet');
    if (callback != null) {
      _redirectWithError(callback, 'View-only wallet cannot sign');
    }
    return;
  }

  // Create a SignatureRequest for the approval UI
  final requestId = 'deeplink:${DateTime.now().millisecondsSinceEpoch}';
  final request = SignatureRequest(
    id: requestId,
    type: esr != null ? SignatureRequestType.sign : SignatureRequestType.login,
    origin: origin,
    params: {
      'origin': origin,
      'callback': callback,
      'esr': esr,
      'deeplink': true,
    },
    timestamp: DateTime.now(),
    status: SignatureRequestStatus.pending,
  );

  // Store callback for after approval
  _pendingDeepLinkCallbacks[requestId] = callback;

  // Show the auth request sheet
  final context = rootNavigatorKey.currentContext;
  if (context != null) {
    // Navigate to account first if not there
    GoRouter.of(context).go('/account');
    // Then show auth sheet after a short delay
    Future.delayed(const Duration(milliseconds: 300), () {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) {
        showAuthRequestSheet(ctx, request);
      }
    });
  }
}

/// Pending deep link callbacks, keyed by request ID
final Map<String, String?> _pendingDeepLinkCallbacks = {};

/// Get and remove a pending callback
String? getDeepLinkCallback(String requestId) {
  return _pendingDeepLinkCallbacks.remove(requestId);
}

/// Redirect to callback URL with error
void _redirectWithError(String callback, String error) async {
  final uri = Uri.parse(callback).replace(queryParameters: {
    ...Uri.parse(callback).queryParameters,
    'error': error,
  });
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    logger.e('Failed to redirect to callback: $e');
  }
}

/// Redirect to callback URL with success result
Future<void> redirectWithSuccess(String callback, Map<String, String> result) async {
  final uri = Uri.parse(callback).replace(queryParameters: {
    ...Uri.parse(callback).queryParameters,
    ...result,
  });
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    logger.e('Failed to redirect to callback: $e');
  }
}

Future<Uri?> registerURLHandler() async {
  if (Platform.isLinux) return null;
  final _appLinks = AppLinks();

  subUniLinks = _appLinks.uriLinkStream.listen((uri) {
    logger.d(uri);
    handleUri(uri);
  });

  final uri = await _appLinks.getInitialAppLink();
  return uri;
}

void handleQuickAction(BuildContext context, String quickAction) {
  final t = quickAction.split(".");
  final coin = int.parse(t[0]);
  final shortcut = t[1];
  setActiveAccountOf(coin);
  switch (shortcut) {
    case 'receive':
      GoRouter.of(context).go('/account/pay_uri');
    case 'send':
      GoRouter.of(context).go('/account/quick_send');
  }
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  if (!appStore.initialized) return;
  Workmanager().executeTask((task, inputData) async {
    logger.i("Native called background task: $task");
    await syncStatus2.sync(false, auto: true);
    return true;
  });
}
