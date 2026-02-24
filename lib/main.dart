import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'appsettings.dart';
import 'accounts.dart';
import 'cloak/cloak_wallet_manager.dart';
import 'cloak/cloak_db.dart';
import 'cloak/signature_provider.dart';
import 'router.dart' show initialLocation;
import 'store2.dart';
import 'main.reflectable.dart';
import './pages/utils.dart';

import 'init.dart';

const ZECUNIT = 100000000.0;
// ignore: non_constant_identifier_names
var ZECUNIT_DECIMAL = Decimal.parse('100000000');
const mZECUNIT = 100000;

// CLOAK uses 4 decimal precision (10000 smallest units = 1.0000 CLOAK)
const CLOAKUNIT = 10000.0;
// ignore: non_constant_identifier_names
var CLOAKUNIT_DECIMAL = Decimal.parse('10000');

final GlobalKey<NavigatorState> navigatorKey = new GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeReflectable();
  await restoreSettings();
  await initCoins();
  await restoreWindow();
  initNotifications();
  final prefs = await SharedPreferences.getInstance();
  final dbPath = await getDbPath();

  final pinSet = prefs.getBool('pin_set') ?? false;
  final walletFilePath = p.join(dbPath, 'cloak.wallet');
  final walletFileExists = File(walletFilePath).existsSync();

  bool walletReady = false;

  if (pinSet && walletFileExists) {
    // PIN is set and wallet exists — defer all DB/wallet init to PIN login page.
    // The PinLoginPage will init DB, load wallet, restore account, and start sync.
  } else if (pinSet && !walletFileExists) {
    // PIN set but no wallet file — unusual state. Go to splash for create/restore.
    // The PIN setup page will handle re-init.
  } else {
    // No PIN — initialize normally (unencrypted DB)
    await CloakWalletManager.init(dbPassword: appStore.dbPassword);

    try {
      if (walletFileExists) {
        await CloakWalletManager.loadWallet();
        await refreshCloakAccountsCache();
        walletReady = true;

        // Validate wallet configuration
        final validationErrors = await CloakWalletManager.validateWalletConfiguration();
        if (validationErrors.isNotEmpty) {
          appStore.cloakWalletValidationErrors = validationErrors;
        }

        // Start signature provider server for website auth
        await SignatureProvider.start();
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
          walletReady = true;
        }
      }
    } catch (e) {
      print('[init] Error initializing wallet: $e');
    }
  }

  // Set initial route BEFORE router is first accessed by runApp.
  if (Platform.environment['YW_INITIAL_ROUTE'] == null) {
    if (pinSet && walletFileExists) {
      initialLocation = '/pin_login';
    } else if (walletReady) {
      initialLocation = '/account';
    } else {
      initialLocation = '/splash';
    }
  }

  // Migrate coin index: CLOAK was 2 in multi-coin list, now 0
  final oldCoin = prefs.getInt('coin') ?? 0;
  if (oldCoin == 2) {
    await prefs.setInt('coin', 0);
  }
  // Migrate account_order_v1: transform "2:1" to "0:1"
  final order = prefs.getString('account_order_v1') ?? '';
  if (order.contains('2:')) {
    await prefs.setString('account_order_v1', order.replaceAll('2:', '0:'));
  }

  if (walletReady) {
    try {
      final a = ActiveAccount2.fromPrefs(prefs);
      if (a != null) {
        setActiveAccount(a.coin, a.id);
        aa.update(syncStatus2.latestHeight);
      }
    } catch (e) {
      print('[init] Error restoring account: $e');
    }
  }

  // Restore UI preferences (hide bottom nav, always-on-top)
  await initUiPrefs();

  if (walletReady) {
    // Ensure sync progress events are listened to on desktop startup
    initSyncListener();
    // Kick off a manual sync on the first frame
    if (!isMobile()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future(() => triggerManualSync());
      });
    }
  }

  runApp(App());
}

Future<void> restoreSettings() async {
  final prefs = await SharedPreferences.getInstance();
  appSettings = AppSettingsExtension.load(prefs);
  // Load persisted hide balances preference (defaults to false if absent)
  try {
    final hb = prefs.getBool('hide_balances');
    if (hb != null) {
      appStore.hideBalances = hb;
    }
  } catch (_) {}
}

// recoverDb removed — CLOAK uses wallet seed for recovery, not ZIP backup

final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
