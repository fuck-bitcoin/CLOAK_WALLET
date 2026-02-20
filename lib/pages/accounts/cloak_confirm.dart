import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:convert';
import 'dart:math' show pow;
import 'dart:ui' show FontFeature;

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../../theme/zashi_tokens.dart';
import '../../cloak/cloak_wallet_manager.dart';
import 'send.dart' show SendContext, BatchAsset;
import '../utils.dart';

/// CLOAK send confirmation page — mirrors the Zcash TxPlanPage flow.
/// Shows amount, fee, total, recipient, memo before ZKP generation.
class CloakConfirmPage extends StatefulWidget {
  CloakConfirmPage();

  @override
  State<StatefulWidget> createState() => _CloakConfirmState();
}

class _CloakConfirmState extends State<CloakConfirmPage> {
  bool _addrExpanded = false;
  bool _msgExpanded = false;
  final GlobalKey _contentKey = GlobalKey();
  bool _contentTooTall = false;
  bool _sending = false;
  bool _feeLoaded = false;

  // Fee in smallest units (10000 = 1.0 CLOAK)
  int _feeUnits = 4000; // conservative default (0.4 CLOAK); overwritten by dynamic fetch
  static const int _unitScale = 10000;

  @override
  void initState() {
    super.initState();
    _fetchFee();
  }

