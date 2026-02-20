import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../theme/zashi_tokens.dart';

import '../../generated/intl/messages.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../cloak/cloak_db.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/atomic_assets_service.dart';
import '../../widgets/nft_image_widget.dart';
import '../cloak/nft_lightbox.dart';
import '../utils.dart';
import '../vote/migration.dart';
import 'balance.dart';
import 'sync_status.dart';
import 'qr_address.dart';
import '../scan.dart';
import '../splash.dart';
import '../tx.dart';
import '../../tablelist.dart';
import '../accounts/send.dart' show SendContext, BatchAsset;

/// Set to false to disable mock NFTs (for when real on-chain NFTs exist)
const _kMockNfts = true;

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      aaSequence.seqno; // observe for MobX reactivity
      // Key changes ONLY on account/vault switch, NOT on sync/poll ticks.
      // Vault switches keep same coin+id, so include activeVaultHash.
      final key = ValueKey('${aa.coin}:${aa.id}:${isVaultMode ? activeVaultHash : ""}');
      return HomePageInner(key: key);
    });
  }
}

class HomePageInner extends StatefulWidget {
  HomePageInner({super.key});
  @override
  State<StatefulWidget> createState() => _HomeState();
}

class _HomeState extends State<HomePageInner> {
  final key = GlobalKey<BalanceState>();
  int addressMode = coins[aa.coin].defaultAddrMode;
  int _selectedTab = 0;
  bool _hideFees = false;
  Timer? _vaultRefreshTimer;

