import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../store2.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';
import 'send.dart' show SendContext, BatchAsset;
import '../../theme/zashi_tokens.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/cloak_db.dart';
import 'submit.dart' show BeatPulse, SendingEllipses;

class CloakSubmitPage extends StatefulWidget {
  CloakSubmitPage();
  @override
  State<StatefulWidget> createState() => _CloakSubmitState();
}

class _CloakSubmitState extends State<CloakSubmitPage>
    with SingleTickerProviderStateMixin {
  String? txId;
  String? error;
  String _statusMessage = '';
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    Future(() async {
      try {
        final sc = SendContext.instance;
        if (sc == null) throw 'No send context';

        setState(() => _statusMessage = 'Loading ZK parameters...');
          if (!await CloakWalletManager.loadZkParams()) {
            throw 'Failed to load ZK parameters';
          }

          final bool isNft = sc.nftId != null && sc.nftId!.isNotEmpty;

          String? result;
          if (sc.isBatchWithdraw && sc.batchAssets != null && sc.vaultHash != null) {
            // Batch vault withdrawal (Quick Withdraw)
            final entries = sc.batchAssets!.map((ba) {
              if (ba.nftId != null) {
                return VaultWithdrawEntry(
                  nftAssetIds: [ba.nftId!],
                  nftContract: ba.contract,
                  memo: '',
                );
              } else {
                final whole = ba.amountUnits ~/ _pow10(ba.precision);
                final frac = (ba.amountUnits % _pow10(ba.precision)).toString().padLeft(ba.precision, '0');
                final quantity = '$whole.$frac ${ba.symbol}';
                return VaultWithdrawEntry(
                  quantity: quantity,
                  tokenContract: ba.contract,
                  memo: '',
                );
              }
            }).toList();

            result = await CloakWalletManager.authenticateVaultBatch(
              vaultHash: sc.vaultHash!,
              recipientAddress: sc.address,
              entries: entries,
              onStatus: (status) {
                if (mounted) setState(() => _statusMessage = status);
              },
            );
          } else if (sc.vaultHash != null && sc.vaultHash!.isNotEmpty) {
            // Vault withdrawal via authenticate
            if (isNft) {
              // NFT vault withdrawal
              result = await CloakWalletManager.authenticateVault(
                vaultHash: sc.vaultHash!,
                recipientAddress: sc.address,
                quantity: '0.0000 CLOAK', // no fungible amount for NFT withdraw
                tokenContract: 'thezeostoken',
                nftAssetIds: [sc.nftId!],
                nftContract: sc.nftContract,
                memo: sc.memo?.memo ?? '',
                onStatus: (status) {
                  if (mounted) setState(() => _statusMessage = status);
                },
              );
            } else {
              // FT vault withdrawal
              final precision = sc.tokenPrecision ?? 4;
              final amtDouble = sc.amount.value / (10000).toDouble(); // CLOAK precision = 4
              final quantity = '${amtDouble.toStringAsFixed(precision)} ${sc.tokenSymbol ?? 'CLOAK'}';
              result = await CloakWalletManager.authenticateVault(
                vaultHash: sc.vaultHash!,
                recipientAddress: sc.address,
                quantity: quantity,
                tokenContract: sc.tokenContract ?? 'thezeostoken',
                memo: sc.memo?.memo ?? '',
                onStatus: (status) {
                  if (mounted) setState(() => _statusMessage = status);
                },
              );
            }
          } else if (isNft) {
            // Normal shielded NFT send (future: needs ZTransaction NFT variant)
            throw 'NFT shielded sends are not yet supported. Use vault withdrawal to transfer NFTs.';
          } else {
            // Normal shielded send
            result = await CloakWalletManager.sendTransaction(
              recipientAddress: sc.address,
              amount: sc.amount.value,
              tokenSymbol: sc.tokenSymbol ?? 'CLOAK',
              tokenContract: sc.tokenContract ?? 'thezeostoken',
              memo: sc.memo?.memo ?? '',
              drain: sc.isDrainSend,
              onStatus: (status) {
                if (mounted) setState(() => _statusMessage = status);
              },
            );
          }

          if (result == null) throw 'Transaction failed. Check wallet balance and try again.';
          txId = result;
          // txId will be fetched on-demand when viewing transaction details
          // Force TX list refresh immediately after send so eager wallet
          // update (outgoing notes added during zsign) shows in the TX list
          // before the next sync cycle.
          aa.update(null);
          // Refresh vault balance after successful withdrawal/deposit so the
          // hero balance updates immediately (queries on-chain vault state).
          // Wait briefly for the TX to be confirmed on-chain (Telos ~0.5s blocks).
          if (isVaultMode) {
            await Future.delayed(const Duration(milliseconds: 1500));
            await refreshActiveVaultBalance();
          }
      } catch (e) {
        error = e.toString();
      }
      if (!mounted) return;
      setState(() {});
      // Trigger sync to pick up the new shielded note (vault withdrawal) or
      // updated balance (send). This also fixes TX history labels — the
      // "Received" entry must exist for the label to show "Vault Withdraw"
      // instead of "Publish Vault".
      if (txId != null) {
        try {
          await triggerManualSync();
        } catch (_) {}
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: 1.0 - _fadeAnimation.value,
        child: child,
      ),
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: null,
        body: Center(
            child: txId != null
                ? _buildSuccess(context, t, s)
                : error != null
                    ? _buildError(context, t)
                    : _buildSending(context, t)),
      ),
    );
  }

  Widget _buildSending(BuildContext context, ThemeData t) {
    String? full = '';
    try {
      full = SendContext.instance?.address;
    } catch (_) {}
    full = (full ?? '').trim();
    final src = full!.isNotEmpty ? full : 'unknown';
    final int cut = src.length > 20 ? 20 : src.length;
    final previewAddr = src.substring(0, cut) + '...';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BeatPulse(
            color: const Color(0xFFF4B728),
            size: 200,
            duration: const Duration(milliseconds: 1400)),
        const Gap(8),
        SendingEllipses(
            style: t.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
            duration: const Duration(milliseconds: 2400)),
        const Gap(8),
        Text(_statusMessage,
            style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.onSurface.withOpacity(0.7))),
        const Gap(8),
        Text(
            (SendContext.instance?.isBatchWithdraw == true)
                ? 'Your vault assets are being withdrawn to'
                : (SendContext.instance?.nftId != null)
                    ? (SendContext.instance?.vaultHash != null
                        ? '${SendContext.instance?.nftName ?? 'Your NFT'} is being withdrawn to'
                        : '${SendContext.instance?.nftName ?? 'Your NFT'} is being sent to')
                    : (SendContext.instance?.vaultHash != null)
                        ? 'Your ${SendContext.instance?.tokenSymbol ?? 'CLOAK'} is being withdrawn to'
                        : 'Your ${SendContext.instance?.tokenSymbol ?? 'CLOAK'} is being sent to',
            style: t.textTheme.bodySmall),
        const Gap(4),
        Text(previewAddr, style: t.textTheme.bodySmall),
      ],
    );
  }

  Widget _buildSuccess(BuildContext context, ThemeData t, S s) {
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final balanceColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    final sc = SendContext.instance;
    final full = (sc?.address ?? '').trim();
    final int cut = full.length > 20 ? 20 : full.length;
    final previewAddr = full.isNotEmpty ? '${full.substring(0, cut)}...' : '';

    final bool isNft = sc?.nftId != null && sc!.nftId!.isNotEmpty;
    final bool isVaultWithdraw = sc?.vaultHash != null && sc!.vaultHash!.isNotEmpty;
    final bool isBatch = sc?.isBatchWithdraw == true;

    return Stack(children: [
      // Top gradient
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0x0DF2B628),
                  t.colorScheme.background.withOpacity(0.0),
                  t.colorScheme.background,
                ],
                stops: const [0.0, 0.22, 0.55],
              ),
            ),
          ),
        ),
      ),
      // Top icon — single circle with check (CLOAK style)
      Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 22,
          ),
          child: Container(
            width: 49,
            height: 49,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2E2C2C),
            ),
            child: Icon(Icons.check, size: 37, color: t.colorScheme.onPrimary),
          ),
        ),
      ),
      // NFT image card (between checkmark and center text)
      if (isNft && sc?.nftImageUrl != null)
        Align(
          alignment: const Alignment(0.0, -0.28),
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: const Color(0xFF1C1C1E),
            ),
            clipBehavior: Clip.antiAlias,
            child: sc!.nftImageUrl!.startsWith('asset:')
              ? Image.asset(sc.nftImageUrl!.substring(6), fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(Icons.diamond_outlined, size: 64, color: balanceColor))
              : Image.network(sc.nftImageUrl!, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(Icons.diamond_outlined, size: 64, color: balanceColor)),
          ),
        ),
      // Center content — pushed down when NFT image is shown
      Align(
        alignment: Alignment(0.0, isNft ? 0.52 : 0.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(isVaultWithdraw ? 'Withdrawn!' : 'Sent!',
                style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            if (isNft && !isBatch) ...[
              const Gap(4),
              Text(
                sc?.nftName ?? 'NFT #${sc?.nftId}',
                style: t.textTheme.titleSmall?.copyWith(color: balanceColor),
                textAlign: TextAlign.center,
              ),
            ],
            const Gap(8),
            Text(
                isBatch
                    ? 'Your vault assets were successfully withdrawn to'
                    : isNft
                        ? (isVaultWithdraw
                            ? 'Your NFT was successfully withdrawn to'
                            : 'Your NFT was successfully sent to')
                        : isVaultWithdraw
                            ? 'Your ${sc?.tokenSymbol ?? 'CLOAK'} was successfully withdrawn to'
                            : 'Your ${sc?.tokenSymbol ?? 'CLOAK'} was successfully sent to',
                style: t.textTheme.bodySmall),
            const Gap(4),
            Text(previewAddr, style: t.textTheme.bodySmall),
            const Gap(12),
            if (txId != null && !txId!.startsWith('dry_run_'))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.48,
                    child: SizedBox(
                      height: 48,
                      child: Material(
                        color: const Color(0xFF2E2C2C),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _openTx,
                          child: Center(
                            child: Text(
                              s.openInExplorer,
                              style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                                fontFamily: balanceFontFamily,
                                fontWeight: FontWeight.w600,
                                color: t.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      // Close button at bottom
      Positioned(
        left: 0,
        right: 0,
        bottom: 26,
        child: Align(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FractionallySizedBox(
              widthFactor: 0.96,
              child: SizedBox(
                height: 48,
                child: Material(
                  color: balanceColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _closeToBalance,
                    child: Center(
                      child: Text(
                        'Close',
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
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildError(BuildContext context, ThemeData t) {
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final balanceColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    // Clean up the error message for display
    String displayError = error ?? 'Unknown error';
    if (displayError.contains('InsufficientFunds')) {
      final sym = SendContext.instance?.tokenSymbol ?? 'CLOAK';
      displayError = 'Insufficient $sym balance to cover the transaction amount and network fees.';
    }

    return Stack(children: [
      // Top gradient (red tint)
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.redAccent.withOpacity(0.05),
                  t.colorScheme.background.withOpacity(0.0),
                  t.colorScheme.background,
                ],
                stops: const [0.0, 0.22, 0.55],
              ),
            ),
          ),
        ),
      ),
      // Top icon — circle with X
      Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 22,
          ),
          child: Container(
            width: 49,
            height: 49,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2E2C2C),
            ),
            child: Icon(Icons.close, size: 37, color: Colors.redAccent),
          ),
        ),
      ),
      // Center content
      Align(
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Transaction Failed',
                  style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const Gap(12),
              Text(displayError,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(
                      color: t.colorScheme.onSurface.withOpacity(0.7))),
            ],
          ),
        ),
      ),
      // Cancel Transaction button at bottom
      Positioned(
        left: 0,
        right: 0,
        bottom: 26,
        child: Align(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FractionallySizedBox(
              widthFactor: 0.96,
              child: SizedBox(
                height: 48,
                child: Material(
                  color: balanceColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _closeToBalance,
                    child: Center(
                      child: Text(
                        'Cancel Transaction',
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
            ),
          ),
        ),
      ),
    ]);
  }

  _openTx() {
    openTxInExplorer(txId!);
  }

  _closeToBalance() {
    if (_fadeController.isAnimating) return;
    _fadeController.forward().then((_) {
      if (!mounted) return;
      final sc = SendContext.instance;
      try {
        if (sc?.fromThread == true && sc?.threadIndex != null) {
          GoRouter.of(context).go('/messages/details?index=${sc!.threadIndex}');
          return;
        }
      } catch (_) {}
      GoRouter.of(context).go('/account');
    });
  }
}

int _pow10(int exp) {
  int result = 1;
  for (int i = 0; i < exp; i++) result *= 10;
  return result;
}
