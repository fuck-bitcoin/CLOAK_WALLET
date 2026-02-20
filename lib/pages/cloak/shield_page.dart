// Shield Page - Transfer tokens from Telos to shielded CLOAK wallet
//
// This page enables users to shield ANY EOSIO token from their Telos wallet
// directly within the CLOAK wallet app. Uses ESR protocol to open Anchor
// for transaction signing - private keys never touch this app.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/eosio_client.dart';
import '../../cloak/esr_service.dart';
import '../../cloak/shield_state.dart';
import '../../theme/zashi_tokens.dart';
import 'esr_display_dialog.dart';

/// Shield tokens from Telos into shielded CLOAK wallet
class ShieldPage extends StatefulWidget {
  const ShieldPage({super.key});

  @override
  State<ShieldPage> createState() => _ShieldPageState();
}

class _ShieldPageState extends State<ShieldPage> {
  final _accountController = TextEditingController();
  final _amountController = TextEditingController();
  final _amountFocus = FocusNode();

  // UI constants matching Send flow exactly
  static const _addressFillColor = Color(0xFF2E2C2C);

  String? _vaultHash;
  bool _loadingVaultHash = true;
  bool _vaultPublished = false;
  bool _isPublishing = false;
  String _shieldFeeDisplay = '0.3000 CLOAK';

  @override
  void initState() {
    super.initState();
    // Start with a clean state - don't persist account between sessions
    shieldStore.clear();
    // Load vault hash
    _loadVaultHash();
  }

  Future<void> _loadVaultHash() async {
    print('[ShieldPage] _loadVaultHash starting...');
    try {
      // NOTE: Do NOT call getVaults() or getPrimaryVaultHash() - they use FFI that crashes!
      // Instead, use the stored vault hash from database
      String? vaultHash = await CloakWalletManager.getStoredVaultHash();
      print('[ShieldPage] Stored vault hash: ${vaultHash ?? "null"}');

      // If no stored hash, create a vault
      if (vaultHash == null || vaultHash.isEmpty) {
        print('[ShieldPage] No stored vault hash, creating vault...');
        vaultHash = await CloakWalletManager.createAndStoreVault();
        print('[ShieldPage] Created vault hash: ${vaultHash ?? "null"}');
      }

      // Check if vault is published
      final isPublished = await CloakWalletManager.isVaultPublished();
      print('[ShieldPage] Vault published: $isPublished');

      // Fetch dynamic shield fee from chain
      final fee = await CloakWalletManager.getShieldFee();
      print('[ShieldPage] Shield fee: $fee');

      if (mounted) {
        setState(() {
          _vaultHash = vaultHash;
          _vaultPublished = isPublished;
          _loadingVaultHash = false;
          _shieldFeeDisplay = fee;
        });
        print('[ShieldPage] State updated, _vaultHash=${_vaultHash != null ? "set" : "null"}, published=$_vaultPublished');
      }
    } catch (e, stack) {
      print('[ShieldPage] Error loading vault hash: $e');
      print('[ShieldPage] Stack: $stack');
      if (mounted) {
        setState(() => _loadingVaultHash = false);
      }
    }
  }

