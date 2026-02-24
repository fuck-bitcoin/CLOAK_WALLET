import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:shared_preferences/shared_preferences.dart';

import '../accounts.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/signature_provider.dart';
import 'utils.dart';

/// Create Wallet page: generates a 24-word BIP39 seed, displays it,
/// requires confirmation, then creates the CLOAK wallet.
class CreateWalletPage extends StatefulWidget {
  const CreateWalletPage({super.key});

  @override
  State<CreateWalletPage> createState() => _CreateWalletPageState();
}

class _CreateWalletPageState extends State<CreateWalletPage>
    with WithLoadingAnimation {
  late final String _seed;
  bool _confirmed = false;
  bool _seedRevealed = false;
  final _nameController = TextEditingController(text: 'Main');

  @override
  void initState() {
    super.initState();
    _seed = bip39.generateMnemonic(strength: 256); // 24 words
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final words = _seed.split(' ');

    return wrapWithLoading(Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: const Text('Create Wallet'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Warning banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFF4CAF50), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Write down these 24 words and store them safely. '
                        'This is the ONLY way to recover your wallet.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Seed phrase grid (blurred until revealed)
              GestureDetector(
                onTap: () {
                  if (!_seedRevealed) setState(() => _seedRevealed = true);
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _seedRevealed
                      ? _buildSeedGrid(words)
                      : _buildBlurredSeed(),
                ),
              ),
              const SizedBox(height: 12),

              // Copy button
              if (_seedRevealed)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _seed));
                      showSnackBar('Seed phrase copied to clipboard');
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white.withOpacity(0.6),
                    ),
                  ),
                ),
              const SizedBox(height: 16),

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
              const SizedBox(height: 20),

              // Confirmation checkbox
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _confirmed = !_confirmed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _confirmed,
                        onChanged: (v) => setState(() => _confirmed = v!),
                        activeColor: const Color(0xFF4CAF50),
                      ),
                      Expanded(
                        child: Text(
                          "I've saved my seed phrase securely",
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Create button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: Material(
                  color: (_confirmed && _seedRevealed)
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFF4CAF50).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: (_confirmed && _seedRevealed) ? _onCreate : null,
                    child: const Center(
                      child: Text(
                        'Create Wallet',
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

  Widget _buildBlurredSeed() {
    return Container(
      key: const ValueKey('blurred'),
      width: double.infinity,
      height: 240,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.visibility_off,
                color: Colors.white.withOpacity(0.4), size: 36),
            const SizedBox(height: 12),
            Text(
              'Tap to reveal seed phrase',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeedGrid(List<String> words) {
    return Container(
      key: const ValueKey('revealed'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(words.length, (i) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${i + 1}. ${words[i]}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          );
        }),
      ),
    );
  }

  Future<void> _onCreate() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSnackBar('Please enter an account name');
      return;
    }

    try {
      await load(() async {
        final account = await CloakWalletManager.createWallet(
          name,
          _seed,
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

        if (mounted) GoRouter.of(context).go('/account');
      });
    } catch (e) {
      print('[CreateWallet] Error creating wallet: $e');
      if (mounted) showSnackBar('Failed to create wallet. Please try again.');
    }
  }
}
