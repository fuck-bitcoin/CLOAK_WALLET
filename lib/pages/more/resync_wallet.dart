import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../cloak/cloak_sync.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../generated/intl/messages.dart';
import '../../router.dart' show router;
import '../../store2.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';
import '../widgets.dart';

class ResyncWalletPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _ResyncWalletState();
}

class _ResyncWalletState extends State<ResyncWalletPage> with WithLoadingAnimation {
  late final s = S.of(context);

  @override
  Widget build(BuildContext context) {
    print('[ResyncWalletPage] build() called');
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final titleStyle = (t.textTheme.titleMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w500,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor.withOpacity(0.8),
      fontFamily: balanceFontFamily,
    );
    final radius = BorderRadius.circular(14);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text('Resync Wallet'),
        actions: [
          IconButton(onPressed: _resync, icon: Icon(Icons.check)),
        ],
      ),
      body: wrapWithLoading(
        SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reset and resync wallet', style: titleStyle),
                Gap(8),
                Text(
                  'This will clear all transaction history and balances from your wallet, then resync everything from the blockchain.',
                  style: bodyStyle,
                ),
                Gap(24),

                // Warning box
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: radius,
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
                      Gap(12),
                      Expanded(
                        child: Text(
                          'Your keys and unpublished notes will be preserved, but all synced data will be deleted.',
                          style: bodyStyle.copyWith(color: Colors.red.shade300),
                        ),
                      ),
                    ],
                  ),
                ),
                Gap(16),

                // Info box
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: radius,
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue, size: 24),
                      Gap(12),
                      Expanded(
                        child: Text(
                          'Use this if your wallet data is corrupted or transactions are missing. The full resync may take several minutes.',
                          style: bodyStyle.copyWith(color: Colors.blue.shade300),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _resync() async {
    final confirmed = await showConfirmDialog(
      context,
      'Resync Wallet',
      'Are you sure? All transaction history and balances will be cleared and resynced from the blockchain.',
    );
    if (!confirmed) return;

    load(() async {
      // 1. Reset chain state
      final success = await CloakWalletManager.resetChainState();
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reset wallet state'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // 2. Reset sync status so banner knows we're not synced
      syncStatus2.syncedHeight = 0;
      syncStatus2.isRescan = true;

      // 3. Navigate to balance page — sync banner will appear
      router.go('/account');

      // 4. Trigger full sync (deferred so balance page renders first)
      Future(() => syncStatus2.sync(true));
    });
  }
}
