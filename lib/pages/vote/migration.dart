import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';

/// Checks if migration to Orchard is needed for voting.
bool needsOrchardMigration() {
  final pools = aa.poolBalances;
  return pools.transparent > 0 || pools.sapling > 0;
}

/// Returns true if user has any funds at all
bool hasAnyFunds() {
  final pools = aa.poolBalances;
  return pools.transparent > 0 || pools.sapling > 0 || pools.orchard > 0;
}

/// Get total balance across all pools
int getTotalBalance() {
  final pools = aa.poolBalances;
  return pools.transparent + pools.sapling + pools.orchard;
}

/// Shows the migration modal if needed.
Future<bool> showMigrationModalIfNeeded(BuildContext context) async {
  if (!needsOrchardMigration() && migrationState.state != MigrationState.migrating) return false;

  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) => OrchardMigrationModal(),
  );
  return true;
}

/// Modal is now a pure observer of global migrationState
class OrchardMigrationModal extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    
    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
    );

    return Observer(builder: (context) {
    // Observe all relevant state
    aaSequence.seqno;
    syncStatus2.changed;
    
    // Get migration state from global store
    final migState = migrationState.state;
    final migStatus = migrationState.statusMessage;
    final transparentState = migrationState.transparentState;
    final saplingState = migrationState.saplingState;
    final migError = migrationState.error;
    
    // Get pool balances
    final transparent = aa.poolBalances.transparent;
    final sapling = aa.poolBalances.sapling;
    final orchard = aa.poolBalances.orchard;
    final total = transparent + sapling + orchard;
    final needsMigration = transparent + sapling;
    
    // Determine UI state - trust migration state OR check balances
    final isMigrating = migState == MigrationState.migrating;
    // Show completed if: state says ready OR balances show all in orchard
    final isCompleted = migState == MigrationState.ready || (needsMigration == 0 && orchard > 0);

    final radius = BorderRadius.circular(14);
    
    Widget primaryButton({required String label, required VoidCallback? onTap, bool showSpinner = false}) {
      return SizedBox(
        width: double.infinity,
        height: 48,
        child: Material(
          color: onTap != null ? balanceTextColor : balanceTextColor.withOpacity(0.5),
          shape: RoundedRectangleBorder(borderRadius: radius),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSpinner) ...[
                    SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: t.colorScheme.background,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.background,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget secondaryButton({required String label, required VoidCallback? onTap}) {
      return SizedBox(
        width: double.infinity,
        height: 40,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: balanceTextColor.withOpacity(0.3)),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Center(
              child: Text(
                label,
                style: bodyStyle.copyWith(fontWeight: FontWeight.w400),
              ),
            ),
          ),
        ),
      );
    }

    // Determine title based on state
    final String title;
    if (isCompleted) {
      title = 'Migration Complete';
    } else if (isMigrating) {
      title = 'Migrating...';
    } else {
      title = 'Migrate for Voting';
    }

    return AlertDialog(
      title: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(title, key: ValueKey(title), style: titleStyle),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isCompleted) ...[
            // Completion screen
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your funds are now in Orchard and ready for voting!',
                    style: bodyStyle,
                  ),
                ),
              ],
            ),
            const Gap(20),
            primaryButton(
              label: 'Done',
              onTap: () => Navigator.of(context).pop(),
            ),
          ] else if (isMigrating) ...[
            // Migration in progress screen
            Text(
              'Your funds are being migrated to Orchard. You can close this dialog, but please keep the app open.',
              style: bodyStyle,
            ),
            const Gap(16),
            
            // Pool breakdown - uses global state
            _PoolRow(label: 'Transparent', amount: transparent, state: transparentState, style: bodyStyle),
            const Gap(4),
            _PoolRow(label: 'Sapling', amount: sapling, state: saplingState, style: bodyStyle),
            const Gap(4),
            _PoolRow(label: 'Orchard', amount: orchard, state: PoolMigrationState.pending, isOrchard: true, style: bodyStyle),
            Divider(color: balanceTextColor.withOpacity(0.2), height: 16),
            _PoolRow(label: 'Total', amount: total, state: PoolMigrationState.pending, isBold: true, style: bodyStyle),
            
            const Gap(16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                backgroundColor: const Color(0xFFA1740D).withOpacity(0.3),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFC99111)),
              ),
            ),
            const Gap(8),
            Text(migStatus, style: bodyStyle.copyWith(fontSize: 12)),

            if (migError != null) ...[
              const Gap(12),
              Text(migError, style: bodyStyle.copyWith(color: Colors.red)),
            ],

            const Gap(16),
            secondaryButton(
              label: 'Close (migration continues)',
              onTap: () => Navigator.of(context).pop(),
            ),
          ] else ...[
            // Initial screen - prompt to migrate
            Text(
              'To participate in Zcash voting, all your funds must be in the Orchard pool.',
              style: bodyStyle,
            ),
            const Gap(16),
            
            // Pool breakdown
            _PoolRow(label: 'Transparent', amount: transparent, state: transparentState, style: bodyStyle),
            const Gap(4),
            _PoolRow(label: 'Sapling', amount: sapling, state: saplingState, style: bodyStyle),
            const Gap(4),
            _PoolRow(label: 'Orchard', amount: orchard, state: PoolMigrationState.pending, isOrchard: true, style: bodyStyle),
            Divider(color: balanceTextColor.withOpacity(0.2), height: 16),
            _PoolRow(label: 'Total', amount: total, state: PoolMigrationState.pending, isBold: true, style: bodyStyle),
            
            const Gap(16),
            Text(
              'This sends your funds to yourself, moving them to Orchard. Your seed phrase stays the same.',
              style: bodyStyle.copyWith(fontSize: 12, color: balanceTextColor.withOpacity(0.7)),
            ),

            if (migError != null) ...[
              const Gap(12),
              Text(migError, style: bodyStyle.copyWith(color: Colors.red)),
            ],

            const Gap(16),
            secondaryButton(label: 'Later', onTap: () => Navigator.of(context).pop()),
            const Gap(10),
            primaryButton(
              label: 'Migrate ${decimalToStringTrim(needsMigration / ZECUNIT)} ZEC',
              onTap: () => migrationState.startMigration(),
            ),
          ],
        ],
      ),
      actions: const [],
    );
    }); // End Observer
  }
}