  /// Check if wallet has any shielded NFTs
  bool _hasShieldedNfts() {
    if (_kMockNfts) return true;
    final nftRaw = CloakWalletManager.getNftsJson();
    if (nftRaw != null && nftRaw.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(nftRaw);
        if (parsed.isNotEmpty) return true;
      } catch (_) {}
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    syncStatus2.update();
    _injectMockIfEmpty();
    _loadFeeFilter();
    // Check for CLOAK wallet validation errors after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkCloakWalletValidation();
    });
    // Auto-refresh vault balance when in vault mode (polls chain every 5s)
    if (isVaultMode) {
      _vaultRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted && isVaultMode) {
          refreshActiveVaultBalance();
        }
      });
    }
  }

  @override
  void dispose() {
    _vaultRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFeeFilter() async {
    final saved = await CloakDb.getProperty('tx_filters');
    final hide = saved != null && saved.isNotEmpty && saved.split(',').contains('fees');
    if (mounted && hide != _hideFees) {
      setState(() => _hideFees = hide);
    }
  }

  /// Check for CLOAK wallet validation errors and show warning dialog
  void _checkCloakWalletValidation() {
    if (!CloakWalletManager.isCloak(aa.coin)) return;
    if (!appStore.hasCloakWalletErrors) return;

    // Show warning dialog for each error
    final errors = appStore.cloakWalletValidationErrors;
    if (errors.isNotEmpty) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
              SizedBox(width: 8),
              Flexible(child: Text('Wallet Configuration Error')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your CLOAK wallet has a configuration issue that will cause shield transactions to fail:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                ...errors.map((e) => Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(e, style: TextStyle(color: Colors.red[700])),
                )),
                SizedBox(height: 16),
                Text(
                  'To fix this, you need to:\n'
                  '1. Back up your seed phrase\n'
                  '2. Delete your CLOAK wallet\n'
                  '3. Restore from seed\n\n'
                  'This will recreate the wallet with the correct configuration.',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                // Clear errors so dialog doesn't show again this session
                appStore.cloakWalletValidationErrors = [];
                Navigator.of(ctx).pop();
              },
              child: Text('I UNDERSTAND'),
            ),
          ],
        ),
      );
    }
  }

  void _injectMockIfEmpty() {
    if (aa.txs.items.isNotEmpty) return;
    // No-op here if already populated. TxPage will inject mocks when history opens.
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SingleChildScrollView(
          child: Observer(
              builder: (context) {
                aaSequence.seqno;
                // Access pool balance properties to trigger MobX observation
                aa.poolBalances.transparent;
                aa.poolBalances.sapling;
                aa.poolBalances.orchard;
                syncStatus2.changed;
                migrationState.state; // Also observe migration state
                appStore.hideBalances; // Rebuild when eyeball toggle changes
                // Track TX list changes so Observer rebuilds when txs.read() updates items
                aa.txs.items.length;
                aa.txs.version;

                final bool isWatchOnly = !aa.canPay;
                return AnimatedSwitcher(
                  // Lengthen further for a clearer crossfade
                  duration: const Duration(milliseconds: 480),
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  child: KeyedSubtree(
                    // Preserve subtree to avoid sudden rebuilds during switch
                    key: ValueKey<int>(aa.id),
                    child: Column(
                    children: [
                      // SyncStatusWidget manages its own visibility including fade-out animation
                      SyncStatusWidget(),
                      // Migration banner for voting readiness (Zcash only, not CLOAK)
                      if (!CloakWalletManager.isCloak(aa.coin) &&
                          (hasAnyFunds() || migrationState.state != MigrationState.none))
                        _MigrationBanner(),
                      Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Column(children: [
                          if (isWatchOnly)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.secondary.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: Theme.of(context).colorScheme.secondary.withOpacity(0.6)),
                                    ),
                                    child: Text('Watch-Only', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface)),
                                  ),
                                ],
                              ),
                            ),
                          // Balance block first
                          BalanceWidget(
                            addressMode,
                            key: key,
                          ),
                          Gap(24),
                          // Catalog-styled quick actions under rate line (responsive width)
                          Builder(builder: (context) {
                            final screenWidth = MediaQuery.of(context).size.width;
                            const horizontalPadding = 32.0; // matches symmetric(horizontal:16)
                            const gap = 6.0; // 50% tighter than before
                            final available = screenWidth - horizontalPadding;
                            if (isVaultMode) {
                              // Vault quick actions: Deposit, Withdraw, Scan (3 buttons)
                              final tileSize = ((available - 2 * gap) / 3).clamp(72.0, 96.0).toDouble();
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _QuickActionTile(
                                    label: 'Deposit',
                                    asset: 'assets/icons/receive_quick.svg',
                                    onTap: () => _showVaultDeposit(context),
                                    tileSize: tileSize,
                                  ),
                                  const Gap(gap),
                                  _QuickActionTile(
                                    label: 'Withdraw',
                                    asset: 'assets/icons/send_quick.svg',
                                    onTap: () => _showVaultWithdraw(context),
                                    tileSize: tileSize,
                                  ),
                                  const Gap(gap),
                                  _QuickActionTile(
                                    label: 'Scan',
                                    asset: 'assets/icons/scan_quick.svg',
                                    onTap: () { scanQRCode(context); },
                                    tileSize: tileSize,
                                  ),
                                ],
                              );
                            } else if (isWatchOnly) {
                              final tileSize = available.clamp(72.0, 96.0).toDouble();
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _QuickActionTile(
                                    label: 'Receive',
                                    asset: 'assets/icons/receive_quick.svg',
                                    onTap: () => GoRouter.of(context).push('/account/receive'),
                                    tileSize: tileSize,
                                  ),
                                ],
                              );
                            } else {
                              final tileSize = ((available - 3 * gap) / 4).clamp(72.0, 96.0).toDouble();
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _QuickActionTile(
                                    label: 'Receive',
                                    asset: 'assets/icons/receive_quick.svg',
                                    onTap: () => GoRouter.of(context).push('/account/receive'),
                                    tileSize: tileSize,
                                  ),
                                  const Gap(gap),
                                  _QuickActionTile(
                                    label: s.send,
                                    asset: 'assets/icons/send_quick.svg',
                                    onTap: () => GoRouter.of(context).push('/account/quick_send'),
                                    tileSize: tileSize,
                                  ),
                                  const Gap(gap),
                                  _QuickActionTile(
                                    label: 'Scan',
                                    asset: 'assets/icons/scan_quick.svg',
                                    onTap: () { scanQRCode(context); },
                                    tileSize: tileSize,
                                  ),
                                  const Gap(gap),
                                  _QuickActionTile(
                                    label: s.more,
                                    asset: 'assets/icons/more_quick.svg',
                                    onTap: () => GoRouter.of(context).push('/more'),
                                    tileSize: tileSize,
                                  ),
                                ],
                              );
                            }
                          }),
                          // Reduce spacing under quick actions by 15px
                          const Gap(30),
                          // Heading above transaction history with right-aligned "See all >" pill
                          Builder(
                            builder: (context) {
                              final t = Theme.of(context);
                              final zashi = t.extension<ZashiThemeExt>();
                              final color = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                              final base = t.textTheme.bodyMedium ?? t.textTheme.titleMedium ?? t.textTheme.bodySmall;
                              final sized = (base?.fontSize != null)
                                  ? base!.copyWith(fontSize: base.fontSize! * 1.15, fontWeight: FontWeight.w700)
                                  : (base ?? const TextStyle(fontWeight: FontWeight.w700));
                              final style = sized.copyWith(color: color);
                              final txTextColor = zashi?.balanceAmountColor ?? t.colorScheme.onSurface;
                              final borderColor = zashi?.quickBorderColor ?? t.dividerColor;
                              // Flat fill to match transaction receive icon style (non‑gradient)
                              final flatFill = t.colorScheme.onSurface.withOpacity(0.12);

                              // "See all >" pill widget (reused below)
                              Widget seeAllPill() => SizedBox(
                                    width: kTxTrailingWidth,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Transform.scale(
                                        scale: 0.8,
                                        child: Material(
                                          color: Colors.transparent,
                                          shape: const StadiumBorder(),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: flatFill,
                                              borderRadius: BorderRadius.circular(999),
                                              border: Border.all(color: borderColor),
                                            ),
                                            child: InkWell(
                                              borderRadius: BorderRadius.circular(999),
                                              onTap: () => GoRouter.of(context).push('/activity_overlay').then((_) => _loadFeeFilter()),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 7.1, vertical: 5.4),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  crossAxisAlignment: CrossAxisAlignment.center,
                                                  children: [
                                                    SizedBox(width: ((base?.fontSize ?? 14.0) * 1.20) * 0.25),
                                                    Text(
                                                      'See all',
                                                      textAlign: TextAlign.center,
                                                      style: TextStyle(fontWeight: FontWeight.w700, color: txTextColor),
                                                    ),
                                                    const SizedBox(width: 2),
                                                    Icon(
                                                      Icons.chevron_right,
                                                      size: (base?.fontSize ?? 14.0) * 1.20,
                                                      color: txTextColor,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );

                              if (isVaultMode) {
                                // Vault mode: always Tokens + NFTs (no Activity)
                                final tabs = ['Tokens', 'NFTs'];
                                final safeTab = _selectedTab.clamp(0, tabs.length - 1);
                                if (safeTab != _selectedTab) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    setState(() => _selectedTab = safeTab);
                                  });
                                }
                                return _SegmentedToggle(
                                  selectedIndex: safeTab,
                                  labels: tabs,
                                  onChanged: (i) => setState(() => _selectedTab = i),
                                );
                              }

                              if (CloakWalletManager.isCloak(aa.coin)) {
                                // Check if NFTs exist to determine tab count
                                final hasNfts = _hasShieldedNfts();
                                final tabs = hasNfts
                                    ? ['Activity', 'Tokens', 'NFTs']
                                    : ['Activity', 'Tokens'];
                                // Clamp selectedTab if NFTs tab disappeared
                                final safeTab = _selectedTab.clamp(0, tabs.length - 1);
                                if (safeTab != _selectedTab) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    setState(() => _selectedTab = safeTab);
                                  });
                                }
                                return _SegmentedToggle(
                                  selectedIndex: safeTab,
                                  labels: tabs,
                                  onChanged: (i) => setState(() => _selectedTab = i),
                                );
                              }

                              // Non-CLOAK: original "Transactions" heading + pill
                              return Row(
                                children: [
                                  Expanded(child: Text('Transactions', style: style)),
                                  seeAllPill(),
                                ],
                              );
                            },
                          ),
                          const Gap(6),
                          // Embedded History preview under quick menu (limit to 5 most recent)
                          Builder(builder: (context) {
                            // Activity tab TX list
                            Widget txList() {
                              var txs = aa.txs.items;
                              if (_hideFees) {
                                txs = txs.where((tx) => !TxPageState.isFeeEntry(tx)).toList();
                              }
                              if (txs.isEmpty) {
                                return Padding(
                                  key: const ValueKey('activity_empty'),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    'No transactions yet',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                );
                              }
                              return Column(
                                key: const ValueKey('activity_list'),
                                children: [
                                  for (int i = 0; i < txs.length.clamp(0, 5); i++) ...[
                                    if (i > 0) Divider(
                                      height: 8,
                                      thickness: 0.5,
                                      color: Theme.of(context).dividerColor.withOpacity(0.25),
                                    ),
                                    TxItem(txs[i], null, index: i),
                                  ],
                                ],
                              );
                            }

                            // Vault mode: Tokens (tab 0) and NFTs (tab 1) only
                            if (isVaultMode) {
                              return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  switchInCurve: Curves.easeIn,
                                  switchOutCurve: Curves.easeOut,
                                  layoutBuilder: (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.topCenter,
                                    children: [...previousChildren, if (currentChild != null) currentChild],
                                  ),
                                  child: _selectedTab == 0
                                      ? _VaultTokensTabContent(key: const ValueKey('vault_tokens'))
                                      : _VaultNftsTabContent(key: const ValueKey('vault_nfts')),
                              );
                            }

                            if (CloakWalletManager.isCloak(aa.coin)) {
                              final t = Theme.of(context);
                              final zashi = t.extension<ZashiThemeExt>();
                              final txTextColor = zashi?.balanceAmountColor ?? t.colorScheme.onSurface;
                              final borderColor = zashi?.quickBorderColor ?? t.dividerColor;
                              final flatFill = t.colorScheme.onSurface.withOpacity(0.12);
                              final base = t.textTheme.bodyMedium ?? t.textTheme.titleMedium ?? t.textTheme.bodySmall;

                              return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  switchInCurve: Curves.easeIn,
                                  switchOutCurve: Curves.easeOut,
                                  layoutBuilder: (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.topCenter,
                                    children: [...previousChildren, if (currentChild != null) currentChild],
                                  ),
                                  child: _selectedTab == 0
                                      ? Column(
                                          key: const ValueKey('activity'),
                                          children: [
                                            txList(),
                                            const Gap(12),
                                            Center(
                                              child: Transform.scale(
                                                scale: 0.8,
                                                child: Material(
                                                  color: Colors.transparent,
                                                  shape: const StadiumBorder(),
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      color: flatFill,
                                                      borderRadius: BorderRadius.circular(999),
                                                      border: Border.all(color: borderColor),
                                                    ),
                                                    child: InkWell(
                                                      borderRadius: BorderRadius.circular(999),
                                                      onTap: () => GoRouter.of(context).push('/activity_overlay').then((_) => _loadFeeFilter()),
                                                      child: Padding(
                                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                                        child: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            Text(
                                                              'See all',
                                                              style: TextStyle(fontWeight: FontWeight.w700, color: txTextColor),
                                                            ),
                                                            const SizedBox(width: 2),
                                                            Icon(
                                                              Icons.chevron_right,
                                                              size: (base?.fontSize ?? 14.0) * 1.20,
                                                              color: txTextColor,
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : _selectedTab == 1
                                          ? _TokensTabContent(key: const ValueKey('tokens'))
                                          : _NftsTabContent(key: const ValueKey('nfts')),
                              );
                            }

                            return txList();
                          }),
                        ])),
                    ],
                  )),
                );
              },
            ),
    );
  }

  _send(bool custom) async {
    final protectSend = appSettings.protectSend;
    if (protectSend) {
      final authed = await authBarrier(context, dismissable: true);
      if (!authed) return;
    }
    final c = custom ? 1 : 0;
    GoRouter.of(context).push('/account/quick_send?custom=$c');
  }

  _backup() {
    GoRouter.of(context).push('/more/backup');
  }

  /// Show vault deposit info modal with send-to address and memo
  /// Vault withdraw: show bottom sheet with Quick Withdraw / Custom Withdraw options
  void _showVaultWithdraw(BuildContext context) {
    final hash = activeVaultHash;
    final vaultBalance = aa.poolBalances.sapling; // vault CLOAK balance in units
    if (hash == null || hash.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active vault')),
      );
      return;
    }
    final hasNfts = activeVaultTokens?.nfts.isNotEmpty ?? false;
    if (vaultBalance <= 0 && !hasNfts && !_kMockNfts) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vault has no balance to withdraw')),
      );
      return;
    }
    _showWithdrawOptionsSheet(context);
  }

  /// Bottom sheet modal presenting Quick Withdraw and Custom Withdraw options.
  /// Uses existing showModalBottomSheet pattern from tx.dart / shield_page.dart
  /// and button/card styles from cloak_confirm.dart.
  void _showWithdrawOptionsSheet(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    const cardColor = Color(0xFF2E2C2C);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle pill
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                // Title
                Text(
                  'Withdraw from Vault',
                  style: t.textTheme.titleMedium?.copyWith(
                    fontFamily: balanceFontFamily,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 24),
                // Quick Withdraw — primary button (balanceColor fill, matches cloak_confirm.dart)
                SizedBox(
                  width: double.infinity,
                  child: Material(
                    color: balanceColor,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _doQuickWithdraw(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(Icons.flash_on, size: 20, color: t.colorScheme.background),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Quick Withdraw',
                                style: t.textTheme.titleSmall?.copyWith(
                                  fontFamily: balanceFontFamily,
                                  fontWeight: FontWeight.w600,
                                  color: t.colorScheme.background,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 20, color: t.colorScheme.background),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Explanation text (matches cloak_confirm.dart fee explanation style)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Withdraw all assets from this vault to your wallet in a single transaction.',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurface.withOpacity(0.45),
                      fontSize: 11.5,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Custom Withdraw — secondary card (0xFF2E2C2C fill, matches cloak_confirm.dart cards)
                SizedBox(
                  width: double.infinity,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        GoRouter.of(context).push('/account/quick_send');
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(Icons.tune, size: 20, color: t.colorScheme.onSurface),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Custom Withdraw',
                                style: t.textTheme.titleSmall?.copyWith(
                                  fontFamily: balanceFontFamily,
                                  fontWeight: FontWeight.w600,
                                  color: t.colorScheme.onSurface,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurface),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Quick Withdraw: gather all vault assets, target the wallet's own
  /// CLOAK receive address, and go straight to the review/confirm page.
  void _doQuickWithdraw(BuildContext context) {
    final vt = activeVaultTokens;
    final hash = activeVaultHash;
    if (vt == null || hash == null) return;

    // Build BatchAsset list from vault FTs + NFTs
    final List<BatchAsset> assets = [];
    for (final ft in vt.fts) {
      final symbol = ft['symbol'] as String? ?? 'CLOAK';
      final contract = ft['contract'] as String? ?? 'thezeostoken';
      final amount = ft['amount'] as String? ?? '0';
      final precision = ft['precision'] as int? ?? 4;
      double scale = 1;
      for (int i = 0; i < precision; i++) scale *= 10;
      final units = ((double.tryParse(amount) ?? 0.0) * scale).round();
      if (units <= 0) continue;
      assets.add(BatchAsset(
        symbol: symbol,
        contract: contract,
        precision: precision,
        amountUnits: units,
      ));
    }
    for (final nft in vt.nfts) {
      assets.add(BatchAsset(
        symbol: 'NFT',
        contract: nft['contract']?.toString() ?? 'atomicassets',
        precision: 0,
        amountUnits: 0,
        nftId: nft['id']?.toString(),
        nftName: nft['name']?.toString(),
        nftImageUrl: nft['imageUrl']?.toString(),
      ));
    }

    if (assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vault has no assets to withdraw')),
      );
      return;
    }

    // Destination = wallet's own CLOAK shielded address (use stable default, not derive)
    final address = CloakWalletManager.getDefaultAddress() ?? '';
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not resolve wallet address')),
      );
      return;
    }

    // Set up SendContext for the confirm page
    SendContext.instance = SendContext(
      address,
      0,            // pools (unused for CLOAK)
      Amount(0, false), // amount (batch mode uses batchAssets instead)
      null,         // memo (no memo for vault withdrawals — privacy)
      null,         // fx
      'Your Wallet', // display
      false,        // fromThread
      null,         // threadIndex
      null,         // threadCid
      null,         // tokenSymbol
      null,         // tokenContract
      null,         // tokenPrecision
      hash,         // vaultHash
      null,         // nftId
      null,         // nftContract
      null,         // nftImageUrl
      null,         // nftName
      true,         // isBatchWithdraw
      assets,       // batchAssets
    );

    GoRouter.of(context).push('/account/cloak_confirm');
  }

  /// Deposit button: show bottom sheet with Quick Deposit / External Deposit options.
  void _showVaultDeposit(BuildContext context) {
    final hash = activeVaultHash;
    if (hash == null || hash.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active vault')),
      );
      return;
    }
    _showDepositOptionsSheet(context);
  }

  /// Bottom sheet presenting Quick Deposit and External Deposit options.
  void _showDepositOptionsSheet(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    const cardColor = Color(0xFF2E2C2C);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle pill
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                // Title
                Text(
                  'Deposit to Vault',
                  style: t.textTheme.titleMedium?.copyWith(
                    fontFamily: balanceFontFamily,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 24),
                // Quick Deposit — primary button (balanceColor fill)
                SizedBox(
                  width: double.infinity,
                  child: Material(
                    color: balanceColor,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _doQuickDeposit(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(Icons.flash_on, size: 20, color: t.colorScheme.background),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Quick Deposit',
                                style: t.textTheme.titleSmall?.copyWith(
                                  fontFamily: balanceFontFamily,
                                  fontWeight: FontWeight.w600,
                                  color: t.colorScheme.background,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 20, color: t.colorScheme.background),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Explanation text
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Deposit from your CLOAK wallet balance directly to this vault.',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurface.withOpacity(0.45),
                      fontSize: 11.5,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // External Deposit — secondary card
                SizedBox(
                  width: double.infinity,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showExternalDepositModal(context);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        child: Row(
                          children: [
                            Icon(Icons.open_in_new, size: 20, color: t.colorScheme.onSurface),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'External Deposit',
                                style: t.textTheme.titleSmall?.copyWith(
                                  fontFamily: balanceFontFamily,
                                  fontWeight: FontWeight.w600,
                                  color: t.colorScheme.onSurface,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurface),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Deposit from Anchor or any external Telos wallet.',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurface.withOpacity(0.45),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Quick Deposit: navigate to send flow with vault hash as destination address.
  /// The Rust layer auto-converts 64-char hex vault hashes to thezeosvault transfers.
  /// isVaultDeposit flag tells the send page to use wallet balance (not vault balance)
  /// and show "DEPOSIT" title, without changing global vault mode state.
  void _doQuickDeposit(BuildContext context) {
    final hash = activeVaultHash ?? '';
    if (hash.isEmpty) return;

    GoRouter.of(context).push('/account/quick_send', extra: SendContext(
      hash,                           // address (vault hash → auto-converted by Rust)
      7,                              // pools
      Amount(0, false),               // amount
      MemoData(false, '', 'AUTH:$hash|'), // memo
      null,                           // fx
      'This Vault',                   // display
      false,                          // fromThread
      null,                           // threadIndex
      null,                           // threadCid
      null,                           // tokenSymbol
      null,                           // tokenContract
      null,                           // tokenPrecision
      null,                           // vaultHash
      null,                           // nftId
      null,                           // nftContract
      null,                           // nftImageUrl
      null,                           // nftName
      false,                          // isBatchWithdraw
      null,                           // batchAssets
      true,                           // isVaultDeposit
    ));
  }

  /// External Deposit: modern modal with explicit step-by-step instructions.
  void _showExternalDepositModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ExternalDepositSheet(
        vaultHash: activeVaultHash ?? '',
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  final String label;
  final String asset;
  final VoidCallback onTap;
  final double? tileSize;
  const _QuickActionTile({required this.label, required this.asset, required this.onTap, this.tileSize});

  @override
  Widget build(BuildContext context) {
    final onSurf = Theme.of(context).colorScheme.onSurface;
    final zashi = Theme.of(context).extension<ZashiThemeExt>()!;
    final radius = zashi.tileRadius;
    final size = tileSize ?? 96.0;
    final gradTop = zashi.quickGradTop;
    final gradBottom = zashi.quickGradBottom;
    final borderColor = zashi.quickBorderColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          elevation: 1.5,
          shadowColor: isDark ? Colors.black54 : Colors.black12,
          borderRadius: BorderRadius.circular(radius),
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [gradTop, gradBottom],
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: borderColor),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: (zashi.tilePadding - 4).clamp(0, double.infinity),
                  horizontal: zashi.tilePadding,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    SvgPicture.asset(
                      asset,
                      width: asset.contains('scan_quick') ? 36 : 32,
                      height: asset.contains('scan_quick') ? 36 : 32,
                      colorFilter: ColorFilter.mode(onSurf, BlendMode.srcIn),
                    ),
                    const SizedBox(height: 6),
                    LayoutBuilder(builder: (context, box) {
                      // Responsive label: keep as large as possible until it would ellipsize,
                      // then step down font size to fit.
                      final base = Theme.of(context).textTheme.labelSmall;
                      final candidates = <double?>[
                        base?.fontSize,
                        (base?.fontSize != null) ? base!.fontSize! * 0.9 : null,
                        (base?.fontSize != null) ? base!.fontSize! * 0.8 : null,
                        (base?.fontSize != null) ? base!.fontSize! * 0.7 : null,
                      ].whereType<double>().toList();
                      Text? fitted;
                      for (final fs in candidates) {
                        final tp = TextPainter(
                          text: TextSpan(text: label, style: base?.copyWith(fontSize: fs)),
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                        )..layout(maxWidth: box.maxWidth);
                        if (!tp.didExceedMaxLines) {
                          fitted = Text(
                            label,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: base?.copyWith(fontSize: fs, color: onSurf.withOpacity(0.9)),
                          );
                          break;
                        }
                      }
                      return fitted ?? Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: base?.copyWith(color: onSurf.withOpacity(0.9)),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner shown on home page when funds need migration to Orchard for voting
/// Uses orange gradient matching the shielded address card on Receive page
class _MigrationBanner extends StatefulWidget {
  @override
  State<_MigrationBanner> createState() => _MigrationBannerState();
}

class _MigrationBannerState extends State<_MigrationBanner> with SingleTickerProviderStateMixin {
  // Orange gradient colors matching the Receive page shielded card
  static const Color _orangeBase = Color(0xFFC99111);
  static const Color _orangeDark = Color(0xFFA1740D);
  // Green for ready state
  static const Color _greenBase = Color(0xFF4CAF50);
  static const Color _greenDark = Color(0xFF388E3C);

  late AnimationController _flashController;
  late Animation<double> _flashAnimation;
  int _lastNonOrchard = 0;
  bool _hasAppeared = false;

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _flashAnimation = Tween<double>(begin: 1.0, end: 0.5).animate(
      CurvedAnimation(parent: _flashController, curve: Curves.easeInOut),
    );
    _flashController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _flashController.reverse();
      }
    });
    _lastNonOrchard = aa.poolBalances.transparent + aa.poolBalances.sapling;
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  void _checkForFlash() {
    final currentNonOrchard = aa.poolBalances.transparent + aa.poolBalances.sapling;
    if (_hasAppeared && currentNonOrchard > _lastNonOrchard) {
      _flashController.forward(from: 0.0);
    }
    _lastNonOrchard = currentNonOrchard;
  }

  @override
  Widget build(BuildContext context) {
    // Wrap in Observer to react to MobX observable changes
    return Observer(builder: (context) {
    // Access observables to trigger MobX tracking
    aaSequence.seqno;
    syncStatus2.changed;
    
    final t = Theme.of(context);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final pools = aa.poolBalances;
    final nonOrchard = pools.transparent + pools.sapling;
    final nonOrchardZec = nonOrchard / ZECUNIT;
    
    // Check if balance increased and trigger flash
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForFlash());
    
    final state = migrationState.state;
    final isMigrating = state == MigrationState.migrating;
    // Ready if: state says ready OR balances show all in orchard
    final isReady = state == MigrationState.ready || (nonOrchard == 0 && pools.orchard > 0);

    // Determine colors based on state
    final Color gradStart;
    final Color gradEnd;
    if (isReady) {
      gradStart = _greenDark;
      gradEnd = _greenBase;
    } else {
      gradStart = _orangeDark;
      gradEnd = _orangeBase;
    }

    // Determine title and subtitle - balance-driven logic
    final String title;
    final String subtitle;
    final IconData? trailingIcon;
    
    if (isReady) {
      title = 'Ready for Voting!';
      subtitle = 'All funds are in Orchard pool';
      trailingIcon = Icons.chevron_right;
    } else if (isMigrating) {
      title = 'Migrating...';
      subtitle = migrationState.statusMessage;
      trailingIcon = null; // Will show spinner
    } else {
      title = 'Migrate for Voting';
      subtitle = '${decimalToStringTrim(nonOrchardZec)} ZEC needs migration to Orchard';
      trailingIcon = Icons.arrow_forward_ios;
    }

    final bannerContent = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: AnimatedBuilder(
        animation: _flashAnimation,
        builder: (context, child) {
          return Opacity(
            opacity: _flashAnimation.value,
            child: child,
          );
        },
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: isReady 
                ? () => GoRouter.of(context).push('/account/vote')
                : () => showMigrationModalIfNeeded(context),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [gradStart, gradEnd],
                ),
              ),
              child: Row(
                children: [
                  // ZEC glyph with vote icon overlay (like shielded card)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Center(
                          child: SvgPicture.asset(
                            'assets/icons/zec_glyph.svg',
                            width: 28,
                            height: 28,
                            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                          ),
                        ),
                        Positioned(
                          right: -1,
                          bottom: -1,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withOpacity(0.08)),
                            ),
                            child: Icon(
                              isReady ? Icons.check : Icons.how_to_vote,
                              size: 14,
                              color: Colors.white.withOpacity(0.95),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: (t.textTheme.titleMedium ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const Gap(4),
                        Text(
                          subtitle,
                          style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMigrating)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withOpacity(0.7)),
                      ),
                    )
                  else if (trailingIcon != null)
                    Icon(trailingIcon, color: Colors.white.withOpacity(0.9), size: isReady ? 24 : 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Fade in on first appearance
    if (!_hasAppeared) {
      _hasAppeared = true;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 10 * (1 - value)),
              child: child,
            ),
          );
        },
        child: bannerContent,
      );
    }

    return bannerContent;
    }); // End Observer
  }
}

class _SegmentedToggle extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final List<String> labels;
  const _SegmentedToggle({required this.selectedIndex, required this.onChanged, required this.labels});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final selectedColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final unselectedColor = t.colorScheme.onSurface.withOpacity(0.5);
    final gradTop = zashi?.quickGradTop ?? t.colorScheme.onSurface.withOpacity(0.12);
    final gradBottom = zashi?.quickGradBottom ?? t.colorScheme.onSurface.withOpacity(0.08);
    final indicatorBorder = zashi?.quickBorderColor ?? t.dividerColor;
    final isDark = t.brightness == Brightness.dark;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: t.colorScheme.onSurface.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabCount = labels.length;
          final segWidth = constraints.maxWidth / tabCount;
          return Stack(
            children: [
              // Sliding indicator with quick-action gradient + shadow
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                left: selectedIndex * segWidth,
                top: 0,
                bottom: 0,
                width: segWidth,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [gradTop, gradBottom],
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: indicatorBorder),
                  ),
                ),
              ),
              // Labels
              Row(
                children: List.generate(tabCount, (i) => Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Center(
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: selectedIndex == i ? selectedColor : unselectedColor,
                          fontWeight: selectedIndex == i ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                )),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Token helpers ───────────────────────────────────────────────

String? _getTokenLogoUrl(String symbol, String contract) {
  const wellKnown = {
    'thezeostoken:CLOAK': 'asset:assets/cloak_logo.png',
    'eosio.token:TLOS': 'https://raw.githubusercontent.com/AnyswapIN/nftlist/main/telos.png',
  };
  return wellKnown['$contract:$symbol'];
}

Color _getHomeTokenColor(String symbol) {
  switch (symbol) {
    case 'CLOAK': return Colors.purple;
    case 'TLOS': return Colors.blue;
    case 'USDT': return Colors.green;
    case 'USDC': return Colors.blue.shade700;
    case 'BTC': case 'WBTC': return Colors.orange;
    case 'ETH': case 'WETH': return Colors.indigo;
    default: return Colors.grey.shade600;
  }
}

// ─── _TokenIcon (duplicated from shield_page.dart) ───────────────

class _HomeTokenIcon extends StatefulWidget {
  final String? logoUrl;
  final String symbol;
  final double size;
  final Color fallbackColor;

  const _HomeTokenIcon({
    this.logoUrl,
    required this.symbol,
    required this.size,
    required this.fallbackColor,
  });

  @override
  State<_HomeTokenIcon> createState() => _HomeTokenIconState();
}

class _HomeTokenIconState extends State<_HomeTokenIcon> {
  bool _imageLoadFailed = false;

  bool get _hasImage => widget.logoUrl != null && widget.logoUrl!.isNotEmpty && !_imageLoadFailed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: _hasImage
            ? Border.all(color: const Color(0x33FFFFFF), width: 0.5)
            : null,
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _hasImage ? Colors.transparent : widget.fallbackColor,
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildImage(context),
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    if (widget.logoUrl == null || widget.logoUrl!.isEmpty) {
      return _buildFallback(context);
    }
    if (widget.logoUrl!.startsWith('asset:')) {
      final assetPath = widget.logoUrl!.substring(6);
      return Image.asset(
        assetPath,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _imageLoadFailed = true);
          });
          return _buildFallback(context);
        },
      );
    }
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
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildFallback(BuildContext context) {
    return Container(
      color: widget.fallbackColor,
      child: Center(
        child: Text(
          widget.symbol.isNotEmpty ? widget.symbol[0] : '?',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: widget.size * 0.45,
          ),
        ),
      ),
    );
  }
}

