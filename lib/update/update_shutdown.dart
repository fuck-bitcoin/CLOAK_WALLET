import 'dart:async';
import 'dart:io';

import '../cloak/cloak_wallet_manager.dart';
import '../cloak/signature_provider.dart';
import '../store2.dart';
import 'update_install_gate.dart';

class UpdateShutdown {
  static bool _inProgress = false;
  static bool _prepared = false;
  static bool _walletWasLoaded = false;
  static bool _signatureProviderWasRunning = false;
  static bool _syncWasPaused = false;
  static bool _autoSyncWasRunning = false;

  static Future<void> gracefulExit({int code = 0}) async {
    await prepareForUpdate();
    exitPrepared(code: code);
  }

  /// Quiesces all wallet-owned state and fails closed if it cannot be saved.
  /// A pre-launched desktop helper must remain unable to mutate application
  /// files until this process exits successfully.
  static Future<void> prepareForUpdate() async {
    if (_prepared) return;
    if (_inProgress) {
      throw StateError('Wallet shutdown is already in progress');
    }
    _inProgress = true;
    _walletWasLoaded = CloakWalletManager.isLoaded;
    _signatureProviderWasRunning = SignatureProvider.isRunning;
    _syncWasPaused = syncStatus2.paused;
    _autoSyncWasRunning = syncTimer != null;

    syncTimer?.cancel();
    syncTimer = null;
    syncStatus2.setPause(true);

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (syncStatus2.syncing && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (syncStatus2.syncing ||
          CloakWalletManager.isSensitiveOperationActive ||
          SignatureProvider.isSigningRequestActive) {
        throw StateError('Wallet is still completing a sensitive operation');
      }

      if (CloakWalletManager.isLoaded) {
        final saved = await CloakWalletManager.saveWallet()
            .timeout(const Duration(seconds: 30));
        if (!saved) throw StateError('Wallet save was rejected');
      }
      await SignatureProvider.stop().timeout(const Duration(seconds: 5));
      if (CloakWalletManager.isLoaded) await CloakWalletManager.close();
      _prepared = true;
    } catch (error) {
      try {
        await _restoreRuntime();
      } catch (restoreError) {
        throw StateError(
          'Wallet update preparation failed ($error) and runtime recovery '
          'also failed ($restoreError). Restart CLOAK Wallet.',
        );
      }
      rethrow;
    }
  }

  /// Restores wallet-owned state when an external installer did not replace
  /// this running process (for example, a rejected Android package install).
  static Future<void> resumeAfterInstallerDidNotExit() async {
    if (!_prepared && !_inProgress) return;
    await _restoreRuntime();
  }

  static Future<void> _restoreRuntime() async {
    if (_walletWasLoaded && !CloakWalletManager.isLoaded) {
      // Installer failure recovery occurs while the install gate remains held
      // so no proof/send/sign request can race the reopen. Use the manager's
      // narrowly scoped recovery API for that state; ordinary callers retain
      // the public load path and all of its update-entry guards.
      final loaded = UpdateInstallGate.isApplyingUpdate
          ? await CloakWalletManager.loadWalletForUpdateRecovery()
          : await CloakWalletManager.loadWallet();
      if (!loaded) throw StateError('Could not reopen the wallet');
    }
    if (_signatureProviderWasRunning && !SignatureProvider.isRunning) {
      final started = await SignatureProvider.start();
      if (!started && !SignatureProvider.isRunning) {
        throw StateError('Could not restart the signing provider');
      }
    }
    syncStatus2.setPause(_syncWasPaused);
    if (_autoSyncWasRunning && syncTimer == null) {
      // The install gate is released by the coordinator after this recovery
      // returns. Restore scheduling on the next tick so sync cannot race that
      // release or disappear permanently after a failed preparation.
      syncTimer = Timer(const Duration(seconds: 1), () {
        syncTimer = null;
        unawaited(startAutoSync());
      });
    }
    _prepared = false;
    _inProgress = false;
    _walletWasLoaded = false;
    _signatureProviderWasRunning = false;
    _syncWasPaused = false;
    _autoSyncWasRunning = false;
  }

  static Never exitPrepared({int code = 0}) {
    if (!_prepared) {
      throw StateError('Wallet update shutdown has not completed');
    }
    exit(code);
  }
}
