import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../appsettings.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/params_manager.dart';
import '../cloak/signature_provider.dart';
import 'desktop_update_installer.dart';
import 'update_config.dart';
import 'update_downloader.dart';
import 'update_install_gate.dart';
import 'update_manifest.dart';
import 'update_manifest_client.dart';
import 'update_shutdown.dart';

enum UpdateCheckStatus {
  available,
  upToDate,
  skipped,
  throttled,
  unsupported,
  notConfigured,
  manualUpdateRequired,
  error,
}

enum UpdateLifecycle {
  idle,
  checking,
  available,
  downloading,
  ready,
  deferred,
  applying,
  failed,
}

class UpdateCheckResult {
  final UpdateCheckStatus status;
  final UpdateManifestV1? manifest;
  final UpdateAsset? asset;
  final String? message;

  const UpdateCheckResult(
    this.status, {
    this.manifest,
    this.asset,
    this.message,
  });

  bool get hasUpdate => status == UpdateCheckStatus.available;
}

class UpdateCoordinator {
  static const _lastCheckKey = 'cloak_update_last_check_v1';
  static const _skippedVersionKey = 'cloak_update_skipped_version_v1';
  static const _automaticChecksKey = 'cloak_update_automatic_checks_v1';
  static const MethodChannel _platformChannel =
      MethodChannel('app.cloak.wallet/updater');
  static final UpdateCoordinator instance = UpdateCoordinator._();

  final http.Client _httpClient;
  final ValueNotifier<UpdateLifecycle> lifecycle =
      ValueNotifier(UpdateLifecycle.idle);
  final ValueNotifier<bool> automaticChecksEnabled = ValueNotifier(true);
  late bool Function() installSafetyCheck;
  Future<void> Function()? _deferredApply;
  Timer? _deferredTimer;

  UpdateCoordinator._() : _httpClient = http.Client() {
    installSafetyCheck = () =>
        !CloakWalletManager.isSensitiveOperationActive &&
        !SignatureProvider.isSigningRequestActive;
    _platformChannel.setMethodCallHandler(_handlePlatformMethod);
  }

  static bool get isApplyingUpdate => UpdateInstallGate.isApplyingUpdate;