  @override
  void dispose() {
    // Clear the store when navigating away
    shieldStore.clear();
    _accountController.dispose();
    _amountController.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    // Match send.dart chip styling exactly
    final chipBgColor = Color.lerp(_addressFillColor, Colors.black, 0.06) ?? _addressFillColor;
    final chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
    final balanceTextColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Builder(builder: (context) {
          final t = Theme.of(context);
          final base = t.appBarTheme.titleTextStyle ??
              t.textTheme.titleLarge ??
              t.textTheme.titleMedium ??
              t.textTheme.bodyMedium;
          final reduced = (base?.fontSize != null)
              ? base!.copyWith(fontSize: base.fontSize! * 0.75)
              : base;
          return Text('SHIELD ASSETS', style: reduced);
        }),
        centerTitle: true,
        actions: [
          // DEBUG: Test simple transfer ESR
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: _testSimpleEsr,
            tooltip: 'Test ESR (debug)',
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelpDialog,
            tooltip: 'How shielding works',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Gap(8),

              // Section 0: Vault Deposit Info (NEW - simpler method)
              _buildVaultSection(context, t, balanceFontFamily, balanceTextColor),
              const Gap(16),

              // Divider with "OR" text
              Row(
                children: [
                  Expanded(child: Divider(color: balanceTextColor.withOpacity(0.3))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('OR USE ESR', style: TextStyle(color: balanceTextColor.withOpacity(0.5), fontSize: 12)),
                  ),
                  Expanded(child: Divider(color: balanceTextColor.withOpacity(0.3))),
                ],
              ),
              const Gap(16),

              // Section 1: Telos Account Input
              Align(
                alignment: Alignment.center,
                child: FractionallySizedBox(
                  widthFactor: 0.96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'From Telos Account',
                        style: t.textTheme.titleSmall?.copyWith(fontFamily: balanceFontFamily),
                      ),
                      const Gap(8),
                      _buildAccountInput(context, t, balanceFontFamily, chipBgColor, chipBorderColor, balanceTextColor),
                    ],
                  ),
                ),
              ),
              const Gap(24),

              // Section 2: Asset Selection Dropdown
              Observer(builder: (context) {
                if (!shieldStore.hasAccount) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select Asset',
                          style: t.textTheme.titleSmall?.copyWith(fontFamily: balanceFontFamily),
                        ),
                        const Gap(8),
                        _buildAssetSelector(context, t, balanceFontFamily, balanceTextColor),
                        const Gap(24),
                      ],
                    ),
                  ),
                );
              }),

              // Section 3: Amount Input
              Observer(builder: (context) {
                if (shieldStore.selectedToken == null) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Amount to Shield',
                          style: t.textTheme.titleSmall?.copyWith(fontFamily: balanceFontFamily),
                        ),
                        const Gap(8),
                        _buildAmountInput(context, t, balanceFontFamily, chipBgColor, chipBorderColor, balanceTextColor),
                        const Gap(8),
                        _buildBalanceHint(context, balanceFontFamily),
                        const Gap(24),
                      ],
                    ),
                  ),
                );
              }),

              // Section 4: Fee Info
              Observer(builder: (context) {
                if (shieldStore.selectedToken == null) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: Column(
                      children: [
                        _buildFeeInfo(context),
                        const Gap(24),
                      ],
                    ),
                  ),
                );
              }),

              // Section 5: Flow Diagram
              Observer(builder: (context) {
                if (shieldStore.selectedToken == null) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: Column(
                      children: [
                        _buildFlowDiagram(context),
                        const Gap(24),
                      ],
                    ),
                  ),
                );
              }),

              // Section 6: Error Message
              Observer(builder: (context) {
                final error = shieldStore.error;
                if (error == null) return const SizedBox.shrink();
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: Column(
                      children: [
                        _buildErrorCard(error),
                        const Gap(16),
                      ],
                    ),
                  ),
                );
              }),

              // Section 7: Shield Button
              Observer(builder: (context) {
                return Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.96,
                    child: _buildShieldButton(context, t, balanceFontFamily, balanceTextColor),
                  ),
                );
              }),

              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  /// Account input field with verify button (matches send.dart TextField styling)
  Widget _buildAccountInput(
    BuildContext context,
    ThemeData t,
    String? balanceFontFamily,
    Color chipBgColor,
    Color chipBorderColor,
    Color balanceTextColor,
  ) {
    return TextField(
      controller: _accountController,
      cursorColor: balanceTextColor,
      style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontFamily: balanceFontFamily,
        color: t.colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: 'e.g., myaccount123',
        hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontFamily: balanceFontFamily,
          fontWeight: FontWeight.w400,
          color: t.colorScheme.onSurface.withOpacity(0.7),
        ),
        filled: true,
        fillColor: WidgetStateColor.resolveWith((_) => _addressFillColor),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        prefixIcon: Icon(Icons.account_circle_outlined, color: t.colorScheme.onSurface.withOpacity(0.5)),
        suffixIcon: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Observer(builder: (context) {
            if (shieldStore.isLoadingTokens) {
              return const SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            return _SuffixChip(
              icon: Icon(Icons.check_circle_outline, size: 18, color: t.colorScheme.onSurface),
              backgroundColor: chipBgColor,
              borderColor: chipBorderColor,
              onTap: _verifyAccount,
            );
          }),
        ),
      ),
      onSubmitted: (_) => _verifyAccount(),
      textInputAction: TextInputAction.next,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-z1-5.]')),
        LengthLimitingTextInputFormatter(12),
      ],
    );
  }

  /// Asset selector button that opens a bottom sheet
  Widget _buildAssetSelector(
    BuildContext context,
    ThemeData t,
    String? balanceFontFamily,
    Color balanceTextColor,
  ) {
    return Observer(builder: (context) {
      final tokens = shieldStore.availableTokens;
      final selected = shieldStore.selectedToken;

      // Show loading state first
      if (shieldStore.isLoadingTokens) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _addressFillColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
              const Gap(12),
              Text(
                'Loading assets...',
                style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontFamily: balanceFontFamily,
                  color: t.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      }

      // Show no tokens message only after loading completes
      if (tokens.isEmpty) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _addressFillColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: t.colorScheme.onSurface.withOpacity(0.5)),
              const Gap(12),
              Text(
                'No tokens found in this account',
                style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontFamily: balanceFontFamily,
                  color: t.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      }

      // Button that opens the asset selection sheet
      return Material(
        color: _addressFillColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showAssetSelectionSheet(context, t, balanceFontFamily),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // Token icon or placeholder
                if (selected != null) ...[
                  _TokenIcon(
                    logoUrl: selected.bestLogoUrl,
                    symbol: selected.symbol,
                    size: 32,
                    fallbackColor: _getTokenColor(selected.symbol),
                  ),
                  const Gap(12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected.symbol,
                          style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${selected.amount} available',
                          style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            color: t.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Icon(Icons.token, color: t.colorScheme.onSurface.withOpacity(0.5), size: 32),
                  const Gap(12),
                  Expanded(
                    child: Text(
                      'Select an asset',
                      style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                        fontFamily: balanceFontFamily,
                        color: t.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ),
                ],
                Icon(Icons.chevron_right, color: t.colorScheme.onSurface.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// Show bottom sheet for asset selection with search
  void _showAssetSelectionSheet(BuildContext context, ThemeData t, String? balanceFontFamily) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AssetSelectionSheet(
        tokens: shieldStore.availableTokens.toList(),
        fontFamily: balanceFontFamily,
        onSelect: (token) {
          shieldStore.selectToken(token);
          _amountController.clear();
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Color _getTokenColor(String symbol) {
    switch (symbol) {
      case 'CLOAK':
        return Colors.purple;
      case 'TLOS':
        return Colors.blue;
      case 'USDT':
        return Colors.green;
      case 'USDC':
        return Colors.blue[700]!;
      default:
        return Colors.grey[600]!;
    }
  }

  /// Amount input with MAX chip (matches send.dart ZashiAmountRow styling)
  Widget _buildAmountInput(
    BuildContext context,
    ThemeData t,
    String? balanceFontFamily,
    Color chipBgColor,
    Color chipBorderColor,
    Color balanceTextColor,
  ) {
    return Observer(builder: (context) {
      final token = shieldStore.selectedToken;
      return TextField(
        controller: _amountController,
        focusNode: _amountFocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        cursorColor: balanceTextColor,
        style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontFamily: balanceFontFamily,
          color: balanceTextColor,
          fontSize: 20,
        ),
        decoration: InputDecoration(
          hintText: '0.0000',
          hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontFamily: balanceFontFamily,
            fontWeight: FontWeight.w400,
            color: balanceTextColor.withOpacity(0.7),
            fontSize: 20,
          ),
          filled: true,
          fillColor: WidgetStateColor.resolveWith((_) => _addressFillColor),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          suffixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Symbol badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: chipBgColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: chipBorderColor),
                  ),
                  child: Text(
                    token?.symbol ?? 'TOKEN',
                    style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                ),
                const Gap(8),
                // MAX button
                _SuffixChip(
                  icon: Text(
                    'MAX',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                  backgroundColor: chipBgColor,
                  borderColor: chipBorderColor,
                  onTap: () {
                    shieldStore.setMaxAmount();
                    _amountController.text = shieldStore.amount;
                  },
                ),
              ],
            ),
          ),
        ),
        onChanged: (value) => shieldStore.setAmount(value),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
        ],
      );
    });
  }

  /// Balance hint below amount input
  Widget _buildBalanceHint(BuildContext context, String? balanceFontFamily) {
    final t = Theme.of(context);
    return Observer(builder: (context) {
      final token = shieldStore.selectedToken;
      if (token == null) return const SizedBox.shrink();

      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            'Available: ',
            style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
              fontFamily: balanceFontFamily,
              color: t.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          Text(
            token.quantity,
            style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
              fontFamily: balanceFontFamily,
              color: Colors.green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    });
  }

  /// Fee information card
  Widget _buildFeeInfo(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.amber[700], size: 20),
          const Gap(8),
          Expanded(
            child: Text(
              'Shield fee: $_shieldFeeDisplay (paid separately)',
              style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: Colors.amber[700],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Visual flow diagram
  Widget _buildFlowDiagram(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _addressFillColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        children: [
          _FlowStep(
            number: '1',
            title: 'Anchor Opens',
            subtitle: 'Review & approve transaction',
            icon: Icons.open_in_new,
          ),
          _FlowArrow(),
          _FlowStep(
            number: '2',
            title: 'ZK Proof Generated',
            subtitle: 'Creates encrypted shielded note',
            icon: Icons.lock_outline,
          ),
          _FlowArrow(),
          _FlowStep(
            number: '3',
            title: 'Tokens Shielded',
            subtitle: 'Appears in your CLOAK wallet',
            icon: Icons.shield,
          ),
        ],
      ),
    );
  }

  /// Error message card
  Widget _buildErrorCard(String error) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.colorScheme.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.colorScheme.error.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: t.colorScheme.error, size: 20),
          const Gap(8),
          Expanded(
            child: Text(
              error,
              style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: t.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Main shield button (matches send.dart Review button styling)
  Widget _buildShieldButton(
    BuildContext context,
    ThemeData t,
    String? balanceFontFamily,
    Color balanceTextColor,
  ) {
    return Observer(builder: (context) {
      final isLoading = shieldStore.isShielding;
      final canShield = shieldStore.canShield;
      final status = shieldStore.statusMessage;

      return Column(
        children: [
          SizedBox(
            height: 48,
            child: Material(
              color: canShield && !isLoading ? balanceTextColor : Colors.grey[800],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: canShield && !isLoading ? _initiateShield : null,
                child: Center(
                  child: isLoading
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            ),
                            const Gap(12),
                            Text(
                              status ?? 'Processing...',
                              style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                                fontFamily: balanceFontFamily,
                                fontWeight: FontWeight.w600,
                                color: t.colorScheme.surface,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.shield, size: 20, color: t.colorScheme.surface),
                            const Gap(8),
                            Text(
                              'Shield',
                              style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                                fontFamily: balanceFontFamily,
                                fontWeight: FontWeight.w600,
                                color: t.colorScheme.surface,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          if (status != null && isLoading) ...[
            const Gap(8),
            Text(
              status,
              style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: t.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
          const Gap(8),
          TextButton.icon(
            onPressed: !isLoading && shieldStore.telosAccountName != null
                ? _clearAssetBuffer
                : null,
            icon: const Icon(Icons.cleaning_services, size: 16),
            label: const Text('Clear Asset Buffer'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange[300],
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      );
    });
  }

  /// Verify account and fetch tokens
  Future<void> _verifyAccount() async {
    final accountName = _accountController.text.trim().toLowerCase();
    if (accountName.isEmpty) return;

    // Validate format
    if (!RegExp(r'^[a-z1-5.]{1,12}$').hasMatch(accountName)) {
      shieldStore.setError('Invalid account format (1-12 chars: a-z, 1-5, .)');
      return;
    }

    // Verify account exists
    final accountInfo = await getAccount(accountName);
    if (accountInfo == null) {
      shieldStore.setError('Account not found on Telos');
      return;
    }

    // Fetch tokens
    await shieldStore.setAccount(accountName);
  }

  /// Initiate the shield operation
  ///
  /// This uses the CLEOS-style 2-step flow:
  /// 1. Generate ZK proof and create ESR with ONLY user's transfer actions
  /// 2. User signs transfers in Anchor (via QR code or copy/paste)
  /// 3. Combine user's signature with thezeosalias signature
  /// 4. Broadcast complete transaction directly via push_transaction (like cleos)
  Future<void> _initiateShield() async {
    final token = shieldStore.selectedToken;
    if (token == null) return;

    shieldStore.setShielding(true);
    shieldStore.setStatus('Generating ZK proof...');
    shieldStore.setError(null);

    try {
      // Format quantity with proper precision
      final amount = double.parse(shieldStore.amount);
      final quantity =
          '${amount.toStringAsFixed(token.precision)} ${token.symbol}';

      shieldStore.setStatus('Preparing transaction...');

      // CLEOS-style flow: Generate ESR with ONLY user's transfer actions
      // The mint proof is stored separately for use after Anchor signs
      final shieldData = await CloakWalletManager.generateShieldEsrSimple(
        tokenContract: token.contract,
        quantity: quantity,
        telosAccount: shieldStore.telosAccountName!,
      );

      final esrUrl = shieldData['esrUrl'] as String;

      shieldStore.setShielding(false);

      if (mounted) {
        // Show the ESR display dialog with QR code
        // Pass shieldData so we can complete the transaction after Anchor signs
        final result = await EsrDisplayDialog.show(
          context,
          esrUrl: esrUrl,
          title: 'Sign Token Transfers',
          subtitle: 'Scan with Anchor to approve your token transfers.\n'
              'The ZK proof will be added and broadcast automatically.',
          shieldData: shieldData,
        );

        // If result is not null, transaction was broadcast successfully
        if (result != null && mounted) {
          // Handle both automatic and manual completion
          if (result['status'] == 'completed_manually') {
            await _showSuccessDialog(null);
          } else {
            final txId = result['transaction_id']?.toString();
            await _showSuccessDialog(txId);
          }
        }
      }
    } catch (e) {
      shieldStore.setError(e.toString());
      shieldStore.setShielding(false);
    }
  }

  /// Clear the on-chain assetbuffer by sending begin + fee + end (no mint).
  /// This removes orphaned entries from previous failed transactions.
  Future<void> _clearAssetBuffer() async {
    final accountName = shieldStore.telosAccountName;
    if (accountName == null || accountName.isEmpty) {
      shieldStore.setError('Enter your Telos account name first');
      return;
    }

    shieldStore.setShielding(true);
    shieldStore.setStatus('Preparing buffer clear...');
    shieldStore.setError(null);

    try {
      final data = await CloakWalletManager.generateClearBufferEsr(
        telosAccount: accountName,
      );

      final esrUrl = data['esrUrl'] as String;
      shieldStore.setShielding(false);

      if (mounted) {
        final result = await EsrDisplayDialog.show(
          context,
          esrUrl: esrUrl,
          title: 'Clear Asset Buffer',
          subtitle: 'Sign to clear orphaned buffer entries.\nCost: 0.2000 CLOAK (begin fee).',
        );

        if (result != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Asset buffer cleared! You can now shield.')),
          );
        }
      }
    } catch (e) {
      shieldStore.setError(e.toString());
      shieldStore.setShielding(false);
    }
  }

  /// Show success dialog after transaction is broadcast
  Future<void> _showSuccessDialog([String? txId]) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            Gap(8),
            Text('Shield Complete!'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your tokens have been shielded successfully!\n\n'
              'They will appear in your private CLOAK wallet after the next sync.',
            ),
            if (txId != null) ...[
              const Gap(16),
              Text(
                'Transaction ID:',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const Gap(4),
              Text(
                txId.length > 16 ? '${txId.substring(0, 16)}...' : txId,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              GoRouter.of(context).pop();
            },
            child: const Text('DONE'),
          ),
        ],
      ),
    );
  }

  /// Show help dialog explaining shielding
  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How Shielding Works'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '1. Enter your Telos account name\n'
                '2. Select the token to shield\n'
                '3. Enter the amount\n'
                '4. Click Shield - Anchor wallet will open\n'
                '5. Approve the transaction in Anchor\n'
                '6. Your tokens become private!\n\n'
                'Shielded tokens are protected by zero-knowledge '
                'proofs. Only you can see your balance and '
                'transaction history.',
                style: TextStyle(height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  /// Build the vault section for simple deposit flow via ESR
  /// Uses the simpler vault deposit method: just transfer to thezeosvault with AUTH memo
  Widget _buildVaultSection(
    BuildContext context,
    ThemeData t,
    String? balanceFontFamily,
    Color balanceTextColor,
  ) {
    print('[ShieldPage] _buildVaultSection: _loadingVaultHash=$_loadingVaultHash, _vaultHash=${_vaultHash != null ? "exists" : "null"}');
    final hasVault = _vaultHash != null && _vaultHash!.isNotEmpty;

    if (_loadingVaultHash) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _addressFillColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _addressFillColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.green.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet,
                      color: Colors.green,
                      size: 20,
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'VAULT DEPOSIT',
                          style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w600,
                            color: Colors.green,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          hasVault
                              ? (_vaultPublished ? 'Ready to receive deposits' : 'Not yet published - publish below')
                              : 'Create a vault first',
                          style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                            color: _vaultPublished ? Colors.green.withOpacity(0.8) : Colors.orange.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Gap(16),

              if (!hasVault) ...[
                // No vault - show create button
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: Colors.orange, size: 18),
                      const Gap(8),
                      Expanded(
                        child: Text(
                          'You need to create a vault first. This generates a unique deposit address for your shielded wallet.',
                          style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                            color: t.colorScheme.onSurface.withOpacity(0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Gap(12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isCreatingVault ? null : _createVault,
                    icon: _isCreatingVault
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.add_circle_outline, size: 20),
                    label: Text(
                      _isCreatingVault ? 'Creating...' : 'CREATE VAULT',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ] else ...[
                // Has vault - show vault info and deposit button
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your Vault Hash:',
                        style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                          fontWeight: FontWeight.w600,
                          color: t.colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                      const Gap(4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_vaultHash!.substring(0, 20)}...${_vaultHash!.substring(_vaultHash!.length - 8)}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: t.colorScheme.onSurface.withOpacity(0.9),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: 'AUTH:$_vaultHash'));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Vault memo copied to clipboard')),
                              );
                            },
                            tooltip: 'Copy vault memo',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Gap(12),
                // Info text
                Text(
                  'Fill in your Telos account, token, and amount below, then tap "Shield via Vault".',
                  style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                    color: t.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const Gap(12),
                // Vault publish or deposit button
                Observer(builder: (context) {
                  final hasAccount = shieldStore.hasAccount;
                  final hasToken = shieldStore.selectedToken != null;
                  final hasAmount = shieldStore.amount.isNotEmpty;

                  // If vault is NOT published, show publish button
                  if (!_vaultPublished) {
                    final canPublish = hasAccount && !_isPublishing;
                    return Column(
                      children: [
                        // Warning about publishing
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber, color: Colors.orange[700], size: 20),
                              const Gap(8),
                              Expanded(
                                child: Text(
                                  'Vault must be published to blockchain first. This requires 0.3 CLOAK fee.',
                                  style: TextStyle(color: Colors.orange[700], fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Gap(12),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: canPublish ? _publishVault : null,
                            icon: _isPublishing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.publish, size: 20),
                            label: Text(
                              _isPublishing ? 'Publishing...' : 'PUBLISH VAULT TO BLOCKCHAIN',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey[800],
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    );
                  }

                  // Vault is published - show deposit button
                  final canDeposit = hasAccount && hasToken && hasAmount && !_isVaultDepositing;
                  return SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: canDeposit ? () => _initiateVaultDeposit(_vaultHash!) : null,
                      icon: _isVaultDepositing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.shield, size: 20),
                      label: Text(
                        _isVaultDepositing ? 'Processing...' : 'SHIELD VIA VAULT',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey[800],
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  );
                }),
              ],
            ],
          ),
        );
  }

  bool _isCreatingVault = false;
  bool _isVaultDepositing = false;

  /// Publish vault to blockchain directly (no ESR/Anchor needed).
  /// All publish actions only need thezeosalias@public signing,
  /// so we sign locally and push via HTTP.
  Future<void> _publishVault() async {
    final telosAccount = shieldStore.telosAccountName;
    if (telosAccount == null || telosAccount.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your Telos account first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isPublishing = true);

    try {
      print('[ShieldPage] Publishing vault directly for account: $telosAccount');

      final txId = await CloakWalletManager.publishVaultDirect();

      if (mounted) {
        setState(() => _vaultPublished = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Vault published! TX: ${txId.substring(0, 16)}...'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[ShieldPage] Error publishing vault: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPublishing = false);
      }
    }
  }

  /// Create a new vault
  Future<void> _createVault() async {
    setState(() => _isCreatingVault = true);

    try {
      final hash = await CloakWalletManager.createAndStoreVault();
      if (hash == null) {
        throw Exception('Failed to create vault');
      }

      if (mounted) {
        setState(() => _vaultHash = hash); // Update state to show vault info
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vault created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCreatingVault = false);
      }
    }
  }

  /// Initiate a vault deposit via ESR
  Future<void> _initiateVaultDeposit(String vaultHash) async {
    final token = shieldStore.selectedToken;
    if (token == null) return;

    setState(() => _isVaultDepositing = true);

    try {
      // Format quantity with proper precision
      final amount = double.parse(shieldStore.amount);
      final quantity = '${amount.toStringAsFixed(token.precision)} ${token.symbol}';
      final memo = 'AUTH:$vaultHash';

      print('[ShieldPage] Vault deposit: $quantity to thezeosvault with memo $memo');

      // Build ESR with just a transfer action
      final esrUrl = EsrService.createSigningRequest(
        actions: [
          {
            'account': token.contract,
            'name': 'transfer',
            'authorization': [
              {'actor': EsrService.actorPlaceholder, 'permission': EsrService.permissionPlaceholder}
            ],
            'data': {
              'from': EsrService.actorPlaceholder,
              'to': 'thezeosvault',
              'quantity': quantity,
              'memo': memo,
            },
          },
        ],
      );

      if (mounted) {
        // Show the ESR display dialog
        final result = await EsrDisplayDialog.show(
          context,
          esrUrl: esrUrl,
          title: 'Vault Deposit',
          subtitle: 'Sign this transfer in Anchor to deposit $quantity to your vault.',
        );

        // Show success if user completed
        if (result != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Vault deposit initiated! Tokens will appear after sync.'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isVaultDepositing = false);
      }
    }
  }

  /// DEBUG: Test simple transfer ESR to verify basic encoding works
  Future<void> _testSimpleEsr() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generating test ESR...')),
    );

    try {
      final esrUrl = await CloakWalletManager.testSimpleTransferEsr();
      if (mounted) {
        // Show the ESR display dialog
        await EsrDisplayDialog.show(
          context,
          esrUrl: esrUrl,
          title: 'Test ESR',
          subtitle: 'This is a test transfer of 0.0001 TLOS. Scan with Anchor or copy the link.',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

/// Suffix chip button matching send.dart _SuffixChip exactly
class _SuffixChip extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;
  final Color backgroundColor;
  final Color borderColor;

  const _SuffixChip({
    required this.icon,
    required this.onTap,
    required this.backgroundColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: borderColor)),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(child: icon),
        ),
      ),
    );
  }
}

/// Token row in dropdown with proper styling and token images
class _TokenRow extends StatelessWidget {
  final TokenBalance token;
  final String? fontFamily;

  const _TokenRow({required this.token, this.fontFamily});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Use a single row with compact layout to avoid overflow
    return SizedBox(
      height: 40, // Fixed height to prevent overflow
      child: Row(
        children: [
          // Token icon - use bestLogoUrl from TokenBalance
          _TokenIcon(
            logoUrl: token.bestLogoUrl,
            symbol: token.symbol,
            size: 28,
            fallbackColor: _getTokenColor(token.symbol),
          ),
          const Gap(10),
          // Symbol and contract in a single compact display
          Expanded(
            child: Text(
              '${token.symbol} (${token.contract})',
              style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                fontFamily: fontFamily,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Gap(8),
          // Amount
          Text(
            token.amount,
            style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
              fontFamily: fontFamily,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Color _getTokenColor(String symbol) {
    switch (symbol) {
      case 'CLOAK':
        return Colors.purple;
      case 'TLOS':
        return Colors.blue;
      case 'USDT':
        return Colors.green;
      case 'USDC':
        return Colors.blue[700]!;
      case 'BTC':
      case 'WBTC':
        return Colors.orange;
      case 'ETH':
      case 'WETH':
        return Colors.indigo;
      default:
        return Colors.grey[600]!;
    }
  }
}

/// Token icon widget that fetches from Telos token lists or shows fallback
/// Supports 'asset:' prefix for local Flutter assets
/// - White background with drop shadow when image is available
/// - Colored background with letter fallback when no image
class _TokenIcon extends StatefulWidget {
  final String? logoUrl;  // Pre-computed best logo URL from TokenBalance
  final String symbol;
  final double size;
  final Color fallbackColor;

  const _TokenIcon({
    this.logoUrl,
    required this.symbol,
    required this.size,
    required this.fallbackColor,
  });

  @override
  State<_TokenIcon> createState() => _TokenIconState();
}

class _TokenIconState extends State<_TokenIcon> {
  bool _imageLoadFailed = false;

  bool get _hasImage => widget.logoUrl != null && widget.logoUrl!.isNotEmpty && !_imageLoadFailed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: _hasImage ? Colors.white : widget.fallbackColor,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildImage(context),
    );
  }

  Widget _buildImage(BuildContext context) {
    if (widget.logoUrl == null || widget.logoUrl!.isEmpty) {
      return _buildFallback(context);
    }

    // Check if it's a local asset (prefixed with 'asset:')
    if (widget.logoUrl!.startsWith('asset:')) {
      final assetPath = widget.logoUrl!.substring(6); // Remove 'asset:' prefix
      return Image.asset(
        assetPath,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _imageLoadFailed = true);
          });
          return _buildFallback(context);
        },
      );
    }

    // Network image
    return Image.network(
      widget.logoUrl!,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _imageLoadFailed = true);
        });
        return _buildFallback(context);
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        // Show loading placeholder with white background
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildFallback(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      color: widget.fallbackColor,
      child: Center(
        child: Text(
          widget.symbol.isNotEmpty ? widget.symbol[0] : '?',
          style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: widget.size * 0.45,
          ),
        ),
      ),
    );
  }
}

/// Flow step widget with proper theme integration
class _FlowStep extends StatelessWidget {
  final String number;
  final String title;
  final String subtitle;
  final IconData icon;

  const _FlowStep({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const Gap(12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                  color: t.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
        Icon(icon, color: t.colorScheme.onSurface.withOpacity(0.6)),
      ],
    );
  }
}

/// Arrow between flow steps
class _FlowArrow extends StatelessWidget {
  const _FlowArrow();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 15),
      child: Column(
        children: [
          Container(width: 2, height: 8, color: t.colorScheme.onSurface.withOpacity(0.3)),
          Icon(Icons.arrow_drop_down, color: t.colorScheme.onSurface.withOpacity(0.3), size: 16),
        ],
      ),
    );
  }
}

