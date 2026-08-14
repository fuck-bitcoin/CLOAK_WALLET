import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_coordinator.dart';

class UpdateUi {
  static bool _dialogVisible = false;

  static Future<void> checkNow(BuildContext context) async {
    final result =
        await UpdateCoordinator.instance.checkForUpdates(force: true);
    if (!context.mounted) return;
    await _showResult(context, result, manual: true);
  }

  static Future<void> maybePrompt(BuildContext context) async {
    if (_dialogVisible) return;
    if (!UpdateCoordinator.instance.automaticChecksEnabled.value) return;
    final result = await UpdateCoordinator.instance.checkForUpdates();
    if (!context.mounted || !result.hasUpdate) return;
    await _showResult(context, result, manual: false);
  }

  static Future<void> _showResult(
    BuildContext context,
    UpdateCheckResult result, {
    required bool manual,
  }) async {
    if (result.hasUpdate) {
      await _showAvailable(context, result);
      return;
    }
    if (!manual) return;

    var title = 'No update available';
    var message = 'CLOAK Wallet is up to date.';
    switch (result.status) {
      case UpdateCheckStatus.manualUpdateRequired:
        title = 'Baseline installer required';
        message = result.message ?? title;
        break;
      case UpdateCheckStatus.notConfigured:
      case UpdateCheckStatus.error:
      case UpdateCheckStatus.unsupported:
        title = 'Could not check for updates';
        message = result.message ?? 'Updates are unavailable on this build.';
        break;
      default:
        break;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (result.status == UpdateCheckStatus.manualUpdateRequired)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(
                'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest',
              )),
              child: const Text('Open release'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static Future<void> _showAvailable(
    BuildContext context,
    UpdateCheckResult result,
  ) async {
    if (_dialogVisible) return;
    _dialogVisible = true;
    final manifest = result.manifest!;
    try {
      final action = await showDialog<_UpdateAction>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('CLOAK Wallet ${manifest.version} is available'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 320),
            child: SingleChildScrollView(
              child: Text(
                manifest.notes.trim().isEmpty
                    ? 'This release is signed by the CLOAK release key.'
                    : manifest.notes,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _UpdateAction.skip),
              child: const Text('Skip this version'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _UpdateAction.later),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _UpdateAction.install),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      if (action == _UpdateAction.skip) {
        await UpdateCoordinator.instance.skip(manifest);
      } else if (action == _UpdateAction.install && context.mounted) {
        await _install(context, result);
      }
    } finally {
      _dialogVisible = false;
    }
  }

  static Future<void> _install(
    BuildContext context,
    UpdateCheckResult result,
  ) async {
    final progress = ValueNotifier<double?>(null);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) => AlertDialog(
          title: const Text('Preparing secure update'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 16),
              const Text('The download and signature are being verified.'),
            ],
          ),
        ),
      ),
    ));
    try {
      await UpdateCoordinator.instance.install(
        result,
        onProgress: (received, total) {
          progress.value = total == 0 ? null : received / total;
        },
      );
      if (context.mounted &&
          Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (context.mounted &&
          UpdateCoordinator.instance.lifecycle.value ==
              UpdateLifecycle.deferred) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Update verified. It will apply after the active transaction finishes.',
          ),
        ));
      }
    } catch (error) {
      if (context.mounted &&
          Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Update failed safely'),
            content: Text('$error'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }
}

enum _UpdateAction { install, later, skip }
