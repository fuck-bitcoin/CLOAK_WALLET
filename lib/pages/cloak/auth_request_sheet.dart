// Auth Request Bottom Sheet - Slide-up sheet for quick approve/decline
// Part of Phase 16: WebSocket Signature Provider Implementation
// Design matches the "Wallets & Hardware" panel in router.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/signature_provider.dart';
import '../../cloak/signature_provider_state.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';

/// Shows the auth request sheet using showGeneralDialog with slide animation
/// Matches the "Wallets & Hardware" panel design but slides from bottom
Future<void> showAuthRequestSheet(BuildContext context, SignatureRequest request) {
  final ThemeData t = Theme.of(context);

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Auth Request',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 450),
    pageBuilder: (dialogCtx, anim, secAnim) {
      return _AuthRequestPanel(
        theme: t,
        request: request,
        parentContext: context,
      );
    },
    transitionBuilder: (ctx, anim, secAnim, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeInOutCubic,
        reverseCurve: Curves.easeInOutCubic,
      );
      // Slide from bottom (1.0) to center (0.0)
      final slide = Tween<Offset>(
        begin: const Offset(0, 1.0),
        end: Offset.zero,
      ).animate(curved);
      final fade = CurvedAnimation(
        parent: anim,
        curve: const Interval(0.15, 1.0, curve: Curves.easeInOutCubic),
      );
      return SlideTransition(
        position: slide,
        child: FadeTransition(opacity: fade, child: child),
      );
    },
  );
}

/// Panel widget that matches the "Wallets & Hardware" design
class _AuthRequestPanel extends StatefulWidget {
  final ThemeData theme;
  final SignatureRequest request;
  final BuildContext parentContext;

  const _AuthRequestPanel({
    required this.theme,
    required this.request,
    required this.parentContext,
  });

  @override
  State<_AuthRequestPanel> createState() => _AuthRequestPanelState();
}