// ─── _ShieldedTokenRow ──────────────────────────────────────────

class _ShieldedTokenRow extends StatelessWidget {
  final String symbol;
  final String contract;
  final String amount;
  final String? logoUrl;
  final Color fallbackColor;

  const _ShieldedTokenRow({
    required this.symbol,
    required this.contract,
    required this.amount,
    this.logoUrl,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              _HomeTokenIcon(
                size: 40,
                logoUrl: logoUrl,
                symbol: symbol,
                fallbackColor: fallbackColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      symbol,
                      style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      contract,
                      style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    appStore.hideBalances ? '\u2013 \u2013.\u2013 \u2013 \u2013 \u2013' : amount,
                    style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    symbol,
                    style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
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

// ─── _TokensTabContent ──────────────────────────────────────────

class _TokensTabContent extends StatelessWidget {
  const _TokensTabContent({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final headerColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final onSurface = t.colorScheme.onSurface;
    final dividerColor = t.dividerColor;
    final base = t.textTheme.bodyMedium ?? t.textTheme.bodySmall;
    final headerStyle = (base ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
      color: headerColor,
    );

    // Parse FT data
    final ftRaw = CloakWalletManager.getBalancesJson();
    final List<_ParsedFt> fts = [];
    if (ftRaw != null && ftRaw.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(ftRaw);
        for (final entry in parsed) {
          final str = entry.toString();
          final atIdx = str.lastIndexOf('@');
          if (atIdx < 0) continue;
          final quantityPart = str.substring(0, atIdx);
          final contract = str.substring(atIdx + 1);
          final spaceIdx = quantityPart.lastIndexOf(' ');
          if (spaceIdx < 0) continue;
          final amount = quantityPart.substring(0, spaceIdx);
          final symbol = quantityPart.substring(spaceIdx + 1);
          fts.add(_ParsedFt(symbol: symbol, contract: contract, amount: amount));
        }
      } catch (_) {}
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // FT List
        if (fts.isEmpty)
          Text(
            'No shielded tokens',
            style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
              color: t.colorScheme.onSurface.withOpacity(0.5),
            ),
          )
        else
          for (int i = 0; i < fts.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                color: dividerColor.withOpacity(0.15),
              ),
            _ShieldedTokenRow(
              symbol: fts[i].symbol,
              contract: fts[i].contract,
              amount: fts[i].amount,
              logoUrl: _getTokenLogoUrl(fts[i].symbol, fts[i].contract),
              fallbackColor: _getHomeTokenColor(fts[i].symbol),
            ),
          ],
        const SizedBox(height: 80),
      ],
    );
  }
}

// ─── NFTs Tab Content ─────────────────────────────────────────────

class _NftsTabContent extends StatefulWidget {
  const _NftsTabContent({super.key});

