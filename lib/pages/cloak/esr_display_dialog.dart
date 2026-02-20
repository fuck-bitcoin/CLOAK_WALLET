// ESR Display Dialog - Shows QR code and clipboard options for ESR URLs
//
// Used when direct Anchor launch fails or isn't supported (e.g., Linux).
// Provides fallback options for users to manually process the ESR.
// Also integrates with Anchor Link WebSocket protocol for automatic response detection.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../cloak/anchor_link.dart';
import '../../cloak/esr_service.dart';
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

  @override
  void initState() {
    super.initState();
    _initAnchorLink();
  }

  @override
  void dispose() {
    _anchorLink?.close();
    _signatureController.dispose();
    super.dispose();
  }

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

      print('[EsrDisplayDialog] Manual broadcast successful! TX: $txId');

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
      // Force rebuild so QR code includes channel ID
      setState(() {});
      // Start listening for response in background
      _waitForResponseInBackground();
    }
  }

  /// Wait for Anchor to respond after signing
  ///
  /// With flags=0 (current implementation), Anchor signs but does NOT broadcast.
  /// The response contains the signed transaction (serializedTransaction + signatures).
  /// Flutter then adds thezeosalias signature and broadcasts itself.
  ///
  /// With flags=1 (legacy/broken), Anchor would try to broadcast directly,
  /// but anchor-link rejects the cosig info pair format.
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
          print('[EsrDisplayDialog] Anchor responded, processing...');
          print('[EsrDisplayDialog] Response keys: ${response.keys.toList()}');

          String? txId;

          // Primary flow: flags=0 - Anchor returns signed transaction for us to broadcast
          // Check for serializedTransaction or signatures (the flags=0 response format)
          if (response.containsKey('serializedTransaction') ||
              response.containsKey('packed_trx') ||
              response.containsKey('signatures')) {
            print('[EsrDisplayDialog] Flags=0 response - adding thezeosalias signature and broadcasting...');
            setState(() {
              _statusMessage = 'Adding protocol signature and broadcasting...';
            });
            txId = await EsrService.addSignatureAndBroadcast(response);
            print('[EsrDisplayDialog] Broadcast complete! TX: $txId');
          } else if (response.containsKey('transaction_id')) {
            // Fallback: Anchor already broadcast (shouldn't happen with flags=0, but handle it)
            txId = response['transaction_id']?.toString();
            print('[EsrDisplayDialog] Anchor already broadcast! TX: $txId');
          } else if (response.containsKey('processed')) {
            // Some Anchor versions return processed.id
            final processed = response['processed'];
            if (processed is Map) {
              txId = processed['id']?.toString();
            }
            print('[EsrDisplayDialog] Transaction processed! TX: $txId');
          } else if (response.containsKey('transaction')) {
            // Anchor may wrap the signed tx in a 'transaction' key
            print('[EsrDisplayDialog] Found transaction key, adding signature and broadcasting...');
            setState(() {
              _statusMessage = 'Adding protocol signature and broadcasting...';
            });
            txId = await EsrService.addSignatureAndBroadcast(response);
            print('[EsrDisplayDialog] Broadcast complete! TX: $txId');
          } else {
            // Check for error indicators in the response
            final errorMsg = response['error']?.toString() ??
                             response['message']?.toString();
            if (errorMsg != null) {
              throw Exception('Anchor returned error: $errorMsg');
            }

            // Check for rejection/cancellation
            final status = response['status']?.toString();
            if (status == 'rejected' || status == 'cancelled' || status == 'expired') {
              throw Exception('Transaction was $status by user');
            }

            // Try to extract any transaction ID we can find
            txId = response['txid']?.toString() ??
                   response['trx_id']?.toString() ??
                   response['id']?.toString();
            if (txId == null) {
              // No transaction ID and no known success format
              // Try broadcasting with whatever we have, but do NOT silently assume success on failure
              print('[EsrDisplayDialog] Unknown response format, attempting broadcast...');
              print('[EsrDisplayDialog] Full response: $response');
              txId = await EsrService.addSignatureAndBroadcast(response);
            }
          }

          final result = {'transaction_id': txId};
          print('[EsrDisplayDialog] Transaction complete! ID: $txId');

          if (mounted) {
            setState(() {
              _statusMessage = 'Transaction broadcast!';
            });
          }

          // Show success and close dialog after a short delay
          showSnackBar('Transaction broadcast successfully!');
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            Navigator.of(context).pop(result);
          }
        } catch (e) {
          print('[EsrDisplayDialog] Error processing response: $e');
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
      return AnchorLinkClient.generateQrData(widget.esrUrl, _anchorLink!.channelId ?? '');
    }
    return widget.esrUrl;
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.esrUrl));
    setState(() => _copied = true);
    showSnackBar('ESR URL copied to clipboard');

    // Reset copied state after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _openInBrowser() async {
    // Open via eosio.to web resolver
    final webUrl = Uri.parse('https://eosio.to/${widget.esrUrl}');
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
      print('[EsrDisplayDialog] Launching Anchor Desktop...');
      final launched = await EsrService.launchAnchor(widget.esrUrl);
      if (launched) {
        showSnackBar('Anchor opened! Review and sign the transaction.');
      } else {
        showSnackBar('Could not launch Anchor. Try copying the link instead.');
      }
    } catch (e) {
      if (mounted) {
        showSnackBar('Error launching Anchor: $e');
      }
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
                  if (_linkStatus != AnchorLinkStatus.disconnected) ...[
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

                  // Action buttons
                  // Copy to Clipboard button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: _copyToClipboard,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _copied ? Colors.green : t.colorScheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                      label: Text(_copied ? 'Copied!' : 'Copy ESR Link'),
                    ),
                  ),
                  const Gap(10),

                  // Launch Anchor Desktop button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: _launchAnchorDesktop,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[700],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.launch, size: 18),
                      label: const Text('Launch Anchor Desktop'),
                    ),
                  ),
                  const Gap(10),

                  // Open in Browser button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: _openInBrowser,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.colorScheme.onSurface,
                        side: BorderSide(color: t.colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('Open in Browser'),
                    ),
                  ),
                  const Gap(16),

                  // Mark Complete button - for when Anchor broadcasts directly
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Did Anchor show "Transaction Broadcast"?',
                          style: t.textTheme.bodySmall?.copyWith(
                            color: Colors.green[700],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Gap(8),
                        SizedBox(
                          width: double.infinity,
                          height: 40,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop({'status': 'completed_manually'});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green[700],
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: const Icon(Icons.check_circle, size: 18),
                            label: const Text('Yes, Transaction Complete!'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Gap(12),

                  // Manual signature entry for desktop Anchor users (fallback)
                  if (!_showManualEntry) ...[
                    TextButton.icon(
                      onPressed: () => setState(() => _showManualEntry = true),
                      icon: Icon(Icons.keyboard, color: Colors.orange[700], size: 16),
                      label: Text(
                        'Advanced: Paste signature manually',
                        style: t.textTheme.bodySmall?.copyWith(
                          color: Colors.orange[700],
                        ),
                      ),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.edit, color: Colors.orange[700], size: 16),
                              const Gap(8),
                              Text(
                                'Paste Raw Signature from Anchor:',
                                style: t.textTheme.bodySmall?.copyWith(
                                  color: Colors.orange[700],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const Gap(8),
                          TextField(
                            controller: _signatureController,
                            maxLines: 2,
                            style: t.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              hintText: 'SIG_K1_...',
                              hintStyle: TextStyle(color: Colors.grey[500]),
                              filled: true,
                              fillColor: Colors.black.withOpacity(0.2),
                              contentPadding: const EdgeInsets.all(10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const Gap(10),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: ElevatedButton(
                              onPressed: _isProcessing ? null : _processManualSignature,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange[700],
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: _isProcessing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Sign & Broadcast'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Gap(12),

                  // Instructions
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.blue[700], size: 16),
                            const Gap(8),
                            Text(
                              'How to use in Anchor:',
                              style: t.textTheme.bodySmall?.copyWith(
                                color: Colors.blue[700],
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const Gap(8),
                        Text(
                          '1. Open Anchor wallet and unlock it\n'
                          '2. Go to Tools → URI Handler\n'
                          '3. Paste the copied ESR link\n'
                          '4. Copy the "Raw Signature" shown\n'
                          '5. Paste it above and click Sign & Broadcast',
                          style: t.textTheme.bodySmall?.copyWith(
                            color: Colors.blue[700],
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
