import 'dart:convert';
import 'dart:math' as m;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';
import 'package:window_manager/window_manager.dart';

import 'cloak/cloak_wallet_manager.dart';
import 'settings.pb.dart';
import 'coin/coins.dart';

var appSettings = AppSettings();
var coinSettings = CoinSettings();

/// Whether the bottom navigation bar is hidden.
final hideBottomNav = ValueNotifier<bool>(false);

/// Whether the window stays on top of other windows.
final alwaysOnTop = ValueNotifier<bool>(false);

/// Call once at startup after SharedPreferences is available.
Future<void> initUiPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  hideBottomNav.value = prefs.getBool('hide_bottom_nav') ?? false;
  alwaysOnTop.value = prefs.getBool('always_on_top') ?? false;
  // Apply persisted always-on-top state
  if (!(Platform.isAndroid || Platform.isIOS) && alwaysOnTop.value) {
    try { await windowManager.setAlwaysOnTop(true); } catch (_) {}
  }
}

Future<void> toggleBottomNav() async {
  hideBottomNav.value = !hideBottomNav.value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('hide_bottom_nav', hideBottomNav.value);
}

Future<void> toggleAlwaysOnTop() async {
  alwaysOnTop.value = !alwaysOnTop.value;
  print('[ALWAYS_ON_TOP] toggling to ${alwaysOnTop.value}');
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('always_on_top', alwaysOnTop.value);
  if (!(Platform.isAndroid || Platform.isIOS)) {
    try {
      await windowManager.setAlwaysOnTop(alwaysOnTop.value);
      final confirmed = await windowManager.isAlwaysOnTop();
      print('[ALWAYS_ON_TOP] setAlwaysOnTop(${alwaysOnTop.value}) → isAlwaysOnTop=$confirmed');
    } catch (e) {
      print('[ALWAYS_ON_TOP] setAlwaysOnTop failed: $e');
    }
  }
}

extension AppSettingsExtension on AppSettings {
  void defaults() {
    if (!hasConfirmations()) confirmations = 3;
    if (!hasRowsPerPage()) rowsPerPage = 10;
    if (!hasDeveloperMode()) developerMode = 5;
    if (!hasCurrency()) currency = 'USD';
    if (!hasAutoHide()) autoHide = 1;
    if (!hasPalette()) {
      palette = ColorPalette(
        name: 'mandyRed',
        dark: true,
      );
    }
    // memo is initialized later because we don't have S yet
    if (!hasNoteView()) noteView = 2;
    if (!hasTxView()) txView = 2;
    if (!hasMessageView()) messageView = 2;
    if (!hasCustomSendSettings())
      customSendSettings = CustomSendSettings()..defaults();
    if (!hasBackgroundSync()) backgroundSync = 1;
    if (!hasLanguage()) language = 'en';
  }

  static AppSettings load(SharedPreferences prefs) {
    final setting = prefs.getString('settings') ?? '';
    final settingBytes = base64Decode(setting);
    return AppSettings.fromBuffer(settingBytes)..defaults();
  }

  Future<void> save(SharedPreferences prefs) async {
    final bytes = this.writeToBuffer();
    final settings = base64Encode(bytes);
    await prefs.setString('settings', settings);
  }

  int chartRangeDays() => 365;
  int get anchorOffset => m.max(confirmations, 1) - 1;
}

extension CoinSettingsExtension on CoinSettings {
  void defaults(int coin) {
    int defaultUAType = coins[coin].defaultUAType;
    if (!hasUaType()) uaType = defaultUAType;
    if (!hasReplyUa()) replyUa = defaultUAType;
    if (!hasSpamFilter()) spamFilter = true;
    if (!hasReceipientPools()) receipientPools = 7;
  }

  static CoinSettings load(int coin) {
    // CLOAK doesn't use WarpApi's SQLite database
    if (CloakWalletManager.isCloak(coin)) {
      return CoinSettings()..defaults(coin);
    }
    final p = WarpApi.getProperty(coin, 'settings');
    return CoinSettings.fromBuffer(base64Decode(p))..defaults(coin);
  }

  void save(int coin) {
    // CLOAK doesn't use WarpApi's SQLite database
    if (CloakWalletManager.isCloak(coin)) {
      // TODO: Store CLOAK settings in shared_preferences or wallet file
      return;
    }
    final bytes = writeToBuffer();
    final settings = base64Encode(bytes);
    const int maxAttempts = 8;
    int attempt = 0;
    while (true) {
      try {
        WarpApi.setProperty(coin, 'settings', settings);
        break;
      } catch (e) {
        attempt += 1;
        if (attempt >= maxAttempts) rethrow;
        final msg = e.toString();
        if (!msg.contains('database is locked')) rethrow;
        sleep(Duration(milliseconds: 50 * attempt));
      }
    }
  }

  FeeT get feeT => FeeT(scheme: manualFee ? 1 : 0, fee: fee.toInt());

  String resolveBlockExplorer(int coin) {
    final explorers = coins[coin].blockExplorers;
    int idx = explorer.index;
    if (idx >= 0) return explorers[idx];
    return explorer.customURL;
  }
}

extension CustomSendSettingsExtension on CustomSendSettings {
  void defaults() {
    contacts = true;
    accounts = true;
    pools = true;
    recipientPools = true;
    amountCurrency = true;
    amountSlider = true;
    max = true;
    deductFee = true;
    replyAddress = true;
    memoSubject = true;
    memo = true;
  }
}