  @override
  State<_NftsTabContent> createState() => _NftsTabContentState();
}

class _NftsTabContentState extends State<_NftsTabContent> {
  List<_ParsedNft> _nfts = [];
  bool _metadataLoaded = false;

  @override
  void initState() {
    super.initState();
    _parseAndFetchNfts();
  }

  void _parseAndFetchNfts() {
    final nftRaw = CloakWalletManager.getNftsJson();
    final List<_ParsedNft> nfts = [];
    if (nftRaw != null && nftRaw.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(nftRaw);
        for (final entry in parsed) {
          final str = entry.toString();
          final atIdx = str.lastIndexOf('@');
          if (atIdx < 0) continue;
          final nftId = str.substring(0, atIdx);
          final contract = str.substring(atIdx + 1);
          nfts.add(_ParsedNft(nftId: nftId, contract: contract));
        }
      } catch (_) {}
    }

    // Inject mock NFTs for visual testing
    if (_kMockNfts && nfts.isEmpty) {
      nfts.addAll([
        const _ParsedNft(nftId: '1099511627776', contract: 'atomicassets', imageUrl: 'asset:assets/nft/cloak-gold-coin.png', name: 'CLOAK Gold Coin', collectionName: 'CLOAK Collection'),
        const _ParsedNft(nftId: '1099511627777', contract: 'atomicassets', imageUrl: 'asset:assets/nft/cloak-front.png', name: 'CLOAK Front', collectionName: 'CLOAK Collection'),
        const _ParsedNft(nftId: '1099511627778', contract: 'atomicassets', imageUrl: 'asset:assets/nft/anonymous-face.png', name: 'Anonymous Face', collectionName: 'CLOAK Collection'),
      ]);
    }

