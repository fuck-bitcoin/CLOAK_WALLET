import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:bip39/src/wordlists/english.dart' as bip39_words;
import 'package:shared_preferences/shared_preferences.dart';

import '../accounts.dart';
import '../cloak/cloak_db.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/signature_provider.dart';
import '../store2.dart';
import 'utils.dart';

/// Restore Wallet page: accepts a 24-word BIP39 seed phrase or
/// an Incoming Viewing Key (ivk1...) for view-only wallets.
class RestoreWalletPage extends StatefulWidget {
  const RestoreWalletPage({super.key});

  @override
  State<RestoreWalletPage> createState() => _RestoreWalletPageState();
}

class _RestoreWalletPageState extends State<RestoreWalletPage>
    with WithLoadingAnimation {
  final _seedController = TextEditingController();
  final _nameController = TextEditingController(text: 'Main');
  final _seedFocus = FocusNode();
  String? _seedError;
  List<String> _suggestions = [];
  bool _isIvkMode = false;

  @override
  void dispose() {
    _seedController.dispose();
    _nameController.dispose();
    _seedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return wrapWithLoading(Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: const Text('Restore Wallet'),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Instructions
              Text(
                _isIvkMode
                    ? 'Paste your Viewing Key to restore a view-only wallet.'
                    : 'Enter your 24-word seed phrase to restore your wallet.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),

              // ── Mode selector ──
              _sectionLabel('RESTORE MODE'),
              const SizedBox(height: 10),
              Row(
                children: [
                  _modePill(
                    icon: Icons.spa_outlined,
                    label: 'Seed Phrase',
                    active: !_isIvkMode,
                    onTap: () => setState(() {
                      _isIvkMode = false;
                      _seedError = null;
                      _suggestions = [];
                    }),
                  ),
                  const SizedBox(width: 10),
                  _modePill(
                    icon: Icons.visibility_outlined,
                    label: 'Viewing Key',
                    active: _isIvkMode,
                    onTap: () => setState(() {
                      _isIvkMode = true;
                      _seedError = null;
                      _suggestions = [];
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Seed phrase / IVK input ──
              _sectionLabel(_isIvkMode ? 'VIEWING KEY' : 'RECOVERY PHRASE'),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2E2C2C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _seedError != null
                        ? const Color(0xFFEF5350).withOpacity(0.5)
                        : (_seedFocus.hasFocus
                            ? const Color(0xFF4CAF50).withOpacity(0.4)
                            : Colors.white.withOpacity(0.08)),
                  ),
                ),
                child: TextField(
                  controller: _seedController,
                  focusNode: _seedFocus,
                  maxLines: _isIvkMode ? 3 : 5,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                  onChanged: _isIvkMode
                      ? (_) {
                          if (_seedError != null) {
                            setState(() => _seedError = null);
                          }
                        }
                      : _onSeedChanged,
                  decoration: InputDecoration(
                    hintText: _isIvkMode ? 'ivk1... or fvk1...' : 'word1 word2 word3 ...',
                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.15),
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                    border: InputBorder.none,
                  ),
                ),
              ),

              // Error text
              if (_seedError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(
                    _seedError!,
                    style: const TextStyle(
                      color: Color(0xFFEF5350),
                      fontSize: 12,
                    ),
                  ),
                ),

              // BIP39 autocomplete suggestions (seed mode only)
              if (_suggestions.isNotEmpty && !_isIvkMode)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _suggestions.map((word) {
                      return Material(
                        color: const Color(0xFF4CAF50).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _applySuggestion(word),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            child: Text(
                              word,
                              style: const TextStyle(
                                color: Color(0xFF4CAF50),
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),

              // IVK warning box
              if (_isIvkMode) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.orange.withOpacity(0.2)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Icon(Icons.visibility,
                              color: Colors.orange.withOpacity(0.7), size: 16),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'View-Only Wallet',
                              style: TextStyle(
                                color: Colors.orange.withOpacity(0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Accepts IVK or FVK. Can view balances and history. Cannot send, create vaults, or sign.',
                              style: TextStyle(
                                color: Colors.orange.withOpacity(0.6),
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // ── Account name ──
              _sectionLabel('ACCOUNT NAME'),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2E2C2C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Main',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.15)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Restore button ──
              SizedBox(
                width: double.infinity,
                height: 52,
                child: Material(
                  color: _isIvkMode
                      ? Colors.orange.withOpacity(0.8)
                      : const Color(0xFF4CAF50),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _onRestore,
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isIvkMode
                                ? Icons.visibility_outlined
                                : Icons.restore,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _isIvkMode ? 'Restore (View-Only)' : 'Restore Wallet',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    ));
  }

  // ── Section label (matches backup.dart style) ──
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white.withOpacity(0.35),
          letterSpacing: 2,
        ),
      ),
    );
  }

  // ── Mode pill (Seed Phrase / Viewing Key) ──
  Widget _modePill({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: active
            ? const Color(0xFF4CAF50).withOpacity(0.15)
            : const Color(0xFF2E2C2C),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active
                    ? const Color(0xFF4CAF50).withOpacity(0.4)
                    : Colors.white.withOpacity(0.06),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: active
                      ? const Color(0xFF4CAF50)
                      : Colors.white.withOpacity(0.35),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: active
                        ? const Color(0xFF4CAF50)
                        : Colors.white.withOpacity(0.4),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onSeedChanged(String text) {
    // Clear previous error
    if (_seedError != null) {
      setState(() => _seedError = null);
    }

    // BIP39 autocomplete: suggest words matching the last partial word
    final words = text.split(RegExp(r'\s+'));
    final lastWord = words.isNotEmpty ? words.last.toLowerCase() : '';

    if (lastWord.length >= 2) {
      final matches = bip39_words.WORDLIST
          .where((w) => w.startsWith(lastWord))
          .take(6)
          .toList();
      setState(() => _suggestions = matches);
    } else {
      setState(() => _suggestions = []);
    }
  }

  void _applySuggestion(String word) {
    final text = _seedController.text;
    final words = text.split(RegExp(r'\s+'));
    if (words.isNotEmpty) words.removeLast();
    words.add(word);
    final newText = words.join(' ') + ' ';
    _seedController.text = newText;
    _seedController.selection = TextSelection.fromPosition(
      TextPosition(offset: newText.length),
    );
    _seedFocus.requestFocus();
    setState(() => _suggestions = []);
  }

  String? _validateSeed(String seed) {
    if (_isIvkMode) {
      final trimmed = seed.trim();
      if (!trimmed.startsWith('ivk1') &&
          !trimmed.startsWith('fvk1')) {
        return 'Viewing key must start with ivk1 or fvk1';
      }
      if (trimmed.length < 20) {
        return 'Viewing key is too short';
      }
      return null;
    }
    final words = seed.trim().split(RegExp(r'\s+'));
    if (words.length != 24) {
      return 'Seed phrase must be exactly 24 words (got ${words.length})';
    }
    for (final word in words) {
      if (!bip39_words.WORDLIST.contains(word.toLowerCase())) {
        return 'Invalid BIP39 word: "$word"';
      }
    }
    return null;
  }

  Future<void> _onRestore() async {
    final seed = _seedController.text.trim();
    final name = _nameController.text.trim();

    // Validate
    final seedErr = _validateSeed(seed);
    if (seedErr != null) {
      setState(() => _seedError = seedErr);
      return;
    }
    if (name.isEmpty) {
      showSnackBar('Please enter an account name');
      return;
    }

    try {
      await load(() async {
        // Always clear existing accounts before restore to prevent duplicates
        await CloakDb.clearAllAccounts();

        final account = await CloakWalletManager.restoreWallet(
          name,
          seed,
          aliasAuthority: 'thezeosalias@public',
          isIvk: _isIvkMode,
        );

        if (account < 0) {
          showSnackBar(_isIvkMode
              ? 'Failed to restore view-only wallet. Check the viewing key format.'
              : 'Wallet already exists');
          return;
        }

        await refreshCloakAccountsCache();
        await SignatureProvider.start();

        setActiveAccount(0, account);
        final prefs = await SharedPreferences.getInstance();
        await aa.save(prefs);

        // Navigate to account — sync banner appears automatically
        // (restoreWallet sets synced_height = 0, triggering full sync)
        if (mounted) GoRouter.of(context).go('/account');
      });
    } catch (e) {
      print('[RestoreWallet] Error restoring wallet: $e');
      if (mounted) showSnackBar('Failed to restore wallet. Please try again.');
    }
  }
}
