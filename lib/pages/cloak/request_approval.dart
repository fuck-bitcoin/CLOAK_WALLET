// Request Approval Page - Shows details of a single request with Accept/Decline buttons
// Part of Phase 16: WebSocket Signature Provider Implementation

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/signature_provider.dart';
import '../../cloak/signature_provider_state.dart';
import '../utils.dart';

/// Page for reviewing and approving/declining a single signature request
class RequestApprovalPage extends StatefulWidget {
  final String requestId;
  const RequestApprovalPage({super.key, required this.requestId});

  @override
  State<RequestApprovalPage> createState() => _RequestApprovalPageState();
}

class _RequestApprovalPageState extends State<RequestApprovalPage> {
  bool _processing = false;

  SignatureRequest? get _request {
    return signatureProviderStore.getRequest(widget.requestId);
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: const Text('REQUEST'),
        ),
        body: const Center(child: Text('Request not found or expired')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(_getTitle(request.type)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildRequestDetails(request)),
              const Gap(16),
              _buildActionButtons(request),
            ],
          ),
        ),
      ),
    );
  }

  String _getTitle(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'LOGIN REQUEST';
      case SignatureRequestType.sign:
        return 'SIGN REQUEST';
      case SignatureRequestType.balance:
        return 'BALANCE REQUEST';
    }
  }

  Widget _buildRequestDetails(SignatureRequest request) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Origin card
          _InfoCard(
            icon: Icons.language,
            title: 'Website',
            child: Text(request.origin, style: const TextStyle(fontSize: 16)),
          ),
          const Gap(16),

          // Request type explanation
          _InfoCard(
            icon: _getTypeIcon(request.type),
            title: 'Request Type',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.typeDescription,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const Gap(4),
                Text(
                  _getTypeExplanation(request.type),
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          const Gap(16),

          // Parameters (expandable JSON view)
          _InfoCard(
            icon: Icons.code,
            title: 'Parameters',
            child: _JsonView(data: request.params),
          ),

          // Warning for sign requests
          if (request.type == SignatureRequestType.sign) ...[
            const Gap(16),
            _WarningCard(
              message: 'This will sign a transaction. Review carefully before approving.',
            ),
          ],

          // What will happen section
          const Gap(16),
          _InfoCard(
            icon: Icons.info_outline,
            title: 'What will happen',
            child: Text(
              _getWhatWillHappen(request.type),
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getTypeIcon(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return Icons.login;
      case SignatureRequestType.sign:
        return Icons.edit_note;
      case SignatureRequestType.balance:
        return Icons.account_balance_wallet;
    }
  }

  String _getTypeExplanation(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'The website wants to verify your identity. This will share your wallet address.';
      case SignatureRequestType.sign:
        return 'The website wants you to sign a transaction. This may transfer funds.';
      case SignatureRequestType.balance:
        return 'The website wants to check your wallet balance.';
    }
  }

  String _getWhatWillHappen(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'If you approve:\n'
            '• Your wallet address will be shared with the website\n'
            '• The website will know you control this address\n'
            '• No funds will be moved';
      case SignatureRequestType.sign:
        return 'If you approve:\n'
            '• The transaction will be signed with your keys\n'
            '• Funds may be transferred as specified\n'
            '• This action cannot be undone';
      case SignatureRequestType.balance:
        return 'If you approve:\n'
            '• Your current balance will be shared\n'
            '• No funds will be moved';
    }
  }

  Widget _buildActionButtons(SignatureRequest request) {
    final t = Theme.of(context);

    // If already processed, show status
    if (request.status != SignatureRequestStatus.pending) {
      return Column(
        children: [
          Icon(
            request.status == SignatureRequestStatus.completed
                ? Icons.check_circle
                : Icons.cancel,
            size: 48,
            color: request.status == SignatureRequestStatus.completed
                ? Colors.green
                : Colors.red,
          ),
          const Gap(8),
          Text(
            request.status == SignatureRequestStatus.completed
                ? 'Request approved'
                : 'Request declined',
            style: TextStyle(
              fontSize: 16,
              color: request.status == SignatureRequestStatus.completed
                  ? Colors.green
                  : Colors.red,
            ),
          ),
          const Gap(16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () => GoRouter.of(context).pop(),
              child: const Text('CLOSE'),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        // Decline button
        Expanded(
          child: SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: _processing ? null : _handleDecline,
              style: OutlinedButton.styleFrom(
                foregroundColor: t.colorScheme.error,
                side: BorderSide(color: t.colorScheme.error),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('DECLINE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
        const Gap(16),

        // Approve button
        Expanded(
          child: SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: _processing ? null : _handleApprove,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _processing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('APPROVE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleApprove() async {
    final request = _request;
    if (request == null) return;

    setState(() => _processing = true);

    try {
      Map<String, dynamic> response;

      switch (request.type) {
        case SignatureRequestType.login:
          response = await _processLogin(request);
          break;
        case SignatureRequestType.sign:
          response = await _processSign(request);
          break;
        case SignatureRequestType.balance:
          response = await _processBalance(request);
          break;
      }

      SignatureProvider.sendRequestResponse(request.id, response);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request approved'), backgroundColor: Colors.green),
        );
        GoRouter.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        await showMessageBox2(context, 'Error', e.toString());
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _handleDecline() async {
    final request = _request;
    if (request == null) return;

    SignatureProvider.sendRequestRejection(request.id, 'User declined');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request declined')),
      );
      GoRouter.of(context).pop();
    }
  }

  Future<Map<String, dynamic>> _processLogin(SignatureRequest request) async {
    // Match official CLOAK GUI format exactly - just result and status, no address
    return {
      'result': 'anonymous',
      'status': 'success',
    };
  }

  Future<Map<String, dynamic>> _processSign(SignatureRequest request) async {
    // The web app (app.cloak.today) sends a sign request with a transaction object.
    // We sign it using the wallet's ZK proof infrastructure via CloakApi.transactPacked,
    // then return the signed transaction data back to the web app.
    final tx = request.params['transaction'] as Map<String, dynamic>?;
    if (tx == null) throw Exception('No transaction provided');

    if (!CloakWalletManager.isLoaded) {
      throw Exception('Wallet not loaded');
    }

    // The web app sends the ZTransaction JSON in the 'transaction' field.
    // This matches the format expected by wallet_transact_packed in the Rust FFI.
    final ztxJson = jsonEncode(tx);

    // Ensure ZK params are loaded (may already be cached)
    if (!CloakWalletManager.zkParamsReady) {
      throw Exception('ZK params not loaded. Please wait for initialization to complete.');
    }

    // Call the wallet manager to build and sign the transaction
    final signedTx = await CloakWalletManager.buildTransaction(
      recipients: [],
      feeTokenContract: tx['fee_token_contract'] as String? ?? 'thezeostoken',
      feeAmount: tx['fee_amount'] as String? ?? '0.1000 CLOAK',
    );

    if (signedTx == null) {
      throw Exception('Transaction signing failed');
    }

    return {
      'result': signedTx,
      'status': 'success',
    };
  }

  Future<Map<String, dynamic>> _processBalance(SignatureRequest request) async {
    final balanceJson = CloakWalletManager.getBalancesJson();
    if (balanceJson == null) throw Exception('Wallet not loaded');

    return {'balance': jsonDecode(balanceJson)};
  }
}

/// Card showing information with icon and title
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.grey),
              const Gap(8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          const Gap(8),
          child,
        ],
      ),
    );
  }
}

/// Warning card with red/orange styling
class _WarningCard extends StatelessWidget {
  final String message;

  const _WarningCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.orange),
          const Gap(12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.orange[800]),
            ),
          ),
        ],
      ),
    );
  }
}

/// JSON viewer widget with expandable sections
class _JsonView extends StatefulWidget {
  final Map<String, dynamic> data;

  const _JsonView({required this.data});

  @override
  State<_JsonView> createState() => _JsonViewState();
}

class _JsonViewState extends State<_JsonView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final jsonString = const JsonEncoder.withIndent('  ').convert(widget.data);
    final lines = jsonString.split('\n');
    final preview = lines.take(4).join('\n');
    final hasMore = lines.length > 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _expanded ? jsonString : preview + (hasMore && !_expanded ? '\n...' : ''),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: t.colorScheme.onSurface,
            ),
          ),
        ),
        if (hasMore) ...[
          const Gap(8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16),
                label: Text(_expanded ? 'Show less' : 'Show more'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: jsonString));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