    setState(() { _nfts = nfts; });

    // Fetch metadata for non-mock NFTs
    if (!_kMockNfts || nfts.any((n) => n.name == null)) {
      _loadMetadata(nfts);
    } else {
      _metadataLoaded = true;
    }
  }

  Future<void> _loadMetadata(List<_ParsedNft> nfts) async {
    final ids = nfts.where((n) => n.contract == 'atomicassets' && n.name == null).map((n) => n.nftId).toList();
    if (ids.isEmpty) {
      setState(() { _metadataLoaded = true; });
      return;
    }
    final metaMap = await AtomicAssetsService.instance.fetchMultiple(ids);
    if (!mounted) return;
    setState(() {
      _nfts = _nfts.map((nft) {
        final meta = metaMap[nft.nftId];
        if (meta != null) {
          return nft.withMetadata(
            name: meta.name,
            collectionName: meta.collectionName,
            imageUrl: meta.imageUrl,
          );
        }
        return nft;
      }).toList();
      _metadataLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onSurface = t.colorScheme.onSurface;
    final isDark = t.brightness == Brightness.dark;

    if (_nfts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.diamond_outlined, size: 48, color: onSurface.withOpacity(0.15)),
              const SizedBox(height: 12),
              Text(
                'No NFTs yet',
                style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w600,
                  color: onSurface.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Shielded NFTs will appear here',
                style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                  color: onSurface.withOpacity(0.35),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        for (int i = 0; i < _nfts.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: _buildNftCard(_nfts[i], onSurface, isDark),
                ),
              ),
              const SizedBox(width: 12),
              if (i + 1 < _nfts.length)
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: _buildNftCard(_nfts[i + 1], onSurface, isDark),
                  ),
                )
              else
                const Expanded(child: SizedBox()),
            ],
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  NftLightboxItem _nftToLightboxItem(_ParsedNft nft) {
    final cached = AtomicAssetsService.instance.getCached(nft.nftId);
    return NftLightboxItem(
      nftId: nft.nftId,
      contract: nft.contract,
      name: nft.name,
      collectionName: nft.collectionName,
      imageUrl: nft.imageUrl,
      schemaName: cached?.schemaName,
      templateId: cached?.templateId,
      rawData: cached?.rawData,
    );
  }