class _AuthRequestPanelState extends State<_AuthRequestPanel>
    with SingleTickerProviderStateMixin {
  bool _processing = false;
  bool _expanded = false;
  double _dragOffset = 0.0;
  AnimationController? _controller;
  Animation<double>? _bounce;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _animateBack() {
    if (_controller == null) return;
    _bounce = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _controller!, curve: Curves.easeOutCubic),
    );
    _controller!
      ..reset()
      ..addListener(() {
        setState(() => _dragOffset = _bounce!.value);
      })
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    // Panel takes 55% of screen height when collapsed, 85% when expanded
    final screenHeight = MediaQuery.of(context).size.height;
    final panelHeight = _expanded ? screenHeight * 0.85 : screenHeight * 0.55;

    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w400,
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _dragOffset += details.delta.dy;
            // Only allow dragging down (positive offset)
            if (_dragOffset < 0) _dragOffset = 0;
          });
        },
        onVerticalDragEnd: (details) {
          // If dragged down more than 100px, dismiss
          if (_dragOffset > 100) {
            Navigator.of(context).pop();
          } else {
            _animateBack();
          }
        },
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: Material(
            color: Colors.transparent,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              width: double.infinity,
              height: panelHeight,
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: balanceTextColor.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Header section - matches "Wallets & Hardware" style
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _getTitle(widget.request.type),
                            style: titleStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: _expanded ? 'Show less' : 'Show more',
                          onPressed: () => setState(() => _expanded = !_expanded),
                          icon: AnimatedRotation(
                            turns: _expanded ? 0.5 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            child: Icon(
                              Icons.expand_less,
                              color: balanceTextColor,
                              size: (titleStyle.fontSize ?? 20.0) * 1.0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Content + action buttons in same scroll
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        16, 0, 16,
                        16 + MediaQuery.of(context).padding.bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Type badge
                          _TypeBadge(type: widget.request.type),
                          const Gap(16),

                          // Origin (website)
                          _buildOriginRow(balanceTextColor, balanceFontFamily),
                          const Gap(8),

                          // Brief description
                          Text(
                            _getShortDescription(widget.request.type),
                            style: TextStyle(
                              color: balanceTextColor.withOpacity(0.7),
                              fontSize: 13,
                            ),
                          ),

                          // Expanded details
                          if (_expanded) ...[
                            const Gap(16),
                            Divider(color: balanceTextColor.withOpacity(0.2)),
                            const Gap(8),
                            _buildExpandedDetails(balanceTextColor),
                          ],

                          // Action buttons — in content flow
                          const Gap(32),
                          _buildActionButtons(t, balanceTextColor),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOriginRow(Color textColor, String? fontFamily) {
    return Row(
      children: [
        Icon(Icons.language, size: 18, color: textColor.withOpacity(0.7)),
        const Gap(8),
        Expanded(
          child: Text(
            widget.request.origin,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: textColor,
              fontFamily: fontFamily,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildExpandedDetails(Color textColor) {
    final t = widget.theme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What will happen
        Text(
          'What will happen',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: textColor.withOpacity(0.6),
          ),
        ),
        const Gap(8),
        Text(
          _getWhatWillHappen(widget.request.type),
          style: TextStyle(fontSize: 13, color: textColor.withOpacity(0.8)),
        ),

        // Warning for sign requests
        if (widget.request.type == SignatureRequestType.sign) ...[
          const Gap(12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                const Gap(8),
                Expanded(
                  child: Text(
                    'Review transaction carefully before approving',
                    style: TextStyle(color: Colors.orange[300], fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],

        const Gap(12),

        // Parameters preview
        Text(
          'Parameters',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: textColor.withOpacity(0.6),
          ),
        ),
        const Gap(8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _formatParams(widget.request.params),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: textColor.withOpacity(0.8),
            ),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        const Gap(8),

        // View full details link
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              Navigator.pop(context);
              GoRouter.of(widget.parentContext).push(
                '/cloak_requests/${Uri.encodeComponent(widget.request.id)}',
              );
            },
            child: const Text('View Full Details'),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(ThemeData t, Color textColor) {
    // If already processed, show status
    if (widget.request.status != SignatureRequestStatus.pending) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            widget.request.status == SignatureRequestStatus.completed
                ? Icons.check_circle
                : Icons.cancel,
            color: widget.request.status == SignatureRequestStatus.completed
                ? Colors.green
                : Colors.red,
          ),
          const Gap(8),
          Text(
            widget.request.status == SignatureRequestStatus.completed
                ? 'Approved'
                : 'Declined',
            style: TextStyle(
              color: widget.request.status == SignatureRequestStatus.completed
                  ? Colors.green
                  : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    const cardColor = Color(0xFF2E2C2C);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    return Column(
      children: [
        // Approve button — green fill, icon + label + chevron
        SizedBox(
          width: double.infinity,
          child: Material(
            color: Colors.green,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _processing ? null : _handleApprove,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Row(
                  children: [
                    _processing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline, size: 20, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Approve',
                        style: t.textTheme.titleSmall?.copyWith(
                          fontFamily: balanceFontFamily,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 20, color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Gap(8),
        // Decline button — dark card, red text
        SizedBox(
          width: double.infinity,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _processing ? null : _handleDecline,
              child: Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.close, size: 20, color: Colors.red[400]),
                    const SizedBox(width: 10),
                    Text(
                      'Decline',
                      style: t.textTheme.titleSmall?.copyWith(
                        fontFamily: balanceFontFamily,
                        fontWeight: FontWeight.w600,
                        color: Colors.red[400],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _getTitle(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'Login Request';
      case SignatureRequestType.sign:
        return 'Sign Request';
      case SignatureRequestType.balance:
        return 'Balance Request';
    }
  }

  String _getShortDescription(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'wants to verify your identity';
      case SignatureRequestType.sign:
        return 'wants you to sign a transaction';
      case SignatureRequestType.balance:
        return 'wants to check your balance';
    }
  }

  String _getWhatWillHappen(SignatureRequestType type) {
    switch (type) {
      case SignatureRequestType.login:
        return 'Your wallet address will be shared with the website. No funds will be moved.';
      case SignatureRequestType.sign:
        return 'The transaction will be signed and may transfer funds. This cannot be undone.';
      case SignatureRequestType.balance:
        return 'Your current balance will be shared. No funds will be moved.';
    }
  }

  String _formatParams(Map<String, dynamic> params) {
    // Show only key fields for compact view
    final buffer = StringBuffer();
    final keys = ['id', 'label', 'chain_id', 'protocol_contract'];
    for (final key in keys) {
      if (params.containsKey(key)) {
        final value = params[key];
        if (value is String && value.length > 40) {
          buffer.writeln('$key: ${value.substring(0, 40)}...');
        } else {
          buffer.writeln('$key: $value');
        }
      }
    }
    if (buffer.isEmpty) {
      return const JsonEncoder.withIndent('  ').convert(params);
    }
    return buffer.toString().trim();
  }

  Future<void> _handleApprove() async {
    setState(() => _processing = true);

    try {
      Map<String, dynamic> response;

      switch (widget.request.type) {
        case SignatureRequestType.login:
          response = await _processLogin();
          break;
        case SignatureRequestType.sign:
          response = await _processSign();
          break;
        case SignatureRequestType.balance:
          response = await _processBalance();
          break;
      }

      SignatureProvider.sendRequestResponse(widget.request.id, response);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(widget.parentContext).showSnackBar(
          const SnackBar(
            content: Text('Request approved'),
            backgroundColor: Colors.green,
          ),
        );
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
    SignatureProvider.sendRequestRejection(widget.request.id, 'User declined');

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(widget.parentContext).showSnackBar(
        const SnackBar(content: Text('Request declined')),
      );
    }
  }

  Future<Map<String, dynamic>> _processLogin() async {
    // app.cloak.today expects {status: "success", result: "<actor_name>"}
    // Since this is a shielded ZK wallet, we use "anonymous" as the actor.
    // The web app stores this as the actor name for display purposes only.
    return {
      'status': 'success',
      'result': 'anonymous',
    };
  }

  Future<Map<String, dynamic>> _processSign() async {
    // Check if this is a transact request from app.cloak.today
    final pendingParams = SignatureProvider.getPendingTransact(widget.request.id);
    if (pendingParams != null) {
      return await SignatureProvider.executeTransact(pendingParams);
    }
    throw UnimplementedError('Transaction signing not yet implemented for this request type');
  }

  Future<Map<String, dynamic>> _processBalance() async {
    final balanceJson = CloakWalletManager.getBalancesJson();
    if (balanceJson == null) throw Exception('Wallet not loaded');
    return {'balance': jsonDecode(balanceJson)};
  }
}

/// Badge showing the type of request - matches wallet design language
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const Gap(6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