  /// Loads the user preference once at startup. Automatic checks default on;
  /// manual checks remain available regardless of this setting.
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    automaticChecksEnabled.value = prefs.getBool(_automaticChecksKey) ?? true;
  }

  Future<void> setAutomaticChecksEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_automaticChecksKey, enabled);
    automaticChecksEnabled.value = enabled;
  }

  Future<UpdateCheckResult> checkForUpdates({bool force = false}) async {
    lifecycle.value = UpdateLifecycle.checking;
    UpdateCheckResult finish(UpdateCheckResult result) {
      if (result.status == UpdateCheckStatus.available) {
        lifecycle.value = UpdateLifecycle.available;
      } else if (result.status == UpdateCheckStatus.error ||
          result.status == UpdateCheckStatus.notConfigured) {
        lifecycle.value = UpdateLifecycle.failed;
      } else {
        lifecycle.value = UpdateLifecycle.idle;
      }
      return result;
    }

    final target = currentUpdateTarget();
    if (target == null || Platform.isIOS) {
      return finish(const UpdateCheckResult(UpdateCheckStatus.unsupported));
    }
    if (cloakUpdatePublicKey.isEmpty) {
      return finish(const UpdateCheckResult(
        UpdateCheckStatus.notConfigured,
        message:
            'This build does not contain the CLOAK release verification key.',
      ));
    }
    SemanticVersion current;
    try {
      current = SemanticVersion.parse(appVersion);
    } catch (_) {
      return finish(const UpdateCheckResult(
        UpdateCheckStatus.notConfigured,
        message: 'Development builds do not install production updates.',
      ));
    }

    final prefs = await SharedPreferences.getInstance();
    if (!force && !await reserveAutomaticCheckAttempt(prefs)) {
      return finish(
        const UpdateCheckResult(UpdateCheckStatus.throttled),
      );
    }

    try {
      final client = UpdateManifestClient(
        client: _httpClient,
        manifestUri: Uri.parse(cloakUpdateManifestUrl),
        signatureUri: Uri.parse(cloakUpdateSignatureUrl),
        publicKeyBase64: cloakUpdatePublicKey,
      );
      final manifest = await client.fetchVerified();
      final asset = manifest.assetFor(target);
      if (asset == null) {
        return finish(UpdateCheckResult(
          UpdateCheckStatus.unsupported,
          manifest: manifest,
          message: 'No signed update is available for $target.',
        ));
      }
      if (!manifest.supportsParameterGeneration(
        ParamsManager.protocolGeneration,
      )) {
        return finish(UpdateCheckResult(
          UpdateCheckStatus.manualUpdateRequired,
          manifest: manifest,
          asset: asset,
          message: 'CLOAK Wallet ${manifest.version} requires proving '
              'parameters ${manifest.requiredParameterGeneration}, but this '
              'wallet supports ${ParamsManager.protocolGeneration}. Install '
              'a compatible baseline release manually.',
        ));
      }
      if (manifest.version.compareTo(current) <= 0) {
        return finish(UpdateCheckResult(
          UpdateCheckStatus.upToDate,
          manifest: manifest,
          asset: asset,
        ));
      }
      if (current.compareTo(manifest.minimumUpdaterVersion) < 0) {
        return finish(UpdateCheckResult(
          UpdateCheckStatus.manualUpdateRequired,
          manifest: manifest,
          asset: asset,
          message: 'A one-time baseline installer is required for this update.',
        ));
      }
      if (!force &&
          prefs.getString(_skippedVersionKey) == manifest.version.toString()) {
        return finish(UpdateCheckResult(
          UpdateCheckStatus.skipped,
          manifest: manifest,
          asset: asset,
        ));
      }
      return finish(UpdateCheckResult(
        UpdateCheckStatus.available,
        manifest: manifest,
        asset: asset,
      ));
    } catch (error) {
      return finish(UpdateCheckResult(
        UpdateCheckStatus.error,
        message: error.toString(),
      ));
    }
  }

  /// Reserves the current automatic-check interval before any network
  /// request. Failed/offline attempts are therefore throttled too, while
  /// force=true manual checks bypass this reservation entirely.
  @visibleForTesting
  static Future<bool> reserveAutomaticCheckAttempt(
    SharedPreferences prefs, {
    DateTime? now,
  }) async {
    final attemptedAt = now ?? DateTime.now();
    final lastAttemptMillis = prefs.getInt(_lastCheckKey);
    if (lastAttemptMillis != null) {
      final nextAttempt = DateTime.fromMillisecondsSinceEpoch(lastAttemptMillis)
          .add(automaticUpdateCheckInterval);
      if (attemptedAt.isBefore(nextAttempt)) return false;
    }
    await prefs.setInt(_lastCheckKey, attemptedAt.millisecondsSinceEpoch);
    return true;
  }

  Future<void> skip(UpdateManifestV1 manifest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, manifest.version.toString());
  }

  Future<void> install(
    UpdateCheckResult result, {
    UpdateDownloadProgress? onProgress,
  }) async {
    if (!result.hasUpdate || result.manifest == null || result.asset == null) {
      lifecycle.value = UpdateLifecycle.failed;
      throw const UpdateException('No verified update is ready to install');
    }
    if (!result.manifest!.supportsParameterGeneration(
      ParamsManager.protocolGeneration,
    )) {
      lifecycle.value = UpdateLifecycle.failed;
      throw const UpdateException(
        'The signed update requires a different proving-parameter generation',
      );
    }
    if (Platform.isMacOS) {
      lifecycle.value = UpdateLifecycle.ready;
      await _applyWhenSafe(() async {
        final started = await _platformChannel.invokeMethod<bool>(
          'checkForUpdates',
          {
            'tag': result.manifest!.tag,
            'version': result.manifest!.version.toString(),
          },
        );
        if (started != true) {
          throw const UpdateException('Sparkle could not start the update');
        }
      });
      return;
    }

    lifecycle.value = UpdateLifecycle.downloading;
    late final File file;
    try {
      file = await UpdateDownloader(_httpClient).downloadVerified(
        result.asset!,
        result.manifest!.version.toString(),
        onProgress: onProgress,
      );
    } catch (_) {
      lifecycle.value = UpdateLifecycle.failed;
      rethrow;
    }
    lifecycle.value = UpdateLifecycle.ready;
    if (Platform.isAndroid) {
      await _applyWhenSafe(() async {
        await UpdateShutdown.prepareForUpdate();
        try {
          final started = await _platformChannel.invokeMethod<bool>(
            'installApk',
            {'path': file.path},
          );
          if (started != true) {
            throw const UpdateException(
              'Allow CLOAK Wallet to install unknown apps, then try again.',
            );
          }
          // Android owns the confirmation UI from this point. Exit only after
          // it was launched so a cancellation leaves a clean, restartable app.
          UpdateShutdown.exitPrepared();
        } catch (_) {
          await UpdateShutdown.resumeAfterInstallerDidNotExit();
          rethrow;
        }
      });
      return;
    }
    if (Platform.isWindows) {
      await _applyWhenSafe(
        () => DesktopUpdateInstaller().installWindows(file),
      );
      return;
    }
    if (Platform.isLinux) {
      await _applyWhenSafe(
        () => DesktopUpdateInstaller().installLinuxAppImage(file),
      );
      return;
    }
    lifecycle.value = UpdateLifecycle.failed;
    throw const UpdateException('This platform cannot apply updates');
  }

  Future<void> _applyWhenSafe(Future<void> Function() apply) async {
    if (!UpdateInstallGate.tryAcquire(installSafetyCheck)) {
      _defer(apply);
      return;
    }
    lifecycle.value = UpdateLifecycle.applying;
    try {
      await apply();
      lifecycle.value = UpdateLifecycle.idle;
    } catch (_) {
      lifecycle.value = UpdateLifecycle.failed;
      rethrow;
    } finally {
      UpdateInstallGate.release();
    }
  }

  void _defer(Future<void> Function() apply) {
    _deferredApply = apply;
    lifecycle.value = UpdateLifecycle.deferred;
    _deferredTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(notifyOperationsMayBeIdle()),
    );
  }

  /// May be called by transaction/proof coordinators when their critical
  /// section ends. A timer is also retained as a crash-safe fallback.
  Future<void> notifyOperationsMayBeIdle() async {
    final deferred = _deferredApply;
    if (deferred == null || !UpdateInstallGate.tryAcquire(installSafetyCheck)) {
      return;
    }
    _deferredApply = null;
    _deferredTimer?.cancel();
    _deferredTimer = null;
    lifecycle.value = UpdateLifecycle.applying;
    try {
      await deferred();
      lifecycle.value = UpdateLifecycle.idle;
    } catch (_) {
      lifecycle.value = UpdateLifecycle.failed;
    } finally {
      UpdateInstallGate.release();
    }
  }

  Future<Object?> _handlePlatformMethod(MethodCall call) async {
    if (call.method != 'prepareForSparkleInstall') {
      throw MissingPluginException('Unknown updater callback ${call.method}');
    }

    while (!UpdateInstallGate.tryAcquire(installSafetyCheck)) {
      lifecycle.value = UpdateLifecycle.deferred;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    lifecycle.value = UpdateLifecycle.applying;
    try {
      await UpdateShutdown.prepareForUpdate();
      // Sparkle owns termination from this point. Keep the gate held so no new
      // proof/sign/send can start between this acknowledgement and relaunch.
      return true;
    } catch (_) {
      UpdateInstallGate.release();
      lifecycle.value = UpdateLifecycle.failed;
      return false;
    }
  }

  static Future<void> acknowledgeHealthCheck(List<String> arguments) async {
    final token = healthTokenFromArguments(arguments);
    if (token == null) return;
    final healthFile = healthFileForToken(token);
    await healthFile.writeAsString(
      'ok $appVersion $appBuildNumber\n',
      flush: true,
    );
  }

  @visibleForTesting
  static String? healthTokenFromArguments(Iterable<String> arguments) {
    final tokens = arguments
        .where((value) => value.startsWith('--cloak-update-health='))
        .map((value) => value.substring('--cloak-update-health='.length))
        .toList(growable: false);
    if (tokens.length != 1 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(tokens.single)) {
      return null;
    }
    return tokens.single;
  }

  @visibleForTesting
  static File healthFileForToken(String token) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(token)) {
      throw ArgumentError.value(token, 'token', 'Invalid update health token');
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'cloak-wallet-update-$token.ok',
    );
  }
}