  Widget _buildNftCard(_ParsedNft nft, Color onSurface, bool isDark) {
    final displayName = nft.name ?? 'NFT #${nft.nftId.length > 8 ? '${nft.nftId.substring(0, 8)}...' : nft.nftId}';
    final subtitle = nft.collectionName ?? nft.contract;

    return GestureDetector(
      onTap: () => showNftLightbox(
        context,
        nfts: _nfts.map(_nftToLightboxItem).toList(),
        initialIndex: _nfts.indexOf(nft),
        isVault: false,
      ),
      // Approach #14: replaced BoxShadow with simple border to eliminate
      // per-card saveLayer() calls that contributed to first-render black screen.
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.12),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: onSurface.withOpacity(0.06),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NftImageWidget(imageUrl: nft.imageUrl, assetId: nft.nftId),
                // Bottom gradient overlay with name + collection
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(10, 20, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _metadataLoaded
                          ? Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.55),
                                fontSize: 10,
                                height: 1.3,
                              ),
                            )
                          : Container(
                              height: 10,
                              width: 60,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ParsedFt {
  final String symbol;
  final String contract;
  final String amount;
  const _ParsedFt({required this.symbol, required this.contract, required this.amount});
}

class _ParsedNft {
  final String nftId;
  final String contract;
  final String? imageUrl;
  final String? name;
  final String? collectionName;
  const _ParsedNft({required this.nftId, required this.contract, this.imageUrl, this.name, this.collectionName});

  _ParsedNft withMetadata({String? name, String? collectionName, String? imageUrl}) {
    return _ParsedNft(
      nftId: nftId,
      contract: contract,
      imageUrl: imageUrl ?? this.imageUrl,
      name: name ?? this.name,
      collectionName: collectionName ?? this.collectionName,
    );
  }
}

// ─── Vault Tab Content ───────────────────────────────────────────

/// Tokens tab for vault mode — reads from activeVaultTokens
class _VaultTokensTabContent extends StatelessWidget {
  const _VaultTokensTabContent({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dividerColor = t.dividerColor;
    final tokens = activeVaultTokens;

    if (tokens == null || tokens.fts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No tokens in vault',
          style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            color: t.colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
      );
    }

    final fts = tokens.fts;

    return Column(
      children: [
        for (int i = 0; i < fts.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              thickness: 0.5,
              color: dividerColor.withOpacity(0.15),
            ),
          _ShieldedTokenRow(
            symbol: fts[i]['symbol'] as String? ?? 'CLOAK',
            contract: fts[i]['contract'] as String? ?? '',
            amount: fts[i]['amount'] as String? ?? '0',
            logoUrl: _getTokenLogoUrl(fts[i]['symbol'] as String? ?? 'CLOAK', fts[i]['contract'] as String? ?? ''),
            fallbackColor: _getHomeTokenColor(fts[i]['symbol'] as String? ?? 'CLOAK'),
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }
}

/// NFTs tab for vault mode — reads from activeVaultTokens
class _VaultNftsTabContent extends StatefulWidget {
  const _VaultNftsTabContent({super.key});

  @override
  State<_VaultNftsTabContent> createState() => _VaultNftsTabContentState();
}

class _VaultNftsTabContentState extends State<_VaultNftsTabContent> {
  List<_ParsedNft> _nfts = [];
  bool _metadataLoaded = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshNfts();
  }

  void _refreshNfts() {
    final tokens = activeVaultTokens;

    if (tokens == null) {
      setState(() { _initialized = false; });
      return;
    }

    final nfts = tokens.nfts;
    final List<_ParsedNft> parsed = [];

    if (_kMockNfts && nfts.isEmpty) {
      parsed.addAll([
        const _ParsedNft(nftId: '1099511627776', contract: 'atomicassets', imageUrl: 'asset:assets/nft/cloak-gold-coin.png', name: 'CLOAK Gold Coin', collectionName: 'CLOAK Collection'),
        const _ParsedNft(nftId: '1099511627777', contract: 'atomicassets', imageUrl: 'asset:assets/nft/cloak-front.png', name: 'CLOAK Front', collectionName: 'CLOAK Collection'),
        const _ParsedNft(nftId: '1099511627778', contract: 'atomicassets', imageUrl: 'asset:assets/nft/anonymous-face.png', name: 'Anonymous Face', collectionName: 'CLOAK Collection'),
      ]);
    } else {
      for (final nft in nfts) {
        final nftId = nft['id']?.toString() ?? nft.keys.first;
        final contract = nft['contract']?.toString() ?? '';
        final imageUrl = nft['imageUrl']?.toString();
        parsed.add(_ParsedNft(nftId: nftId, contract: contract, imageUrl: imageUrl));
      }
    }

    setState(() {
      _nfts = parsed;
      _initialized = true;
    });

    if (!_kMockNfts || parsed.any((n) => n.name == null)) {
      _loadMetadata(parsed);
    } else {
      _metadataLoaded = true;
    }
  }

  Future<void> _loadMetadata(List<_ParsedNft> nfts) async {
    final ids = nfts.where((n) => n.contract == 'atomicassets' && n.name == null).map((n) => n.nftId).toList();
    if (ids.isEmpty) {
      setState(() { _metadataLoaded = true; });
      return;
    }
    final metaMap = await AtomicAssetsService.instance.fetchMultiple(ids);
    if (!mounted) return;
    setState(() {
      _nfts = _nfts.map((nft) {
        final meta = metaMap[nft.nftId];
        if (meta != null) {
          return nft.withMetadata(
            name: meta.name,
            collectionName: meta.collectionName,
            imageUrl: meta.imageUrl,
          );
        }
        return nft;
      }).toList();
      _metadataLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onSurface = t.colorScheme.onSurface;
    final isDark = t.brightness == Brightness.dark;

    if (!_initialized) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_nfts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.diamond_outlined, size: 48, color: onSurface.withOpacity(0.15)),
              const SizedBox(height: 12),
              Text(
                'No NFTs in vault',
                style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w600,
                  color: onSurface.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Vault NFTs will appear here',
                style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                  color: onSurface.withOpacity(0.35),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Approach #14: replaced GridView.count(shrinkWrap) with Column+Row
    // (same fix as Approach #13 for CLOAK NFTs) + added 80px bottom padding.
    return Column(
      children: [
        for (int i = 0; i < _nfts.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: _buildVaultNftCard(_nfts[i], onSurface, isDark),
                ),
              ),
              const SizedBox(width: 12),
              if (i + 1 < _nfts.length)
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: _buildVaultNftCard(_nfts[i + 1], onSurface, isDark),
                  ),
                )
              else
                const Expanded(child: SizedBox()),
            ],
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  NftLightboxItem _nftToLightboxItem(_ParsedNft nft) {
    final cached = AtomicAssetsService.instance.getCached(nft.nftId);
    return NftLightboxItem(
      nftId: nft.nftId,
      contract: nft.contract,
      name: nft.name,
      collectionName: nft.collectionName,
      imageUrl: nft.imageUrl,
      schemaName: cached?.schemaName,
      templateId: cached?.templateId,
      rawData: cached?.rawData,
    );
  }

  Widget _buildVaultNftCard(_ParsedNft nft, Color onSurface, bool isDark) {
    final displayName = nft.name ?? 'NFT #${nft.nftId.length > 8 ? '${nft.nftId.substring(0, 8)}...' : nft.nftId}';
    final subtitle = nft.collectionName ?? nft.contract;

    return GestureDetector(
      onTap: () => showNftLightbox(
        context,
        nfts: _nfts.map(_nftToLightboxItem).toList(),
        initialIndex: _nfts.indexOf(nft),
        isVault: true,
      ),
      // Approach #14: replaced BoxShadow with simple border (same as CLOAK NFT cards).
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.12),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: onSurface.withOpacity(0.06),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NftImageWidget(imageUrl: nft.imageUrl, assetId: nft.nftId),
                // Bottom gradient overlay with name + collection
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(10, 20, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _metadataLoaded
                          ? Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.55),
                                fontSize: 10,
                                height: 1.3,
                              ),
                            )
                          : Container(
                              height: 10,
                              width: 60,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Deposit Info Field ──────────────────────────────────────────

/// External Deposit bottom sheet with step-by-step instructions,
/// working copy buttons, and expandable "What are vaults for?" info.
class _ExternalDepositSheet extends StatefulWidget {
  final String vaultHash;
  const _ExternalDepositSheet({required this.vaultHash});

  @override
  State<_ExternalDepositSheet> createState() => _ExternalDepositSheetState();
}

class _ExternalDepositSheetState extends State<_ExternalDepositSheet> {
  bool _vaultInfoExpanded = false;

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final memo = 'AUTH:${widget.vaultHash}|';
    final screenHeight = MediaQuery.of(context).size.height;
    const cardColor = Color(0xFF2E2C2C);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.75),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                // Title
                Text(
                  'External Deposit',
                  style: t.textTheme.titleMedium?.copyWith(
                    fontFamily: balanceFontFamily,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                // Subtitle
                Text(
                  'From Anchor or any Telos wallet',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurface.withOpacity(0.45),
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 20),

                // Step 1: Send to
                _buildStepCard(
                  step: '1',
                  instruction: 'Send your tokens to this address',
                  copyValue: 'thezeosvault',
                  copyLabel: 'Address',
                  balanceColor: balanceColor,
                  fontFamily: balanceFontFamily,
                  cardColor: cardColor,
                ),
                const SizedBox(height: 12),

                // Step 2: Memo
                _buildStepCard(
                  step: '2',
                  instruction: 'Paste this into the Memo field',
                  copyValue: memo,
                  copyLabel: 'Memo',
                  balanceColor: balanceColor,
                  fontFamily: balanceFontFamily,
                  cardColor: cardColor,
                ),
                const SizedBox(height: 12),

                // Step 3: Confirm
                _buildStepCard(
                  step: '3',
                  instruction: 'Confirm and send the transaction',
                  balanceColor: balanceColor,
                  fontFamily: balanceFontFamily,
                  cardColor: cardColor,
                  trailing: Icon(Icons.check, size: 16, color: balanceColor.withOpacity(0.35)),
                ),
                const SizedBox(height: 16),

                // Green info box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF4CAF50).withOpacity(0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF4CAF50)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'After your deposit confirms, use your CLOAK wallet to authenticate and pull the assets into your shielded balance.',
                          style: TextStyle(color: const Color(0xFF4CAF50), fontSize: 12, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // "What are vaults for?" expandable info
                GestureDetector(
                  onTap: () => setState(() => _vaultInfoExpanded = !_vaultInfoExpanded),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.help_outline, size: 16, color: balanceColor.withOpacity(0.6)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'What are vaults for?',
                                style: TextStyle(
                                  color: balanceColor.withOpacity(0.7),
                                  fontFamily: balanceFontFamily,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            AnimatedRotation(
                              turns: _vaultInfoExpanded ? 0.5 : 0.0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(Icons.expand_more, size: 20, color: balanceColor.withOpacity(0.4)),
                            ),
                          ],
                        ),
                        AnimatedCrossFade(
                          firstChild: const SizedBox.shrink(),
                          secondChild: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'Vaults are private drop boxes for getting tokens into your CLOAK wallet without revealing who you are. '
                              'When you deposit to a vault, the transaction is public — but when you authenticate and pull the funds '
                              'into your shielded balance, nobody can connect the deposit to the withdrawal. '
                              'This breaks the on-chain link between your public Telos account and your private CLOAK wallet.',
                              style: TextStyle(
                                color: balanceColor.withOpacity(0.5),
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                          crossFadeState: _vaultInfoExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                          duration: const Duration(milliseconds: 250),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepCard({
    required String step,
    required String instruction,
    String? copyValue,
    String? copyLabel,
    required Color balanceColor,
    String? fontFamily,
    required Color cardColor,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: balanceColor.withOpacity(0.15),
                ),
                child: Center(
                  child: Text(
                    step,
                    style: TextStyle(
                      color: balanceColor.withOpacity(0.7),
                      fontFamily: fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  instruction,
                  style: TextStyle(
                    color: balanceColor.withOpacity(0.8),
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          if (copyValue != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      copyValue,
                      style: TextStyle(
                        color: balanceColor,
                        fontFamily: fontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _copyToClipboard(copyValue, copyLabel ?? ''),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.copy, size: 16, color: balanceColor.withOpacity(0.5)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
