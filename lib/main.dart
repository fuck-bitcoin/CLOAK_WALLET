import 'dart:async';
import 'dart:io' show Platform;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appsettings.dart';
import 'accounts.dart';
import 'cloak/cloak_wallet_manager.dart';
import 'cloak/cloak_db.dart';
import 'cloak/signature_provider.dart';
import 'store2.dart';
import 'main.reflectable.dart';
import 'coin/coins.dart';
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
  print("db path $dbPath");
  // Initialize CLOAK wallet
  for (var c in coins) {
    try {
      await CloakWalletManager.init(dbPassword: appStore.dbPassword);
      // Try to load existing CLOAK wallet if it exists
      if (await CloakWalletManager.walletExists()) {
        await CloakWalletManager.loadWallet();
        await refreshCloakAccountsCache();
        print('[init] CLOAK wallet loaded');

        // Validate wallet configuration - check for alias_authority mismatch
        final validationErrors = await CloakWalletManager.validateWalletConfiguration();
        if (validationErrors.isNotEmpty) {
          for (final error in validationErrors) {
            print('[init] WALLET VALIDATION ERROR: $error');
          }
          appStore.cloakWalletValidationErrors = validationErrors;
        }

        // Start signature provider server for website auth
        final started = await SignatureProvider.start();
        print('[init] Signature provider ${started ? "started" : "failed to start"}');
      } else {
        // Auto-restore if we have a seed in the DB but no wallet file
        final account = await CloakDb.getFirstAccount();
        if (account != null && account['seed'] != null && (account['seed'] as String).isNotEmpty) {
          print('[init] Wallet file missing but seed found - auto-restoring');
          await CloakWalletManager.restoreWallet(
            account['name'] as String,
            account['seed'] as String,
          );
          await CloakWalletManager.loadWallet();
          await refreshCloakAccountsCache();
          print('[init] CLOAK wallet auto-restored from seed');
        } else {
          print('[init] No CLOAK wallet found');
        }
      }
    } catch (_) {}
  }
  // Restore active account so the wallet shows immediately without a splash route
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

  try {
    final a = ActiveAccount2.fromPrefs(prefs);
    print('[init] fromPrefs returned: $a (id=${a?.id})');
    if (a != null) {
      print('[init] Setting active account: coin=${a.coin}, id=${a.id}');
      setActiveAccount(a.coin, a.id);
      aa.update(syncStatus2.latestHeight);
    } else {
      print('[init] No active account found - should show welcome screen');
    }
    print('[init] aa.id is now: ${aa.id}, aa.coin: ${aa.coin}');
  } catch (e) {
    print('[init] Error restoring account: $e');
  }
  // Restore UI preferences (hide bottom nav, always-on-top)
  await initUiPrefs();
  // Ensure sync progress events are listened to on desktop startup (no Splash route)
  initSyncListener();
  // Ensure desktop instances begin syncing immediately on launch.
  // We kick off a manual sync on the first frame to bypass the
  // "auto > 1 month behind" gating and then resume the normal
  // 15s auto-sync cadence.
  if (!isMobile()) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future(() => triggerManualSync());
    });
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
