// ESR Display Dialog - Shows QR code and clipboard options for ESR URLs
//
// Used when direct Anchor launch fails or isn't supported (e.g., Linux).
// Provides fallback options for users to manually process the ESR.
// Also integrates with Anchor Link WebSocket protocol for automatic response detection.

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:typed_data';

import '../../accounts.dart';
import '../../cloak/anchor_link.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/esr_service.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';

/// Dialog that displays an ESR URL with QR code and copy options
class EsrDisplayDialog extends StatefulWidget {
  final String esrUrl;
  final String? title;
  final String? subtitle;
  /// Optional shield data for CLEOS-style 2-step flow
  /// Contains mintProof, tokenContract, quantity, telosAccount
  final Map<String, dynamic>? shieldData;

  const EsrDisplayDialog({
    super.key,
    required this.esrUrl,
    this.title,
    this.subtitle,
    this.shieldData,
  });

  /// Show the ESR display dialog
  /// Returns the Anchor response if user signed, or null if cancelled
  ///
  /// If [shieldData] is provided, uses CLEOS-style 2-step flow:
  /// - ESR only contains user's transfer actions
  /// - After Anchor signs, completes with thezeosalias signature and broadcasts
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String esrUrl,
    String? title,
    String? subtitle,
    Map<String, dynamic>? shieldData,
  }) {
    return showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => EsrDisplayDialog(
        esrUrl: esrUrl,
        title: title ?? 'Sign Transaction',
        subtitle: subtitle,
        shieldData: shieldData,
      ),
    );
  }

  @override
  State<EsrDisplayDialog> createState() => _EsrDisplayDialogState();
}

class _EsrDisplayDialogState extends State<EsrDisplayDialog> {
  bool _copied = false;
  AnchorLinkClient? _anchorLink;
  AnchorLinkStatus _linkStatus = AnchorLinkStatus.disconnected;
  String? _statusMessage;
  bool _transactionSigned = false;
  bool _showManualEntry = false;
  final _signatureController = TextEditingController();
  bool _isProcessing = false;
  /// On Android, the ESR is regenerated with a Buoy callback URL
  /// once the WebSocket channel is ready.
  String? _androidEsrUrl;

  /// Whether this is an Android two-step flow
  bool get _isAndroidTwoStep =>
      Platform.isAndroid &&
      widget.shieldData != null &&
      widget.shieldData!['isAndroidTwoStep'] == true;

  /// The effective ESR URL (Android may override with callback-enabled version)
  String get _effectiveEsrUrl => _androidEsrUrl ?? widget.esrUrl;

  @override
  void initState() {
    super.initState();
    _initAnchorLink();
    // _startTransactionPolling is called AFTER Anchor is launched
  }

  @override
  void dispose() {
    _anchorLink?.close();
    _signatureController.dispose();
    // If the dialog is dismissed without a successful broadcast,
    // rollback wallet state to prevent phantom transactions
    if (!_transactionSigned) {
      _rollbackWalletState();
    }
    super.dispose();
  }

  /// Rollback wallet state from the pre-proof snapshot if available.
  /// This undoes the state mutation from transactPacked() that happens
  /// during ZK proof generation, preventing phantom transactions.
  Future<void> _rollbackWalletState() async {
    final snapshot = widget.shieldData?['_walletSnapshot'];
    if (snapshot is Uint8List) {
      await CloakWalletManager.restoreWalletFromSnapshot(snapshot);
    }
  }

  /// No auto-detection — user taps Done
  void _startTransactionPolling() {}

  /// Process manually entered signature from desktop Anchor
  Future<void> _processManualSignature() async {
    final sig = _signatureController.text.trim();
    if (sig.isEmpty) {
      showSnackBar('Please paste the signature from Anchor');
      return;
    }

    if (!sig.startsWith('SIG_K1_')) {
      showSnackBar('Invalid signature format. Should start with SIG_K1_');
      return;
    }

    // Check if we have a pending transaction
    if (!EsrService.hasPendingTransaction) {
      showSnackBar('No pending transaction. Please generate a new ESR first.');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Broadcasting transaction...';
    });

