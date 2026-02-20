import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/warp_api.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:bip39/src/wordlists/english.dart' as bip39_words;

import '../../store2.dart';
import '../utils.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../pages/widgets.dart';
import '../../theme/zashi_tokens.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/signature_provider.dart';

// Generate a new BIP39 seed phrase
// strength: 128 = 12 words (Zcash default), 256 = 24 words (CLOAK)
String _generateSeedPhrase({int strength = 128}) {
  return bip39.generateMnemonic(strength: strength);
}

class NewImportAccountPage extends StatefulWidget {
  final bool first;
  final SeedInfo? seedInfo;
  NewImportAccountPage({required this.first, this.seedInfo});

  @override
  State<StatefulWidget> createState() => _NewImportAccountState();
}

class _NewImportAccountState extends State<NewImportAccountPage>
    with WithLoadingAnimation {
  late final s = S.of(context);
  int coin = 0;
  final formKey = GlobalKey<FormBuilderState>();
  final nameController = TextEditingController();
  String _key = '';
  final accountIndexController = TextEditingController(text: '0');
  final birthdayHeightController = TextEditingController();
  late List<FormBuilderFieldOption<int>> options;
  bool _restore = false;
  // For CLOAK: 'wallet' = import main wallet seed, 'vault' = import vault seed
  String _cloakImportType = 'wallet';

  @override
  void initState() {
    super.initState();
    if (widget.first) nameController.text = 'Main';
    final si = widget.seedInfo;
    if (si != null) {
      _restore = true;
      _key = si.seed;
      accountIndexController.text = si.index.toString();
    }
    options = coins.map((c) {
      return FormBuilderFieldOption(
          child: ListTile(
            title: Text(c.name),
            trailing: Image(image: c.image, height: 32),
          ),
          value: c.coin);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return wrapWithLoading(Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(s.newAccount),
        actions: [
          IconButton(onPressed: _onOK, icon: Icon(Icons.add)),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(8),
        child: SingleChildScrollView(
          child: FormBuilder(
            key: formKey,
            child: Column(
              children: [
                Image.asset('assets/icon.png', height: 128),
                Gap(16),
                FormBuilderTextField(
                    name: 'name',
                    decoration: InputDecoration(labelText: s.accountName),
                    controller: nameController,
                    enableSuggestions: true,
                    validator: FormBuilderValidators.required()),
                FormBuilderRadioGroup<int>(
                  decoration: InputDecoration(labelText: s.crypto),
                  orientation: OptionsOrientation.vertical,
                  name: 'coin',
                  initialValue: coin,
                  onChanged: (int? v) {
                    setState(() {
                      coin = v!;
                    });
                  },
                  options: options,
                ),
                FormBuilderSwitch(
                  name: 'restore',
                  title: Text(s.restoreAnAccount),
                  onChanged: (v) {
                    setState(() {
                      _restore = v!;
                      // Reset import type when toggling restore
                      _cloakImportType = 'wallet';
                    });
                  },
                ),
                // CLOAK import type selector (wallet vs vault)
                if (_restore && CloakWalletManager.isCloak(coin) && !widget.first)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Import Type', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        Gap(8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildImportTypeButton(
                                'wallet',
                                'CLOAK Wallet',
                                'Import main wallet seed',
                                Icons.account_balance_wallet,
                              ),
                            ),
                            Gap(8),
                            Expanded(
                              child: _buildImportTypeButton(
                                'vault',
                                'CLOAK Vault',
                                'Import vault auth token seed',
                                Icons.lock,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (_restore)
                  Column(children: [
                    InputTextQR(
                      _key,
                      label: _getKeyLabel(),
                      lines: 4,
                      onChanged: (v) => setState(() => _key = v!),
                      validator: _checkKey,
                    ),
                    // Hide birthday height and account index for vault import
                    if (!CloakWalletManager.isCloak(coin) || _cloakImportType != 'vault') ...[
                      Gap(16),
                      _buildOptionalFieldWithInfo(
                        context: context,
                        name: 'birthday_height',
                        label: 'Wallet Birthday Height',
                        controller: birthdayHeightController,
                        keyboardType: TextInputType.number,
                        infoTitle: 'What is Wallet Birthday Height?',
                        infoContent: 'The birthday height is the block number when your wallet was first created. '
                            'By entering this, the wallet only scans the blockchain from that point forward, '
                            'making sync much faster.\n\n'
                            'If you don\'t know your wallet\'s birthday height, you can leave this blank and the wallet '
                            'will scan from the beginning, which takes longer but finds all your transactions.',
                      ),
                      Gap(12),
                      _buildOptionalFieldWithInfo(
                        context: context,
                        name: 'account_index',
                        label: s.accountIndex,
                        controller: accountIndexController,
                        keyboardType: TextInputType.number,
                        infoTitle: 'What is Account Index?',
                        infoContent: 'The account index lets you create multiple accounts from the same seed phrase. '
                            'Most users only need account 0 (the default).\n\n'
                            'If you previously created additional accounts (1, 2, 3, etc.) in another wallet, '
                            'enter that number here to restore that specific account.',
                      ),
                    ],
                  ]),
                // TODO: Ledger
                // if (_restore && coins[coin].supportsLedger && !isMobile())
                //   Padding(
                //     padding: EdgeInsets.all(8),
                //     child: ElevatedButton(
                //       onPressed: _importLedger,
                //       child: Text('Import From Ledger'),
                //     ),
                //   ),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  /// Get the label for the key/seed input based on context
  String _getKeyLabel() {
    if (CloakWalletManager.isCloak(coin) && _cloakImportType == 'vault') {
      return 'Vault Auth Token Seed (24 words)';
    }
    return s.key;
  }

  /// Build a button for selecting CLOAK import type (wallet vs vault)
  Widget _buildImportTypeButton(String type, String title, String subtitle, IconData icon) {
    final isSelected = _cloakImportType == type;
    final t = Theme.of(context);

    return GestureDetector(
      onTap: () => setState(() => _cloakImportType = type),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
            ? t.colorScheme.primaryContainer
            : t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
              ? t.colorScheme.primary
              : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected
                    ? t.colorScheme.primary
                    : t.colorScheme.onSurfaceVariant,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isSelected
                        ? t.colorScheme.primary
                        : t.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle, size: 18, color: t.colorScheme.primary),
              ],
            ),
            SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionalFieldWithInfo({
    required BuildContext context,
    required String name,
    required String label,
    required TextEditingController controller,
    required TextInputType keyboardType,
    required String infoTitle,
    required String infoContent,
  }) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    return FormBuilderTextField(
      name: name,
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: '$label (Optional)',
        suffixIcon: IconButton(
          icon: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: balanceTextColor.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              'i',
              style: TextStyle(
                color: balanceTextColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          onPressed: () => _showInfoModal(context, infoTitle, infoContent),
        ),
      ),
    );
  }

  void _showInfoModal(BuildContext context, String title, String content) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w500,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor.withOpacity(0.9),
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
      height: 1.5,
    );

    final radius = BorderRadius.circular(14);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: radius),
        title: Text(title, style: titleStyle),
        content: Text(content, style: bodyStyle),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: Material(
              color: balanceTextColor,
              shape: RoundedRectangleBorder(borderRadius: radius),
              child: InkWell(
                borderRadius: radius,
                onTap: () => Navigator.of(context).pop(),
                child: Center(
                  child: Text(
                    'Got it',
                    style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.background,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  _onOK() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      form.save();
      await load(() async {
        final index = int.parse(accountIndexController.text);
        
        // Handle CLOAK differently - uses binary wallet file instead of SQLite
        int account;
        if (CloakWalletManager.isCloak(coin)) {
          final isRestoring = _key.isNotEmpty;
          final seed = isRestoring ? _key.trim() : _generateSeedPhrase(strength: 256);

          // Check if this is a vault import (only available when restoring and not first account)
          if (isRestoring && _cloakImportType == 'vault' && !widget.first) {
            // Importing a vault - requires existing CLOAK wallet
            print('[new_import] Importing vault...');

            final vaultResult = await CloakWalletManager.importVault(
              seed: seed,
              label: nameController.text.isEmpty ? null : nameController.text,
              accountId: aa.id,
            );

            if (vaultResult == null) {
              form.fields['name']!.invalidate('Failed to import vault');
              return;
            }

            // Show success with on-chain status
            final hash = vaultResult['commitment_hash'] as String? ?? '';
            final onChain = vaultResult['on_chain'] == true;
            final hashDisplay = hash.isEmpty ? 'unknown' : '${hash.substring(0, 16)}...';
            print('[new_import] Vault imported: $hashDisplay (on_chain=$onChain)');

            // Show success dialog with on-chain status
            if (mounted) {
              final title = onChain ? 'Vault Imported' : 'Vault Imported (Not Found On-Chain)';
              final message = onChain
                  ? 'Vault found on-chain and imported successfully.\n\nCommitment: $hashDisplay'
                  : 'Vault imported locally but was not found on the blockchain.\n\n'
                    'This may mean the vault was burned, or the seed doesn\'t match any existing vault.\n\n'
                    'Commitment: $hashDisplay';
              await showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Row(children: [
                    Icon(
                      onChain ? Icons.check_circle : Icons.warning_amber_rounded,
                      color: onChain ? Colors.green : Colors.orange,
                    ),
                    SizedBox(width: 8),
                    Expanded(child: Text(title)),
                  ]),
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('OK'),
                    ),
                  ],
                ),
              );
              GoRouter.of(context).pop();
            }
            return;
          }

          if (isRestoring) {
            // Restoring existing wallet - use restoreWallet for full sync
            print('[new_import] Calling restoreWallet...');
            // IMPORTANT: Must use thezeosalias@public for Telos mainnet
            account = await CloakWalletManager.restoreWallet(
              nameController.text,
              seed,
              aliasAuthority: 'thezeosalias@public',
            );
            print('[new_import] restoreWallet returned: $account');
          } else {
            // Creating new wallet - use createWallet (skips sync)
            print('[new_import] Calling createWallet...');
            // IMPORTANT: Must use thezeosalias@public for Telos mainnet
            account = await CloakWalletManager.createWallet(
              nameController.text,
              seed,
              aliasAuthority: 'thezeosalias@public',
            );
            print('[new_import] createWallet returned: $account');
          }
          // Refresh the accounts cache so UI can see the new account
          print('[new_import] Calling refreshCloakAccountsCache...');
          await refreshCloakAccountsCache();
          print('[new_import] refreshCloakAccountsCache done');

          // Start signature provider server for website auth
          print('[new_import] Starting signature provider...');
          final started = await SignatureProvider.start();
          print('[new_import] Signature provider ${started ? "started" : "failed to start"}');
        } else {
          // Zcash/Ycash use WarpApi
          account = await WarpApi.newAccount(coin, nameController.text, _key, index);
        }
        
        print('[new_import] account = $account');
        if (account < 0)
          form.fields['name']!.invalidate(s.thisAccountAlreadyExists);
        else {
          print('[new_import] Calling setActiveAccount($coin, $account)...');
          setActiveAccount(coin, account);
          print('[new_import] setActiveAccount done');
          final prefs = await SharedPreferences.getInstance();
          print('[new_import] Calling aa.save...');
          await aa.save(prefs);
          print('[new_import] aa.save done');
          
          // CLOAK doesn't use WarpApi for account counting
          if (!CloakWalletManager.isCloak(coin)) {
            final count = WarpApi.countAccounts(coin);
            if (count == 1 && _key.isEmpty) {
              // First account of a coin with NO seed: skip to latest height
              // (new wallet, no history to sync)
              await WarpApi.skipToLastHeight(coin);
            }
          }
          if (widget.first) {
            if (_key.isNotEmpty) {
              // Restoring from seed
              // CLOAK handles sync differently - just go to account page
              if (CloakWalletManager.isCloak(coin)) {
                GoRouter.of(context).go('/account');
              } else {
                // Zcash/Ycash restore flow
                final birthdayText = birthdayHeightController.text.trim();
                if (birthdayText.isNotEmpty) {
                  // User provided a birthday height - use it directly
                  final height = int.tryParse(birthdayText);
                  if (height != null && height > 0) {
                    syncStatus2.triggerBannerForRestore();
                    aa.reset(height);
                    Future(() => syncStatus2.rescan(height));
                    GoRouter.of(context).go('/account');
                  } else {
                    // Invalid height, go to rescan page
                    syncStatus2.triggerBannerForRestore();
                    GoRouter.of(context).go('/account/rescan');
                  }
                } else {
                  // No birthday height provided, let user choose on rescan page
                  syncStatus2.triggerBannerForRestore();
                  GoRouter.of(context).go('/account/rescan');
                }
              }
            } else
              GoRouter.of(context).go('/account');
          } else
            GoRouter.of(context).pop();
        }
      });
    }
  }

  String? _checkKey(String? v) {
    if (v == null || v.isEmpty) return null;

    // CLOAK uses 24-word BIP39 seed phrases - validate differently
    // Skip checksum validation since CLOAK seeds may not have standard BIP39 checksums
    if (CloakWalletManager.isCloak(coin)) {
      final words = v.trim().split(RegExp(r'\s+'));
      if (words.length != 24) {
        return 'CLOAK requires a 24-word seed phrase';
      }
      // Just verify each word is a valid BIP39 word (no checksum check)
      for (final word in words) {
        if (!bip39_words.WORDLIST.contains(word.toLowerCase())) {
          return 'Invalid word: "$word"';
        }
      }
      return null;
    }

    // Zcash/Ycash validation
    if (WarpApi.isValidTransparentKey(v)) return s.cannotUseTKey;
    final keyType = WarpApi.validKey(coin, v);
    if (keyType < 0) return s.invalidKey;
    return null;
  }

  _importLedger() async {
    try {
      final account =
          await WarpApi.importFromLedger(aa.coin, nameController.text);
      setActiveAccount(coin, account);
    } on String catch (msg) {
      formKey.currentState!.fields['key']!.invalidate(msg);
    }
  }
}