/// Bottom sheet for asset selection with search
class _AssetSelectionSheet extends StatefulWidget {
  final List<TokenBalance> tokens;
  final String? fontFamily;
  final void Function(TokenBalance) onSelect;

  const _AssetSelectionSheet({
    required this.tokens,
    required this.onSelect,
    this.fontFamily,
  });

  @override
  State<_AssetSelectionSheet> createState() => _AssetSelectionSheetState();
}

class _AssetSelectionSheetState extends State<_AssetSelectionSheet> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TokenBalance> get _filteredTokens {
    if (_searchQuery.isEmpty) return widget.tokens;
    final query = _searchQuery.toLowerCase();
    return widget.tokens.where((token) {
      return token.symbol.toLowerCase().contains(query) ||
          token.contract.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);

    // Full height minus status bar and a small top margin for visual appeal
    final sheetHeight = mediaQuery.size.height - mediaQuery.padding.top - 20;

    return Container(
      height: sheetHeight,
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          const Gap(12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[600],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Gap(16),

          // Title
          Text(
            'SELECT ASSET',
            style: (t.textTheme.titleMedium ?? const TextStyle()).copyWith(
              fontFamily: widget.fontFamily,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const Gap(16),

          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                fontFamily: widget.fontFamily,
              ),
              decoration: InputDecoration(
                hintText: 'Search by name or ticker...',
                hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontFamily: widget.fontFamily,
                  color: Colors.grey[500],
                ),
                prefixIcon: Icon(Icons.search, color: Colors.grey[500]),
                filled: true,
                fillColor: const Color(0xFF2E2C2C),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[600]!),
                ),
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),
          const Gap(16),

          // Token list
          Expanded(
            child: _filteredTokens.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
                        const Gap(8),
                        Text(
                          'No tokens found',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredTokens.length,
                    itemBuilder: (context, index) {
                      final token = _filteredTokens[index];
                      return _AssetListItem(
                        token: token,
                        fontFamily: widget.fontFamily,
                        onTap: () => widget.onSelect(token),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Individual asset item in the selection list
class _AssetListItem extends StatelessWidget {
  final TokenBalance token;
  final String? fontFamily;
  final VoidCallback onTap;

  const _AssetListItem({
    required this.token,
    required this.onTap,
    this.fontFamily,
  });

  Color _getTokenColor(String symbol) {
    switch (symbol) {
      case 'CLOAK':
        return Colors.purple;
      case 'TLOS':
        return Colors.blue;
      case 'USDT':
        return Colors.green;
      case 'USDC':
        return Colors.blue[700]!;
      case 'BTC':
      case 'WBTC':
        return Colors.orange;
      case 'ETH':
      case 'WETH':
        return Colors.indigo;
      default:
        return Colors.grey[600]!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              // Token icon
              _TokenIcon(
                logoUrl: token.bestLogoUrl,
                symbol: token.symbol,
                size: 40,
                fallbackColor: _getTokenColor(token.symbol),
              ),
              const Gap(12),

              // Token info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      token.symbol,
                      style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                        fontFamily: fontFamily,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      token.contract,
                      style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                        fontFamily: fontFamily,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),

              // Balance
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    token.amount,
                    style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                      fontFamily: fontFamily,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    token.symbol,
                    style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                      fontFamily: fontFamily,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