    try {
      // Broadcast using the stored transaction + user's signature + thezeosalias signature
      final txId = await EsrService.broadcastWithManualSignature(sig);

      setState(() {
        _transactionSigned = true;
        _statusMessage = 'Transaction broadcast!';
      });

      showSnackBar('Transaction broadcast successfully!');

      // Close dialog after short delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pop({'transaction_id': txId});
      }
    } catch (e) {
      print('[EsrDisplayDialog] Manual broadcast error: $e');
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Error: $e';
      });
      showSnackBar('Error: $e');
    }
  }

  /// Initialize Anchor Link WebSocket connection
  Future<void> _initAnchorLink() async {
    // Create client with Telos chain ID
    _anchorLink = AnchorLinkClient(
      chainId: '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11',
      onStatusChange: (status, message) {
        if (mounted) {
          setState(() {
            _linkStatus = status;
            _statusMessage = message;
          });
        }
      },
    );

    // Connect first to get channel ID for QR code
    final connected = await _anchorLink!.connect();
    if (connected && mounted) {
      if (_isAndroidTwoStep) {
        // Android two-step flow:
        // Generate a transfer-only ESR with Buoy callback URL.
        // Anchor broadcasts the transfers, POSTs the result to Buoy,
        // we receive it on the WebSocket, then broadcast begin/mint/end.
        final channelId = _anchorLink!.channelId!;
        final callbackUrl = 'https://cb.anchor.link/$channelId';
        final sd = widget.shieldData!;
        _androidEsrUrl = await EsrService.createTransferOnlyEsr(
          tokenContract: sd['tokenContract'] as String,
          quantity: sd['quantity'] as String,
          userAccount: sd['telosAccount'] as String,
          feeQuantity: sd['feeQuantity'] as String? ?? '0.3000 CLOAK',
          callbackUrl: callbackUrl,
        );
      } else {
        // Desktop: send ESR to relay for QR-scan / Anchor Link flow
        _anchorLink!.sendRequest(widget.esrUrl);
      }
      // Force rebuild so QR code includes channel ID / new ESR
      setState(() {});
      // Start listening for response in background
      _waitForResponseInBackground();
    }

    // Auto-launch Anchor with the ESR
    await _launchAnchorDesktop();
    // Snapshot AFTER Anchor launch — avoids capturing stale values from before
    _startTransactionPolling();
  }

  /// Wait for Anchor to respond after signing
  ///
  /// Desktop (flags=0): Anchor returns signed transaction via WebSocket relay.
  /// Flutter adds thezeosalias signature and broadcasts.
  ///
  /// Android two-step (flags=3): Anchor broadcasts user's transfers, POSTs
  /// CallbackPayload to Buoy relay. Flutter receives it on WebSocket, then
  /// broadcasts begin/mint/end via broadcastMintOnly().
  Future<void> _waitForResponseInBackground() async {
    try {
      final response = await _anchorLink?.waitForResponse(
        timeout: const Duration(minutes: 5),
      );

      if (response != null && mounted) {
        setState(() {
          _transactionSigned = true;
          _statusMessage = 'Processing response...';
        });

        try {
          String? txId;

          if (_isAndroidTwoStep) {
            // Android two-step: Anchor already broadcast the 2 user transfers.
            // The response is a Buoy-relayed CallbackPayload with keys like:
            // sig, tx, bn, sa, sp, rbn, rid, ex, cid, req
            // OR it could be the raw POST body as a JSON string.
            final transferTxId = response['tx']?.toString() ??
                response['transaction_id']?.toString() ??
                response['txid']?.toString();
            print('[EsrDisplayDialog] Android callback received. Transfer TX: $transferTxId');

            // Step 2: Broadcast begin/mint/end with thezeosalias key
            setState(() {
              _statusMessage = 'Completing shield (ZK proof)...';
            });

            final sd = widget.shieldData!;
            final mintProof = sd['mintProof'] as Map<String, dynamic>;
            txId = await EsrService.broadcastMintOnly(
              mintProof: mintProof,
              feeQuantity: sd['feeQuantity'] as String? ?? '0.3000 CLOAK',
            );
          } else {
            // Desktop flow: flags=0 - Anchor returns signed transaction
            if (response.containsKey('serializedTransaction') ||
                response.containsKey('packed_trx') ||
                response.containsKey('signatures')) {
              setState(() {
                _statusMessage = 'Adding protocol signature and broadcasting...';
              });
              txId = await EsrService.addSignatureAndBroadcast(response);
            } else if (response.containsKey('transaction_id')) {
              txId = response['transaction_id']?.toString();
            } else if (response.containsKey('processed')) {
              final processed = response['processed'];
              if (processed is Map) {
                txId = processed['id']?.toString();
              }
            } else if (response.containsKey('transaction')) {
              setState(() {
                _statusMessage = 'Adding protocol signature and broadcasting...';
              });
              txId = await EsrService.addSignatureAndBroadcast(response);
            } else {
              final errorMsg = response['error']?.toString() ??
                               response['message']?.toString();
              if (errorMsg != null) {
                throw Exception('Anchor returned error: $errorMsg');
              }
              final status = response['status']?.toString();
              if (status == 'rejected' || status == 'cancelled' || status == 'expired') {
                throw Exception('Transaction was $status by user');
              }
              txId = response['txid']?.toString() ??
                     response['trx_id']?.toString() ??
                     response['tx']?.toString() ??
                     response['id']?.toString();
              if (txId == null) {
                txId = await EsrService.addSignatureAndBroadcast(response);
              }
            }
          }

          final result = {'transaction_id': txId};

          if (mounted) {
            setState(() {
              _statusMessage = 'Transaction broadcast!';
            });
          }

          // Persist wallet state now that broadcast succeeded
          await CloakWalletManager.saveWallet();

          showSnackBar('Transaction broadcast successfully!');
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            Navigator.of(context).pop(result);
          }
        } catch (e) {
          print('[EsrDisplayDialog] Error processing response: $e');
          // Rollback wallet state since broadcast failed
          await _rollbackWalletState();
          if (mounted) {
            setState(() {
              _linkStatus = AnchorLinkStatus.error;
              _statusMessage = 'Broadcast failed: ${e.toString()}';
              _transactionSigned = false;
            });
            showSnackBar('Error: ${e.toString()}');
          }
        }
      }
    } catch (e) {
      print('[EsrDisplayDialog] Anchor Link error: $e');
      if (mounted) {
        setState(() {
          _linkStatus = AnchorLinkStatus.error;
          _statusMessage = 'Error: ${e.toString()}';
        });
      }
    }
  }

  /// Get the QR data with Anchor Link channel ID if connected
  String get _qrData {
    if (_anchorLink != null && _anchorLink!.status != AnchorLinkStatus.disconnected) {
      // Include channel ID for automatic response via WebSocket
      return AnchorLinkClient.generateQrData(_effectiveEsrUrl, _anchorLink!.channelId ?? '');
    }
    return _effectiveEsrUrl;
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: _effectiveEsrUrl));
    setState(() => _copied = true);
    showSnackBar('ESR URL copied to clipboard');

    // Reset copied state after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _openInBrowser() async {
    // Open via eosio.to web resolver
    final webUrl = Uri.parse('https://eosio.to/${_effectiveEsrUrl}');
    try {
      await launchUrl(webUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        showSnackBar('Could not open browser: $e');
      }
    }
  }

  /// Launch Anchor Desktop directly with the ESR
  Future<void> _launchAnchorDesktop() async {
    try {
      // Use the raw ESR URL — Anchor Desktop handles esr:// protocol directly
      // Don't append callback channel (corrupts the base64 payload)
      final launched = await EsrService.launchAnchor(_effectiveEsrUrl);
      if (launched) {
      } else {
      }
    } catch (e) {
    }
  }

  /// Build status indicator for Anchor Link connection
  Widget _buildStatusIndicator(ThemeData t) {
    Color statusColor;
    IconData statusIcon;
    String statusText;

    switch (_linkStatus) {
      case AnchorLinkStatus.connecting:
        statusColor = Colors.orange;
        statusIcon = Icons.sync;
        statusText = 'Connecting to Anchor Link...';
        break;
      case AnchorLinkStatus.waitingForWallet:
        statusColor = Colors.blue;
        statusIcon = Icons.hourglass_empty;
        statusText = 'Waiting for Anchor wallet...';
        break;
      case AnchorLinkStatus.processing:
        statusColor = Colors.purple;
        statusIcon = Icons.pending;
        statusText = _statusMessage ?? 'Processing response...';
        break;
      case AnchorLinkStatus.completed:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        statusText = _statusMessage ?? 'Transaction complete!';
        break;
      case AnchorLinkStatus.error:
        statusColor = Colors.red;
        statusIcon = Icons.error;
        statusText = _statusMessage ?? 'Connection error';
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.cloud_off;
        statusText = 'Not connected';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_linkStatus == AnchorLinkStatus.connecting ||
              _linkStatus == AnchorLinkStatus.waitingForWallet)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              ),
            )
          else
            Icon(statusIcon, size: 16, color: statusColor),
          const Gap(8),
          Text(
            statusText,
            style: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final mediaQuery = MediaQuery.of(context);
    final qrSize = mediaQuery.size.width * 0.40; // Smaller QR to fit better

    return Container(
      height: mediaQuery.size.height * 0.9,
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle bar (fixed at top)
          const Gap(12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.colorScheme.onSurface.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Gap(12),

          // Title (fixed at top)
          if (widget.title != null) ...[
            Text(
              widget.title!,
              style: t.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Gap(8),
          ],

          // Scrollable content
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                bottom: mediaQuery.padding.bottom + 16,
              ),
              child: Column(
                children: [
                  if (!_transactionSigned) ...[
                  // Subtitle/instructions
                  Text(
                    widget.subtitle ??
                      'Scan this QR code with Anchor wallet, or copy the link and paste it in Anchor\'s URI handler.',
                    style: t.textTheme.bodyMedium?.copyWith(
                      color: t.colorScheme.onSurface.withOpacity(0.7),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const Gap(16),

                  // Anchor Link Status Indicator
                  if (false) ...[
                    _buildStatusIndicator(t),
                    const Gap(12),
                  ],

                  // QR Code (with checkmark overlay if signed)
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: QrImage(
                          data: _qrData,
                          size: qrSize,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      // Success overlay when signed
                      if (_transactionSigned)
                        Container(
                          width: qrSize + 24,
                          height: qrSize + 24,
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle, color: Colors.white, size: 48),
                              Gap(8),
                              Text(
                                'Signed!',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const Gap(16),

                  // Action buttons (dark theme, matching More menu patterns)
                  // Copy ESR Link
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: Material(
                      color: _copied ? const Color(0xFF2E4A2E) : const Color(0xFF2E2C2C),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _copyToClipboard,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_copied ? Icons.check : Icons.copy, size: 18, color: balanceTextColor),
                            const SizedBox(width: 8),
                            Text(
                              _copied ? 'Copied!' : 'Copy ESR Link',
                              style: TextStyle(color: balanceTextColor, fontFamily: balanceFontFamily, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Gap(10),

                  // Launch Anchor Desktop
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: Material(
                      color: const Color(0xFF2E2C2C),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _launchAnchorDesktop,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.launch, size: 18, color: balanceTextColor),
                            const SizedBox(width: 8),
                            Text(
                              'Launch Anchor',
                              style: TextStyle(color: balanceTextColor, fontFamily: balanceFontFamily, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Gap(16),

                  ], // end if (!_transactionSigned)

                  // Done button — always visible, takes user to balance page
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: Material(
                      color: balanceTextColor,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          // 1. Navigate to balance behind the sheet (user can't see it yet)
                          GoRouter.of(context).go('/account');
                          // 2. Wait for balance page to fully render behind the sheet
                          await Future.delayed(const Duration(milliseconds: 500));
                          // 3. Pop the sheet — it slides down to reveal balance
                          if (mounted) Navigator.of(context).pop({'status': 'completed_manually'});
                        },
                        child: Center(
                          child: Text(
                            'DONE',
                            style: TextStyle(
                              color: t.colorScheme.background,
                              fontFamily: balanceFontFamily,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Gap(12),

                  // Manual signature entry (fallback) — hidden after success
                  if (!_transactionSigned && !_showManualEntry) ...[
                    Center(
                      child: InkWell(
                        onTap: () => setState(() => _showManualEntry = true),
                        child: Text(
                          'Advanced: Paste signature manually',
                          style: TextStyle(color: balanceTextColor.withOpacity(0.5), fontSize: 12, fontFamily: balanceFontFamily),
                        ),
                      ),
                    ),
                  ] else if (!_transactionSigned) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E2C2C),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Paste Raw Signature from Anchor:',
                            style: TextStyle(color: balanceTextColor.withOpacity(0.7), fontSize: 12, fontFamily: balanceFontFamily),
                          ),
                          const Gap(8),
                          TextField(
                            controller: _signatureController,
                            maxLines: 2,
                            cursorColor: balanceTextColor,
                            style: TextStyle(color: balanceTextColor, fontFamily: 'monospace', fontSize: 12),
                            decoration: InputDecoration(
                              hintText: 'SIG_K1_...',
                              hintStyle: TextStyle(color: balanceTextColor.withOpacity(0.3)),
                              filled: true,
                              fillColor: Colors.black.withOpacity(0.3),
                              contentPadding: const EdgeInsets.all(10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            ),
                          ),
                          const Gap(10),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: Material(
                              color: balanceTextColor,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: _isProcessing ? null : _processManualSignature,
                                child: Center(
                                  child: _isProcessing
                                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.colorScheme.background))
                                      : Text('Sign & Broadcast', style: TextStyle(color: t.colorScheme.background, fontFamily: balanceFontFamily, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Gap(12),

                  // Instructions — hidden after success
                  if (!_transactionSigned)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E2C2C),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline, color: balanceTextColor.withOpacity(0.5), size: 16),
                            const Gap(8),
                            Text(
                              'How to use in Anchor:',
                              style: TextStyle(
                                color: balanceTextColor.withOpacity(0.7),
                                fontFamily: balanceFontFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const Gap(8),
                        Text(
                          '1. Click on Import Transaction\n'
                          '2. Import ESR Payload\n'
                          '3. Paste the ESR Link\n'
                          '4. Trigger Signing Request',
                          style: TextStyle(
                            color: balanceTextColor.withOpacity(0.5),
                            fontFamily: balanceFontFamily,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Gap(16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
