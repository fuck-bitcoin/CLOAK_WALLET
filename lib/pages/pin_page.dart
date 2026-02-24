import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloak/cloak_wallet_manager.dart';
import '../cloak/cloak_db.dart';
import '../cloak/signature_provider.dart';
import '../accounts.dart';
import '../store2.dart';
import 'utils.dart' show getDbPath, refreshCloakAccountsCache;

/// PIN setup page for first launch. User enters + confirms a 6-digit PIN.
/// After confirming, initializes encrypted DB and navigates to create/restore.
class PinSetupPage extends StatefulWidget {
  /// Where to navigate after PIN is set: 'create' or 'restore'
  final String next;
  const PinSetupPage({super.key, required this.next});

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  String _pin = '';
  String? _firstPin;
  bool _confirming = false;
  bool _error = false;
  bool _loading = false;

  void _onDigit(int digit) {
    if (_pin.length >= 6 || _loading) return;
    setState(() {
      _error = false;
      _pin += digit.toString();
    });
    if (_pin.length == 6) {
      Future.delayed(const Duration(milliseconds: 200), _onComplete);
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _loading) return;
    setState(() {
      _error = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _onComplete() async {
    if (!_confirming) {
      // First entry — save and ask to confirm
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _confirming = true;
      });
    } else {
      // Confirmation entry
      if (_pin == _firstPin) {
        // PINs match — initialize encrypted DB
        setState(() => _loading = true);
        try {
          // Close the unencrypted empty DB that main() may have opened
          await CloakDb.close();

          // Delete the unencrypted DB file so we can create a fresh encrypted one
          final dbDir = await getDbPath();
          final dbFile = File('$dbDir/cloak.db');
          if (await dbFile.exists()) await dbFile.delete();

          // Set the password and re-init with encryption
          appStore.dbPassword = _pin;
          await CloakWalletManager.init(dbPassword: _pin);

          // Persist that PIN is set
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('pin_set', true);

          if (mounted) {
            GoRouter.of(context).go('/splash/${widget.next}');
          }
        } catch (e) {
          print('[PIN] Error initializing encrypted DB: $e');
          setState(() => _loading = false);
        }
      } else {
        // PINs don't match — reset to confirm
        setState(() {
          _error = true;
          _pin = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _confirming ? 'Confirm PIN' : 'Set Your PIN';
    final subtitle = _confirming
        ? (_error ? 'PINs didn\'t match. Try again.' : 'Enter your PIN again to confirm')
        : 'Choose a 6-digit PIN to secure your wallet';

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _loading
              ? null
              : () {
                  if (_confirming) {
                    setState(() {
                      _confirming = false;
                      _firstPin = null;
                      _pin = '';
                      _error = false;
                    });
                  } else {
                    GoRouter.of(context).pop();
                  }
                },
        ),
        elevation: 0,
      ),
      body: _PinBody(
        title: title,
        subtitle: subtitle,
        pin: _pin,
        error: _error,
        loading: _loading,
        onDigit: _onDigit,
        onBackspace: _onBackspace,
      ),
    );
  }
}

/// PIN login page for returning users with encrypted DB.
class PinLoginPage extends StatefulWidget {
  const PinLoginPage({super.key});

  @override
  State<PinLoginPage> createState() => _PinLoginPageState();
}

class _PinLoginPageState extends State<PinLoginPage> {
  String _pin = '';
  bool _error = false;
  bool _loading = false;

  void _onDigit(int digit) {
    if (_pin.length >= 6 || _loading) return;
    setState(() {
      _error = false;
      _pin += digit.toString();
    });
    if (_pin.length == 6) {
      Future.delayed(const Duration(milliseconds: 200), _onComplete);
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _loading) return;
    setState(() {
      _error = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _onComplete() async {
    setState(() => _loading = true);
    try {
      appStore.dbPassword = _pin;
      await CloakWalletManager.init(dbPassword: _pin);

      // Test that the DB actually opened (wrong PIN = "not a database" error)
      final ok = await CloakDb.testConnection();
      if (!ok) {
        // Wrong PIN
        await CloakDb.close();
        appStore.dbPassword = '';
        setState(() {
          _error = true;
          _pin = '';
          _loading = false;
        });
        return;
      }

      // DB opened successfully — load wallet
      await CloakWalletManager.loadWallet();
      await refreshCloakAccountsCache();
      await CloakDb.refreshBurnTimestampsCache();

      await SignatureProvider.start();

      // Restore active account
      final prefs = await SharedPreferences.getInstance();
      final a = ActiveAccount2.fromPrefs(prefs);
      if (a != null) {
        setActiveAccount(a.coin, a.id);
        aa.update(syncStatus2.latestHeight);
      }

      // Start sync
      initSyncListener();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future(() => triggerManualSync());
      });

      if (mounted) GoRouter.of(context).go('/account');
    } catch (e) {
      print('[PIN] Login error: $e');
      await CloakDb.close();
      appStore.dbPassword = '';
      setState(() {
        _error = true;
        _pin = '';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: _PinBody(
        title: 'Enter PIN',
        subtitle: _error ? 'Incorrect PIN. Try again.' : 'Enter your 6-digit PIN to unlock',
        pin: _pin,
        error: _error,
        loading: _loading,
        onDigit: _onDigit,
        onBackspace: _onBackspace,
      ),
    );
  }
}

/// Shared PIN entry UI: title, dots, numpad.
/// Supports physical keyboard input (digits 0-9 and backspace).
class _PinBody extends StatefulWidget {
  final String title;
  final String subtitle;
  final String pin;
  final bool error;
  final bool loading;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;

  const _PinBody({
    required this.title,
    required this.subtitle,
    required this.pin,
    required this.error,
    required this.loading,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  State<_PinBody> createState() => _PinBodyState();
}

class _PinBodyState extends State<_PinBody> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Auto-focus to capture keyboard events
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
    });
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        final key = event.logicalKey;
        // Digits 0-9 (main keyboard and numpad)
        final digitKeys = {
          LogicalKeyboardKey.digit0: 0, LogicalKeyboardKey.digit1: 1,
          LogicalKeyboardKey.digit2: 2, LogicalKeyboardKey.digit3: 3,
          LogicalKeyboardKey.digit4: 4, LogicalKeyboardKey.digit5: 5,
          LogicalKeyboardKey.digit6: 6, LogicalKeyboardKey.digit7: 7,
          LogicalKeyboardKey.digit8: 8, LogicalKeyboardKey.digit9: 9,
          LogicalKeyboardKey.numpad0: 0, LogicalKeyboardKey.numpad1: 1,
          LogicalKeyboardKey.numpad2: 2, LogicalKeyboardKey.numpad3: 3,
          LogicalKeyboardKey.numpad4: 4, LogicalKeyboardKey.numpad5: 5,
          LogicalKeyboardKey.numpad6: 6, LogicalKeyboardKey.numpad7: 7,
          LogicalKeyboardKey.numpad8: 8, LogicalKeyboardKey.numpad9: 9,
        };
        if (digitKeys.containsKey(key)) {
          widget.onDigit(digitKeys[key]!);
        } else if (key == LogicalKeyboardKey.backspace) {
          widget.onBackspace();
        }
      },
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Title
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w300,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            // Subtitle
            Text(
              widget.subtitle,
              style: TextStyle(
                color: widget.error
                    ? const Color(0xFFEF5350)
                    : Colors.white.withOpacity(0.45),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 36),
            // PIN dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < widget.pin.length;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? (widget.error
                              ? const Color(0xFFEF5350)
                              : const Color(0xFF4CAF50))
                          : Colors.transparent,
                      border: Border.all(
                        color: widget.error
                            ? const Color(0xFFEF5350).withOpacity(0.5)
                            : Colors.white.withOpacity(0.25),
                        width: 1.5,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 12),
            // Loading indicator
            SizedBox(
              height: 24,
              child: widget.loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF4CAF50),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const Spacer(flex: 2),
            // Numpad
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Column(
                children: [
                  _numRow([1, 2, 3], widget.onDigit),
                  const SizedBox(height: 16),
                  _numRow([4, 5, 6], widget.onDigit),
                  const SizedBox(height: 16),
                  _numRow([7, 8, 9], widget.onDigit),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      // Empty spacer
                      Expanded(child: SizedBox(height: 64)),
                      // 0
                      Expanded(child: _numButton(0, widget.onDigit)),
                      // Backspace
                      Expanded(
                        child: SizedBox(
                          height: 64,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: widget.onBackspace,
                              child: Center(
                                child: Icon(
                                  Icons.backspace_outlined,
                                  color: Colors.white.withOpacity(0.6),
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(flex: 1),
          ],
        ),
      ),
    );
  }

  static Widget _numRow(List<int> digits, ValueChanged<int> onDigit) {
    return Row(
      children: digits
          .map((d) => Expanded(child: _numButton(d, onDigit)))
          .toList(),
    );
  }

  static Widget _numButton(int digit, ValueChanged<int> onDigit) {
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Material(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => onDigit(digit),
            child: Center(
              child: Text(
                '$digit',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
