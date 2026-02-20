// Pending Requests Page - Shows list of pending signature requests from websites
// Part of Phase 16: WebSocket Signature Provider Implementation

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../cloak/signature_provider.dart';
import '../../cloak/signature_provider_state.dart';

/// Page showing all pending (and recent) signature requests
class PendingRequestsPage extends StatelessWidget {
  const PendingRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('REQUESTS'),
        centerTitle: true,
        actions: [
          // Server status indicator
          Observer(builder: (context) {
            final running = signatureProviderStore.serverRunning;
            return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Tooltip(
                message: running
                    ? 'Server running on port ${signatureProviderStore.serverPort}'
                    : 'Server not running',
                child: Icon(
                  running ? Icons.wifi : Icons.wifi_off,
                  color: running ? Colors.green : Colors.red,
                ),
              ),
            );
          }),
        ],
      ),
      body: SafeArea(
        child: Observer(builder: (context) {
          final requests = signatureProviderStore.requests;

          if (requests.isEmpty) {
            return _buildEmptyState(context);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            itemBuilder: (context, index) => _RequestCard(request: requests[index]),
          );
        }),
      ),
      floatingActionButton: Observer(builder: (context) {
        final hasCompleted = signatureProviderStore.requests.any((r) =>
          r.status == SignatureRequestStatus.completed ||
          r.status == SignatureRequestStatus.rejected);

        if (!hasCompleted) return const SizedBox.shrink();

        return FloatingActionButton.extended(
          onPressed: () => signatureProviderStore.clearCompleted(),
          icon: const Icon(Icons.clear_all),
          label: const Text('Clear History'),
        );
      }),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.verified_user_outlined, size: 64, color: Colors.grey),
          const Gap(16),
          Text('No pending requests', style: Theme.of(context).textTheme.titleMedium),
          const Gap(8),
          Text(
            'When websites request authentication,\nthey will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const Gap(24),
          Observer(builder: (context) {
            final running = signatureProviderStore.serverRunning;
            return Column(
              children: [
                Icon(
                  running ? Icons.check_circle : Icons.error,
                  color: running ? Colors.green : Colors.orange,
                  size: 20,
                ),
                const Gap(4),
                Text(
                  running
                      ? 'Listening on port ${signatureProviderStore.serverPort}'
                      : 'Server not running',
                  style: TextStyle(
                    color: running ? Colors.green : Colors.orange,
                    fontSize: 12,
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

/// Card widget for displaying a single request
class _RequestCard extends StatelessWidget {
  final SignatureRequest request;
  const _RequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isPending = request.status == SignatureRequestStatus.pending;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: isPending ? () => _openDetails(context) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: type badge + time
              Row(
                children: [
                  _TypeBadge(type: request.type),
                  const Spacer(),
                  Text(
                    _formatTime(request.timestamp),
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
              const Gap(12),

              // Origin
              Text(
                request.origin,
                style: t.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Gap(4),

              // Status
              _StatusIndicator(status: request.status),

              // Actions for pending
              if (isPending) ...[
                const Gap(12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => _reject(context),
                      style: TextButton.styleFrom(
                        foregroundColor: t.colorScheme.error,
                      ),
                      child: const Text('DECLINE'),
                    ),
                    const Gap(8),
                    ElevatedButton(
                      onPressed: () => _openDetails(context),
                      child: const Text('REVIEW'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openDetails(BuildContext context) {
    GoRouter.of(context).push('/cloak_requests/${Uri.encodeComponent(request.id)}');
  }

  void _reject(BuildContext context) {
    SignatureProvider.sendRequestRejection(request.id, 'User declined');
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Badge showing the type of request
class _TypeBadge extends StatelessWidget {
  final SignatureRequestType type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    String label;

    switch (type) {
      case SignatureRequestType.login:
        color = Colors.blue;
        icon = Icons.login;
        label = 'LOGIN';
        break;
      case SignatureRequestType.sign:
        color = Colors.orange;
        icon = Icons.edit_note;
        label = 'SIGN';
        break;
      case SignatureRequestType.balance:
        color = Colors.green;
        icon = Icons.account_balance_wallet;
        label = 'BALANCE';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const Gap(4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Status indicator for a request
class _StatusIndicator extends StatelessWidget {
  final SignatureRequestStatus status;
  const _StatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    String label;

    switch (status) {
      case SignatureRequestStatus.pending:
        color = Colors.orange;
        icon = Icons.pending;
        label = 'Pending approval';
        break;
      case SignatureRequestStatus.approved:
        color = Colors.blue;
        icon = Icons.hourglass_bottom;
        label = 'Processing...';
        break;
      case SignatureRequestStatus.completed:
        color = Colors.green;
        icon = Icons.check_circle;
        label = 'Approved';
        break;
      case SignatureRequestStatus.rejected:
        color = Colors.red;
        icon = Icons.cancel;
        label = 'Declined';
        break;
      case SignatureRequestStatus.error:
        color = Colors.red;
        icon = Icons.error;
        label = 'Error';
        break;
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const Gap(4),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ],
    );
  }
}