  Future<void> _fetchFee() async {
    final sc = SendContext.instance;
    // Batch withdrawal uses fixed base fee (single authenticate TX)
    if (sc != null && sc.isBatchWithdraw) {
      // Batch: begin + authenticate + mint + spend per entry
      try {
        final feeStr = await CloakWalletManager.getWithdrawFee();
        final parsed = double.tryParse(feeStr.split(' ').first);
        if (parsed != null && mounted) {
          setState(() {
            _feeUnits = (parsed * _unitScale).round();
            _feeLoaded = true;
          });
          return;
        }
      } catch (_) {}
      if (mounted) setState(() => _feeLoaded = true);
      return;
    }

    final bool isVaultWithdraw = sc?.vaultHash != null && sc!.vaultHash!.isNotEmpty;
    final bool isVaultDeposit = sc?.isVaultDeposit == true;

    try {
      String feeStr;
      if (isVaultWithdraw) {
        feeStr = await CloakWalletManager.getWithdrawFee();
      } else if (isVaultDeposit) {
        // Deposit is a regular send to thezeosvault — use same estimator
        feeStr = await CloakWalletManager.getSendFee(
          sendAmountUnits: sc?.amount.value,
        );
      } else {
        // Regular send — use Rust estimator for note-fragmentation-aware fee
        feeStr = await CloakWalletManager.getSendFee(
          sendAmountUnits: sc?.amount.value,
          recipientAddress: sc?.address,
        );
      }
      final parts = feeStr.split(' ');
      if (parts.isNotEmpty) {
        final parsed = double.tryParse(parts.first);
        if (parsed != null && mounted) {
          setState(() {
            _feeUnits = (parsed * _unitScale).round();
            _feeLoaded = true;
          });
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _feeLoaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final sc = SendContext.instance;
    if (sc == null) {
      return Scaffold(
        body: Center(child: Text('No send context')),
      );
    }

    final t = Theme.of(context);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final balanceColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    const addressFillColor = Color(0xFF2E2C2C);

    final bool isBatch = sc.isBatchWithdraw && sc.batchAssets != null && sc.batchAssets!.isNotEmpty;
    final bool isNft = !isBatch && sc.nftId != null && sc.nftId!.isNotEmpty;
    final String symbol = isNft ? 'NFT' : (sc.tokenSymbol ?? 'CLOAK');
    final String contract = isNft ? (sc.nftContract ?? 'atomicassets') : (sc.tokenContract ?? 'thezeostoken');
    final int precision = isNft ? 0 : (sc.tokenPrecision ?? 4);
    final int tokenUnitScale = isNft ? 1 : pow(10, precision).toInt();
    final bool isCloak = !isNft && symbol == 'CLOAK';
    final bool isVaultWithdraw = sc.vaultHash != null && sc.vaultHash!.isNotEmpty;

    final int sendUnits = sc.amount.value;
    // Total only meaningful when both amount and fee are same token (CLOAK)
    final int totalUnits = isCloak ? sendUnits + _feeUnits : sendUnits;

    return Scaffold(
      appBar: AppBar(
        title: Builder(builder: (context) {
          final t = Theme.of(context);
          final base = t.appBarTheme.titleTextStyle ??
              t.textTheme.titleLarge ??
              t.textTheme.titleMedium ??
              t.textTheme.bodyMedium;
          final reduced = (base?.fontSize != null)
              ? base!.copyWith(fontSize: base.fontSize! * 0.75)
              : base;
          return Text(isBatch ? 'QUICK WITHDRAWAL' : isVaultWithdraw ? 'VAULT WITHDRAWAL' : sc.isVaultDeposit ? 'DEPOSIT CONFIRMATION' : (isNft ? 'NFT CONFIRMATION' : 'CONFIRMATION'), style: reduced);
        }),
        centerTitle: true,
        leading: IconButton(
          onPressed: () {
            final sc = SendContext.instance;
            if (sc?.fromThread == true && sc?.threadIndex != null) {
              GoRouter.of(context).go('/messages/details?index=${sc!.threadIndex}');
            } else {
              GoRouter.of(context).go('/account');
            }
          },
          icon: const Icon(Icons.close),
        ),
        actions: const [],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LayoutBuilder(builder: (context, constraints) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _contentKey.currentContext;
              final size = ctx?.size;
              if (size != null) {
                final tooTall = size.height > constraints.maxHeight;
                if (mounted && tooTall != _contentTooTall) {
                  setState(() => _contentTooTall = tooTall);
                }
              }
            });
            final scrollable = _msgExpanded || _addrExpanded || _contentTooTall;
            return SingleChildScrollView(
              physics: scrollable
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: Column(
                key: _contentKey,
                children: [
                  const Gap(22),
                  // Sending header
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon: NFT thumbnail with sent badge, or send arrow
                      if (!isBatch && isNft && sc.nftImageUrl != null) ...[
                        SizedBox(
                          width: 110,
                          height: 110,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: const Color(0xFF2E2C2C),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: sc.nftImageUrl!.startsWith('asset:')
                                  ? Image.asset(sc.nftImageUrl!.substring(6), fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Icon(Icons.diamond_outlined, size: 48, color: balanceColor))
                                  : Image.network(sc.nftImageUrl!, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Icon(Icons.diamond_outlined, size: 48, color: balanceColor)),
                              ),
                              // Sent badge — bottom-right corner
                              Positioned(
                                right: -3,
                                bottom: -3,
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: balanceColor,
                                  ),
                                  child: Icon(Icons.arrow_upward, size: 20, color: t.colorScheme.background),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Container(
                          width: 49,
                          height: 49,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF2E2C2C),
                          ),
                          child: Icon(isNft ? Icons.diamond_outlined : Icons.send, size: 24, color: balanceColor),
                        ),
                      ],
                      const Gap(8),
                      Builder(builder: (context) {
                        final base = t.appBarTheme.titleTextStyle ??
                            t.textTheme.titleLarge ??
                            t.textTheme.titleMedium ??
                            t.textTheme.bodyMedium;
                        final style = base?.copyWith(
                          fontSize: (base.fontSize ?? 18) * 0.7425,
                        ) ?? const TextStyle();
                        if (isBatch) {
                          return Text('Withdrawing All Assets', style: style);
                        }
                        if (isNft) {
                          return Text(isVaultWithdraw ? 'Withdrawing NFT' : 'Sending NFT', style: style);
                        }
                        return Text(isVaultWithdraw ? 'Withdrawing' : 'Sending', style: style);
                      }),
                      const Gap(2),
                      // Amount or NFT name/ID display (batch shows asset count summary)
                      Builder(builder: (context) {
                        if (isBatch) {
                          final batchFts = sc.batchAssets!.where((a) => !a.isNft).toList();
                          final batchNfts = sc.batchAssets!.where((a) => a.isNft).toList();
                          final parts = <String>[];
                          if (batchFts.isNotEmpty) {
                            parts.add('${batchFts.length} token${batchFts.length == 1 ? '' : 's'}');
                          }
                          if (batchNfts.isNotEmpty) {
                            parts.add('${batchNfts.length} NFT${batchNfts.length == 1 ? '' : 's'}');
                          }
                          return Text(
                            parts.join(', '),
                            style: t.textTheme.bodySmall?.copyWith(
                              color: balanceColor.withOpacity(0.6),
                            ),
                          );
                        }

                        if (isNft) {
                          // Show NFT name prominently, ID + contract smaller underneath
                          final nftDisplayName = sc.nftName ?? 'NFT #${sc.nftId!}';
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                nftDisplayName,
                                style: (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
                                  color: balanceColor,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '#${sc.nftId!}',
                                style: t.textTheme.bodySmall?.copyWith(
                                  color: balanceColor.withOpacity(0.5),
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                sc.nftContract ?? 'atomicassets',
                                style: t.textTheme.bodySmall?.copyWith(color: balanceColor.withOpacity(0.4)),
                              ),
                            ],
                          );
                        }

                        final amtToken = sendUnits / tokenUnitScale.toDouble();
                        final amtStr = amtToken.toStringAsFixed(precision);

                        final Color amtColor = balanceColor;
                        final TextStyle bigStyle = (t.textTheme.displaySmall ?? const TextStyle()).copyWith(
                          color: amtColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        );

                        final amountWidget = Text(
                          '$amtStr $symbol',
                          style: bigStyle,
                          textAlign: TextAlign.center,
                        );

                        // Fiat line — only for CLOAK
                        String? txtFiat;
                        if (isCloak) {
                          final fx = sc.fx ?? marketPrice.price;
                          if (fx != null && fx > 0) {
                            final fiat = amtToken * fx;
                            txtFiat = decimalFormat(fiat, 2, symbol: appSettings.currency);
                          }
                        }

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            amountWidget,
                            if (txtFiat != null) ...[
                              const SizedBox(height: 12),
                              Text(txtFiat, style: t.textTheme.bodyMedium?.copyWith(color: balanceColor)),
                            ],
                          ],
                        );
                      }),
                    ],
                  ),
                  const Gap(24),
                  // Sending to (collapsible)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.center,
                      child: FractionallySizedBox(
                        widthFactor: 0.96,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Transaction Details',
                              style: t.textTheme.titleSmall?.copyWith(fontFamily: balanceFontFamily),
                            ),
                            const Gap(12),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => setState(() => _addrExpanded = !_addrExpanded),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: addressFillColor,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  child: Builder(builder: (context) {
                                    final full = (sc.address).trim();
                                    final textStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                                      fontFamily: balanceFontFamily,
                                      color: t.colorScheme.onSurface,
                                    );
                                    final monoStyle = GoogleFonts.jetBrainsMono(
                                      textStyle: t.textTheme.bodyMedium,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                        FontFeature.slashedZero(),
                                      ],
                                      color: t.colorScheme.onSurface,
                                    );
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment: CrossAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              child: Text((isBatch || isVaultWithdraw) ? 'Withdrawing to' : 'Sending to', maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
                                            ),
                                            if ((sc.display ?? '').isNotEmpty)
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const SizedBox(width: 8),
                                                  ConstrainedBox(
                                                    constraints: const BoxConstraints(maxWidth: 160),
                                                    child: Text(sc.display!, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle, textAlign: TextAlign.right),
                                                  ),
                                                  const SizedBox(width: 8),
                                                ],
                                              ),
                                            AnimatedRotation(
                                              duration: const Duration(milliseconds: 180),
                                              turns: _addrExpanded ? 0.5 : 0.0,
                                              child: Icon(Icons.expand_more, color: t.colorScheme.onSurface),
                                            ),
                                          ],
                                        ),
                                        AnimatedCrossFade(
                                          duration: const Duration(milliseconds: 180),
                                          firstChild: const SizedBox.shrink(),
                                          secondChild: Padding(
                                            padding: const EdgeInsets.only(top: 8),
                                            child: Text(full, style: monoStyle, softWrap: true),
                                          ),
                                          crossFadeState: _addrExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                        ),
                                      ],
                                    );
                                  }),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Gap(12),
                  // Amount / Fee / Total summary box
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.center,
                      child: FractionallySizedBox(
                        widthFactor: 0.96,
                        child: Container(
                          decoration: BoxDecoration(
                            color: addressFillColor,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Builder(builder: (context) {
                            final labelStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                              fontFamily: balanceFontFamily,
                              color: t.colorScheme.onSurface,
                            );
                            final valueStyle = labelStyle;
                            final valueBold = valueStyle.copyWith(fontWeight: FontWeight.w700);

                            Widget row(String label, String value, {bool bold = false}) {
                              return Row(
                                children: [
                                  Expanded(child: Text(label, style: bold ? labelStyle.copyWith(fontWeight: FontWeight.w700) : labelStyle)),
                                  Flexible(child: Text(value, style: bold ? valueBold : valueStyle, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis)),
                                ],
                              );
                            }

                            final feeStr = (_feeUnits / _unitScale.toDouble()).toStringAsFixed(4);

                            if (isBatch) {
                              // Batch withdrawal: list each asset + divider + fee
                              final batchFts = sc.batchAssets!.where((a) => !a.isNft).toList();
                              final batchNfts = sc.batchAssets!.where((a) => a.isNft).toList();
                              return Column(
                                children: [
                                  for (int i = 0; i < batchFts.length; i++) ...[
                                    row(batchFts[i].symbol, batchFts[i].formattedAmount),
                                    if (i < batchFts.length - 1 || batchNfts.isNotEmpty) const Gap(8),
                                  ],
                                  for (int i = 0; i < batchNfts.length; i++) ...[
                                    row('NFT', batchNfts[i].nftName ?? '#${batchNfts[i].nftId}'),
                                    if (i < batchNfts.length - 1) const Gap(8),
                                  ],
                                  if (batchFts.isNotEmpty || batchNfts.isNotEmpty) const Gap(8),
                                  Divider(color: t.colorScheme.onSurface.withOpacity(0.12), height: 1),
                                  const Gap(8),
                                  row('Fee', '$feeStr CLOAK', bold: true),
                                ],
                              );
                            }

                            if (isNft) {
                              // NFT: show name, ID, contract, fee
                              return Column(
                                children: [
                                  row('Asset', sc.nftName ?? 'NFT'),
                                  const Gap(8),
                                  row('ID', '#${sc.nftId!}'),
                                  const Gap(8),
                                  row('Contract', sc.nftContract ?? 'atomicassets'),
                                  const Gap(8),
                                  row('Fee', '$feeStr CLOAK', bold: true),
                                ],
                              );
                            }

                            final sendStr = (sendUnits / tokenUnitScale.toDouble()).toStringAsFixed(precision);

                            if (isCloak) {
                              // Same token for amount + fee → show total
                              final totalStr = (totalUnits / _unitScale.toDouble()).toStringAsFixed(4);
                              return Column(
                                children: [
                                  row('Amount', '$sendStr CLOAK'),
                                  const Gap(8),
                                  row('Fee', '$feeStr CLOAK'),
                                  const Gap(8),
                                  row('Total', '$totalStr CLOAK', bold: true),
                                ],
                              );
                            } else {
                              // Different tokens — can't sum, show separately
                              return Column(
                                children: [
                                  row('Amount', '$sendStr $symbol'),
                                  const Gap(8),
                                  row('Fee', '$feeStr CLOAK'),
                                ],
                              );
                            }
                          }),
                        ),
                      ),
                    ),
                  ),
                  const Gap(12),
                  // Message box (collapsible) — hidden for vault operations (memo is auto-generated)
                  if (!sc.isVaultDeposit && !isVaultWithdraw && !isBatch)
                    _buildMemoBox(context, sc, t, balanceFontFamily),
                  const Gap(27),
                  // Send button or insufficient balance message
                  if (!_sending)
                    Builder(builder: (context) {
                      // In vault mode or batch mode, aa.poolBalances = vault balance.
                      // Wallet shielded CLOAK (for fees) must be read from getBalancesJson.
                      final bool isVaultDeposit = sc.isVaultDeposit;
                      final int walletCloakBalance;
                      if (isBatch || isVaultWithdraw || isVaultDeposit) {
                        int wBal = 0;
                        try {
                          final raw = CloakWalletManager.getBalancesJson();
                          if (raw != null) {
                            final List<dynamic> parsed = jsonDecode(raw);
                            for (final entry in parsed) {
                              final str = entry.toString();
                              if (str.contains('CLOAK@thezeostoken')) {
                                final atIdx = str.lastIndexOf('@');
                                final qp = str.substring(0, atIdx);
                                final si = qp.lastIndexOf(' ');
                                if (si >= 0) {
                                  wBal = ((double.tryParse(qp.substring(0, si)) ?? 0.0) * 10000).round();
                                }
                                break;
                              }
                            }
                          }
                        } catch (_) {}
                        walletCloakBalance = wBal;
                      } else {
                        walletCloakBalance = aa.poolBalances.sapling;
                      }
                      final vaultBalance = isVaultWithdraw ? aa.poolBalances.sapling : 0;
                      bool insufficient = false;
                      String insufficientMsg = 'Insufficient Balance';
                      if (isBatch) {
                        // Batch withdrawal: only need wallet CLOAK for fee
                        if (_feeLoaded && walletCloakBalance < _feeUnits) {
                          insufficient = true;
                          insufficientMsg = 'Insufficient CLOAK for Fee';
                        }
                      } else if (isNft) {
                        // NFT: only need enough CLOAK for fee
                        if (_feeLoaded && walletCloakBalance < _feeUnits) {
                          insufficient = true;
                          insufficientMsg = 'Insufficient CLOAK for Fee';
                        }
                      } else if (isVaultWithdraw) {
                        // Vault withdraw: amount from vault, fee from wallet shielded CLOAK
                        if (_feeLoaded) {
                          if (vaultBalance < sendUnits) {
                            insufficient = true;
                            insufficientMsg = 'Insufficient Vault Balance';
                          } else if (walletCloakBalance < _feeUnits) {
                            insufficient = true;
                            insufficientMsg = 'Insufficient CLOAK for Fee';
                          }
                        }
                      } else if (isCloak) {
                        // CLOAK: amount + fee must be covered by CLOAK balance
                        insufficient = _feeLoaded && walletCloakBalance < totalUnits;
                        insufficientMsg = 'Insufficient CLOAK Balance';
                      } else {
                        // Non-CLOAK: need enough token for amount AND enough CLOAK for fee
                        // Get token balance from getBalancesJson
                        int tokenBalance = 0;
                        try {
                          final raw = CloakWalletManager.getBalancesJson();
                          if (raw != null) {
                            final List<dynamic> parsed = jsonDecode(raw);
                            for (final entry in parsed) {
                              final str = entry.toString();
                              final atIdx = str.lastIndexOf('@');
                              if (atIdx < 0) continue;
                              final qp = str.substring(0, atIdx);
                              final c = str.substring(atIdx + 1);
                              final si = qp.lastIndexOf(' ');
                              if (si < 0) continue;
                              final sym = qp.substring(si + 1);
                              final amt = qp.substring(0, si);
                              if (sym == symbol && c == contract) {
                                tokenBalance = ((double.tryParse(amt) ?? 0.0) * tokenUnitScale).round();
                                break;
                              }
                            }
                          }
                        } catch (_) {}
                        if (_feeLoaded) {
                          if (tokenBalance < sendUnits) {
                            insufficient = true;
                            insufficientMsg = 'Insufficient $symbol Balance';
                          } else if (walletCloakBalance < _feeUnits) {
                            insufficient = true;
                            insufficientMsg = 'Insufficient CLOAK for Fee';
                          }
                        }
                      }
                      if (insufficient) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.center,
                            child: FractionallySizedBox(
                              widthFactor: 0.96,
                              child: SizedBox(
                                height: 48,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2E2C2C),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Center(
                                    child: Text(
                                      insufficientMsg,
                                      style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                                        fontFamily: balanceFontFamily,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.center,
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
                                  onTap: _doSend,
                                  child: Center(
                                    child: Text(
                                      isBatch ? 'Withdraw All' : isVaultWithdraw ? 'Withdraw' : sc.isVaultDeposit ? 'Deposit' : (isNft ? 'Send NFT' : 'Send'),
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
                      );
                    }),
                  // Vault / batch fee explanation
                  if (isBatch || isVaultWithdraw) ...[
                    const Gap(16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'The withdrawal amount comes from your vault. The network fee is paid from your wallet\'s shielded CLOAK balance.',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: t.colorScheme.onSurface.withOpacity(0.45),
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                  // Vault deposit fee explanation
                  if (sc.isVaultDeposit) ...[
                    const Gap(16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'The deposit amount and network fee are both paid from your wallet\'s shielded CLOAK balance.',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: t.colorScheme.onSurface.withOpacity(0.45),
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildMemoBox(BuildContext context, SendContext sc, ThemeData t, String? balanceFontFamily) {
    const fill = Color(0xFF2E2C2C);
    final memoText = (sc.memo?.memo ?? '').trim();
    final hasMemo = memoText.isNotEmpty;

    final previewStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontFamily: balanceFontFamily,
      color: t.colorScheme.onSurface,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.center,
        child: FractionallySizedBox(
          widthFactor: 0.96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Message',
                style: t.textTheme.titleSmall?.copyWith(fontFamily: balanceFontFamily),
              ),
              const Gap(12),
              if (!hasMemo)
                Container(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  constraints: const BoxConstraints(minHeight: 52),
                )
              else
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _msgExpanded = !_msgExpanded),
                    child: Container(
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  memoText,
                                  maxLines: _msgExpanded ? null : 1,
                                  overflow: _msgExpanded ? null : TextOverflow.ellipsis,
                                  style: previewStyle,
                                ),
                              ),
                              AnimatedRotation(
                                duration: const Duration(milliseconds: 180),
                                turns: _msgExpanded ? 0.5 : 0.0,
                                child: Icon(Icons.expand_more, color: t.colorScheme.onSurface),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _doSend() async {
    if (_sending) return;
    setState(() => _sending = true);
    GoRouter.of(context).go('/account/cloak_submit');
  }
}