class _PoolRow extends StatelessWidget {
  final String label;
  final int amount;
  final PoolMigrationState state;
  final bool isOrchard;
  final bool isBold;
  final TextStyle style;

  const _PoolRow({
    required this.label,
    required this.amount,
    required this.state,
    required this.style,
    this.isOrchard = false,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    final amountZec = amount / ZECUNIT;
    final amountStr = decimalToStringTrim(amountZec);

    // Determine badge to show
    Widget? badge;
    if (isBold) {
      // Total row - no badge
      badge = null;
    } else if (isOrchard) {
      // Orchard pool - show READY if has funds
      if (amount > 0) {
        badge = _badge('READY', Colors.green);
      }
    } else if (state == PoolMigrationState.migrating) {
      badge = _migratingBadge();
    } else if (state == PoolMigrationState.migrated) {
      badge = _badge('MIGRATED', Colors.green);
    } else if (amount > 0) {
      badge = _badge('MIGRATE', Colors.orange);
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: style.copyWith(fontWeight: isBold ? FontWeight.w600 : FontWeight.normal),
          ),
        ),
        if (badge != null) ...[
          badge,
          const SizedBox(width: 6),
        ],
        Text(
          '$amountStr ZEC',
          style: style.copyWith(
            fontWeight: isBold ? FontWeight.w600 : FontWeight.normal,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: style.copyWith(fontSize: 8, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _migratingBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8, height: 8,
            child: CircularProgressIndicator(strokeWidth: 1, color: Colors.blue),
          ),
          const SizedBox(width: 4),
          Text('MIGRATING', style: style.copyWith(fontSize: 8, color: Colors.blue, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
