import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
                    });
                  },
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
                    if (!CloakWalletManager.isCloak(coin)) ...[
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

  String _getKeyLabel() {
    return s.key;
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
          // Non-CLOAK coins no longer supported
          throw 'Only CLOAK accounts are supported';
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
          
          // CLOAK handles sync differently - no WarpApi account counting needed
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

    // Non-CLOAK key validation not available
    return s.invalidKey;
  }

  _importLedger() async {
    // Ledger import not supported for CLOAK
  }
}
