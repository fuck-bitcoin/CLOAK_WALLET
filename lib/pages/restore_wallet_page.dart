import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:bip39/src/wordlists/english.dart' as bip39_words;
import 'package:shared_preferences/shared_preferences.dart';

import '../accounts.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/signature_provider.dart';
import '../store2.dart';
import 'utils.dart';

/// Restore Wallet page: accepts a 24-word BIP39 seed phrase,
/// validates it, restores the CLOAK wallet, and starts sync.
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
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: const Text('Restore Wallet'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Instructions
              Text(
                'Enter your 24-word seed phrase to restore your wallet.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),

              // Seed phrase input
              TextField(
                controller: _seedController,
                focusNode: _seedFocus,
                maxLines: 5,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
                onChanged: _onSeedChanged,
                decoration: InputDecoration(
                  labelText: 'Seed Phrase',
                  labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                  hintText: 'word1 word2 word3 ...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                  errorText: _seedError,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.redAccent),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.redAccent),
                  ),
                ),
              ),

              // BIP39 autocomplete suggestions
              if (_suggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _suggestions.map((word) {
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _applySuggestion(word),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            word,
                            style: const TextStyle(
                              color: Color(0xFF4CAF50),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 24),

              // Account name
              TextField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Account Name',
                  labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // Restore button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: Material(
                  color: const Color(0xFF4CAF50),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _onRestore,
                    child: const Center(
                      child: Text(
                        'Restore Wallet',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
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

    await load(() async {
      final account = await CloakWalletManager.restoreWallet(
        name,
        seed,
        aliasAuthority: 'thezeosalias@public',
      );

      if (account < 0) {
        showSnackBar('Wallet already exists');
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
  }
}
