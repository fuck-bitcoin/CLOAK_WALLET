import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show FontFeature;
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../accounts.dart';
import '../cloak/cloak_db.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../cloak/cloak_sync.dart' show CloakSync;
import '../cloak/eosio_client.dart' show fetchTransactionDetails, TransactionDetails;
import '../generated/intl/messages.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../store2.dart';
import '../tablelist.dart';
import '../theme/zashi_tokens.dart';
import 'avatar.dart';
import 'utils.dart';
import 'widgets.dart';

// Shared width for the trailing amount column in transaction list items.
// Used by the Balance page header to align the "See all >" pill with numbers.
const double kTxTrailingWidth = 102.0; // 15% narrower to tighten trailing slot and header pill

/// A group of transactions sharing the same date header.
class _TxDateGroup {
  final String header;
  final List<Tx> transactions;
  _TxDateGroup(this.header, this.transactions);
}

/// Groups transactions by date, matching Zashi's Activity page grouping:
/// "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", then "Month Year".
List<_TxDateGroup> _groupTransactionsByDate(List<Tx> txs) {
  if (txs.isEmpty) return [];

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final sevenDaysAgo = today.subtract(const Duration(days: 7));
  final thirtyDaysAgo = today.subtract(const Duration(days: 30));

  final Map<String, List<Tx>> groups = {};
  // Maintain insertion order with a list of keys
  final List<String> orderedKeys = [];

  for (final tx in txs) {
    final txDate = DateTime(tx.timestamp.year, tx.timestamp.month, tx.timestamp.day);
    String key;
    if (txDate == today || txDate.isAfter(today)) {
      key = 'Today';
    } else if (txDate == yesterday || (txDate.isAfter(yesterday) && txDate.isBefore(today))) {
      key = 'Yesterday';
    } else if (txDate.isAfter(sevenDaysAgo) || txDate == sevenDaysAgo) {
      key = 'Previous 7 Days';
    } else if (txDate.isAfter(thirtyDaysAgo) || txDate == thirtyDaysAgo) {
      key = 'Previous 30 Days';
    } else {
      key = DateFormat('MMMM yyyy').format(tx.timestamp);
    }
    if (!groups.containsKey(key)) {
      groups[key] = [];
      orderedKeys.add(key);
    }
    groups[key]!.add(tx);
  }

  return orderedKeys.map((k) => _TxDateGroup(k, groups[k]!)).toList();
}

/// Transaction filter types matching Zashi's Activity filters.
enum TxFilter { sent, received, memos, notes, bookmarked, swap, fees }

class TxPage extends StatefulWidget {
  final bool showAppBar;
  TxPage({this.showAppBar = true});

  @override
  State<StatefulWidget> createState() => TxPageState();
}

class TxPageState extends State<TxPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchTerm = '';
  Set<TxFilter> _activeFilters = {};
  // Filters that actually work vs "coming soon"
  static const _supportedFilters = {TxFilter.sent, TxFilter.received, TxFilter.memos, TxFilter.fees};

  /// Returns true if [tx] is a fee entry (vault operation fee line).
  static bool isFeeEntry(Tx tx) {
    final addr = tx.address ?? '';
    return addr == 'Vault Withdraw' || addr == 'Vault Deposit' || addr == 'Publish Vault' || addr == 'Burn Vault' || addr == 'Send Fee';
  }

  @override
  void initState() {
    super.initState();
    _loadSavedFilters();
    // CLOAK uses table-based sync, no transparent sync needed
  }

  Future<void> _loadSavedFilters() async {
    final saved = await CloakDb.getProperty('tx_filters');
    if (saved != null && saved.isNotEmpty) {
      final names = saved.split(',');
      final restored = <TxFilter>{};
      for (final name in names) {
        try {
          restored.add(TxFilter.values.byName(name));
        } catch (_) {}
      }
      if (restored.isNotEmpty && mounted) {
        setState(() => _activeFilters = restored);
      }
    }
  }

  Future<void> _saveFilters(Set<TxFilter> filters) async {
    if (filters.isEmpty) {
      await CloakDb.setProperty('tx_filters', '');
    } else {
      await CloakDb.setProperty('tx_filters', filters.map((f) => f.name).join(','));
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Tx> _filterTxs(List<Tx> txs) {
    var result = txs;

    // For CLOAK view-only wallets (IVK), hide sent transactions and outgoing operations
    if (CloakWalletManager.isCloak(aa.coin) && CloakWalletManager.isViewOnly) {
      result = result.where((tx) {
        // Hide outgoing transactions (tx.value < 0)
        if (tx.value < 0) return false;
        // Hide fee entries (those are associated with sent/vault operations)
        if (isFeeEntry(tx)) return false;
        return true;
      }).toList();
    }

    // Apply active filters (OR within same type doesn't apply here — each is independent)
    if (_activeFilters.isNotEmpty) {
      result = result.where((tx) {
        for (final f in _activeFilters) {
          switch (f) {
            case TxFilter.sent:
              if (tx.value >= 0) return false;
              break;
            case TxFilter.received:
              if (tx.value < 0) return false;
              break;
            case TxFilter.memos:
              if ((tx.memo ?? '').isEmpty) return false;
              break;
            case TxFilter.fees:
              if (isFeeEntry(tx)) return false;
              break;
            case TxFilter.notes:
            case TxFilter.bookmarked:
            case TxFilter.swap:
              // Not supported yet — these filters don't exclude anything
              break;
          }
        }
        return true;
      }).toList();
    }

    // Apply search term
    if (_searchTerm.length >= 2) {
      final term = _searchTerm.toLowerCase();
      result = result.where((tx) {
        if (tx.contact?.toLowerCase().contains(term) ?? false) return true;
        if (tx.address?.toLowerCase().contains(term) ?? false) return true;
        if (tx.memo?.toLowerCase().contains(term) ?? false) return true;
        if (decimalToString(tx.value).contains(term)) return true;
        return false;
      }).toList();
    }

    return result;
  }

  void _showFilterSheet(BuildContext context) {
    // Copy active filters so user can modify without committing
    Set<TxFilter> pending = Set.of(_activeFilters);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final onSurf = Theme.of(ctx).colorScheme.onSurface;

            Widget filterChip(TxFilter filter, String label) {
              final active = pending.contains(filter);
              final supported = _supportedFilters.contains(filter);
              // View-only wallets can't see sent TXs or fees
              final isViewOnly = CloakWalletManager.isCloak(aa.coin) && CloakWalletManager.isViewOnly;
              final disabledForViewOnly = isViewOnly && (filter == TxFilter.sent || filter == TxFilter.fees);
              final isEnabled = supported && !disabledForViewOnly;

              return GestureDetector(
                onTap: () {
                  if (!isEnabled) {
                    // Show appropriate message
                    final message = disabledForViewOnly
                        ? '$label — not available for view-only wallets'
                        : '$label — coming soon';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(message),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                    return;
                  }
                  setSheetState(() {
                    if (active) {
                      pending.remove(filter);
                    } else {
                      pending.add(filter);
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                  decoration: BoxDecoration(
                    color: active
                        ? onSurf.withOpacity(0.12)
                        : onSurf.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(24),
                    border: active
                        ? Border.all(color: onSurf.withOpacity(0.4), width: 1)
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isEnabled
                              ? onSurf
                              : onSurf.withOpacity(0.4),
                        ),
                      ),
                      if (active) ...[
                        const Gap(4),
                        Icon(Icons.close, size: 16, color: onSurf),
                      ],
                    ],
                  ),
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag indicator
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 20),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: onSurf.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Title
                  Text(
                    'Filter',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: onSurf,
                    ),
                  ),
                  const Gap(24),
                  // Row 1: Sent, Received, Memos, Fees
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      filterChip(TxFilter.sent, 'Sent'),
                      filterChip(TxFilter.received, 'Received'),
                      filterChip(TxFilter.memos, 'Memos'),
                      filterChip(TxFilter.fees, 'Fees'),
                    ],
                  ),
                  const Gap(8),
                  // Row 2: Notes, Bookmarked, Swaps
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      filterChip(TxFilter.notes, 'Notes'),
                      filterChip(TxFilter.bookmarked, 'Bookmarked'),
                      filterChip(TxFilter.swap, 'Swaps'),
                    ],
                  ),
                  const Gap(32),
                  // Reset + Apply buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() => pending.clear());
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: onSurf.withOpacity(0.3)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: Text(
                            'Reset',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: onSurf,
                            ),
                          ),
                        ),
                      ),
                      const Gap(12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            setState(() => _activeFilters = pending);
                            _saveFilters(pending);
                            Navigator.pop(ctx);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: onSurf,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: Text(
                            'Apply',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).scaffoldBackgroundColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showAppBar) {
      // Legacy nested route — wrap in Scaffold with AppBar (fallback for non-CLOAK)
      return SortSetting(
        child: Observer(
          builder: (context) {
            aaSequence.seqno;
            aaSequence.settingsSeqno;
            syncStatus2.changed;
            return Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.maybePop(context),
                ),
                title: Text(S.of(context).history),
                actions: [
                  IconButton(
                    icon: Icon(Icons.close),
                    onPressed: () => GoRouter.of(context).go('/account'),
                  ),
                ],
              ),
              body: _buildBody(context),
            );
          },
        ),
      );
    }

    // Overlay mode: covers whole page including bottom nav, like Contacts
    return SortSetting(
      child: Observer(
        builder: (context) {
          aaSequence.seqno;
          aaSequence.settingsSeqno;
          syncStatus2.changed;

          final theme = Theme.of(context);
          final onSurf = theme.colorScheme.onSurface;
          final TextStyle? baseTitleStyle = theme.appBarTheme.titleTextStyle ??
              theme.textTheme.titleLarge ??
              theme.textTheme.titleMedium ??
              theme.textTheme.bodyMedium;
          final TextStyle? reducedTitleStyle = (baseTitleStyle?.fontSize != null)
              ? baseTitleStyle!.copyWith(fontSize: baseTitleStyle.fontSize! * 0.75)
              : baseTitleStyle;

          return SafeArea(
            child: Material(
              color: theme.scaffoldBackgroundColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header: back arrow, centered "ACTIVITY", no right actions
                  SizedBox(
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Back',
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => GoRouter.of(context).pop(),
                            color: reducedTitleStyle?.color,
                          ),
                        ),
                        Align(
                          alignment: Alignment.center,
                          child: Text(
                            'ACTIVITY',
                            style: reducedTitleStyle,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Search bar + filter button
                  _buildSearchRow(theme, onSurf),
                  // Transaction list
                  Expanded(child: _buildBody(context)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchRow(ThemeData theme, Color onSurf) {
    const Color searchFill = Color(0xFF2E2E2E);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          // Search field — copied from Contacts overlay style
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchTerm = v),
              textInputAction: TextInputAction.search,
              cursorColor: onSurf,
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: Icon(Icons.search, color: onSurf.withOpacity(0.85)),
                suffixIcon: _searchTerm.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close, color: onSurf.withOpacity(0.85)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchTerm = '');
                        },
                      ),
                filled: true,
                fillColor: searchFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
              ),
              style: (theme.textTheme.bodyMedium ?? const TextStyle())
                  .copyWith(color: onSurf),
            ),
          ),
          const Gap(8),
          // Filter button — square, same height as search, stacked-lines icon
          LayoutBuilder(builder: (context, _) {
            const double size = 48.0;
            final hasActive = _activeFilters.isNotEmpty;
            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                children: [
                  Material(
                    color: searchFill,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _showFilterSheet(context),
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: Center(
                          child: CustomPaint(
                            size: const Size(20, 16),
                            painter: _FilterLinesPainter(color: onSurf.withOpacity(0.45)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Glowing dot indicating active filters
                  if (hasActive)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: onSurf,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final onSurf = theme.colorScheme.onSurface;
    final tertiaryTextColor = theme.textTheme.bodySmall?.color ?? onSurf.withOpacity(0.5);
    final sectionHeaderStyle = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: tertiaryTextColor,
    );

    final allTxs = aa.txs.items;
    final txs = _filterTxs(allTxs);
    final groups = _groupTransactionsByDate(txs);
    final hasSearch = _searchTerm.length >= 2;
    final hasFilters = _activeFilters.isNotEmpty;
    final isFiltered = hasSearch || hasFilters;
    final noResults = isFiltered && txs.isEmpty;

    if (allTxs.isEmpty || noResults) {
      return _buildEmptyState(theme, onSurf, tertiaryTextColor, noResults);
    }

    return CustomScrollView(
      slivers: [
        for (int gi = 0; gi < groups.length; gi++) ...[
          // Date section header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Text(groups[gi].header, style: sectionHeaderStyle),
            ),
          ),
          // Transactions in this group
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final groupTxs = groups[gi].transactions;
                final tx = groupTxs[index];
                final globalIndex = allTxs.indexOf(tx);
                ZMessage? message;
                try {
                  message = aa.messages.items.firstWhere((m) => m.txId == tx.id);
                } on StateError {
                  message = null;
                }
                final isLast = index == groupTxs.length - 1;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TxItem(tx, message, index: globalIndex),
                    ),
                    if (!isLast)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Divider(
                          height: 1,
                          thickness: 0.5,
                          color: theme.dividerColor.withOpacity(0.15),
                        ),
                      ),
                    if (isLast && gi < groups.length - 1)
                      const Gap(20),
                  ],
                );
              },
              childCount: groups[gi].transactions.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme, Color onSurf, Color tertiaryColor, bool isFiltered) {
    return Stack(
      children: [
        Column(
          children: List.generate(5, (_) => _PlaceholderRow()),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.3],
                colors: [
                  theme.scaffoldBackgroundColor.withOpacity(0.0),
                  theme.scaffoldBackgroundColor,
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_outlined, size: 64, color: onSurf.withOpacity(0.25)),
                  const Gap(20),
                  Text(
                    isFiltered ? 'No results found' : 'No transactions yet',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: onSurf),
                  ),
                  const Gap(8),
                  Text(
                    isFiltered
                        ? 'We tried our best but couldn\'t find what you\'re looking for.'
                        : 'Your transactions will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: tertiaryColor),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints three horizontally centered lines, each shorter than the one above,
/// mimicking the classic filter/sort icon (stacked descending bars).
class _FilterLinesPainter extends CustomPainter {
  final Color color;
  _FilterLinesPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final cx = size.width / 2;
    // Three lines: full width, 60%, 30%
    final widths = [size.width, size.width * 0.6, size.width * 0.3];
    final ys = [2.0, size.height / 2, size.height - 2.0];
    for (int i = 0; i < 3; i++) {
      final half = widths[i] / 2;
      canvas.drawLine(Offset(cx - half, ys[i]), Offset(cx + half, ys[i]), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Placeholder row mimicking a transaction for the empty state background.
class _PlaceholderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final shimmerColor = Theme.of(context).colorScheme.onSurface.withOpacity(0.06);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, color: shimmerColor),
          ),
          const Gap(16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 100, height: 14,
                  decoration: BoxDecoration(color: shimmerColor, borderRadius: BorderRadius.circular(7)),
                ),
                const Gap(6),
                Container(
                  width: 60, height: 12,
                  decoration: BoxDecoration(color: shimmerColor, borderRadius: BorderRadius.circular(6)),
                ),
              ],
            ),
          ),
          Container(
            width: 48, height: 14,
            decoration: BoxDecoration(color: shimmerColor, borderRadius: BorderRadius.circular(7)),
          ),
        ],
      ),
    );
  }
}

void injectMockTxsIfEmpty({void Function()? notify}) {
  if (aa.txs.items.isNotEmpty) return;
  final now = DateTime.now();
  final latest = syncStatus2.latestHeight ?? 3000000;
  final demo = <Tx>[];
  void addTx({
    required int id,
    required int height,
    required DateTime ts,
    required double value,
    required String txId,
    required String fullId,
    String? address,
    String? contact,
    String? memo,
  }) {
    final confs = (syncStatus2.latestHeight?.let((h) => h - height + 1)) ?? 3;
    demo.add(Tx(
      id,
      height,
      confs,
      ts,
      txId,
      fullId,
      value,
      address,
      contact,
      memo,
      const [],
    ));
  }

  addTx(
    id: 1,
    height: latest - 120,
    ts: now.subtract(Duration(hours: 8)),
    value: 0.5234,
    txId: 'u_in_1',
    fullId: 'uaddr_incoming_1',
    address: 'u1qf...mock',
    contact: 'Alice (Unified)',
    memo: 'Payment for lunch',
  );
  addTx(
    id: 2,
    height: latest - 110,
    ts: now.subtract(Duration(hours: 7, minutes: 20)),
    value: -0.1178,
    txId: 'u_out_1',
    fullId: 'uaddr_outgoing_1',
    address: 'u1zo...mock',
    contact: 'Bob (Unified)',
    memo: 'Tip',
  );
  addTx(
    id: 3,
    height: latest - 90,
    ts: now.subtract(Duration(hours: 6, minutes: 45)),
    value: 1.0025,
    txId: 'sap_in_1',
    fullId: 'sapling_incoming_1',
    address: 'zs1...mock',
    contact: 'Carol (Sapling)',
    memo: 'Reimbursement',
  );
  addTx(
    id: 4,
    height: latest - 80,
    ts: now.subtract(Duration(hours: 5, minutes: 10)),
    value: -0.3501,
    txId: 'sap_out_1',
    fullId: 'sapling_outgoing_1',
    address: 'zs1...mock',
    contact: null,
    memo: 'Purchase',
  );
  addTx(
    id: 5,
    height: latest - 60,
    ts: now.subtract(Duration(hours: 3, minutes: 55)),
    value: 0.275,
    txId: 'orch_in_1',
    fullId: 'orchard_incoming_1',
    address: 'uo1...mock',
    contact: 'Dave (Orchard)',
    memo: 'Refund',
  );
  addTx(
    id: 6,
    height: latest - 58,
    ts: now.subtract(Duration(hours: 3, minutes: 40)),
    value: -0.0503,
    txId: 'orch_out_1',
    fullId: 'orchard_outgoing_1',
    address: 'uo1...mock',
    contact: null,
    memo: 'Swap',
  );
  addTx(
    id: 7,
    height: latest - 45,
    ts: now.subtract(Duration(hours: 2, minutes: 15)),
    value: 0.015,
    txId: 't_in_1',
    fullId: 'transparent_incoming_1',
    address: 't1...mock',
    contact: 'Legacy (T)',
    memo: 'Faucet',
  );
  addTx(
    id: 8,
    height: latest - 40,
    ts: now.subtract(Duration(hours: 2)),
    value: -0.0101,
    txId: 't_out_1',
    fullId: 'transparent_outgoing_1',
    address: 't1...mock',
    contact: null,
    memo: 'Fee',
  );
  // Mix in specific relative-time examples
  void addTimedTx({
    required int id,
    required int daysAgo,
    required bool incoming,
    required String pool,
    String? contact,
    String? memo,
  }) {
    final ts = now.subtract(Duration(days: daysAgo, hours: incoming ? 1 : 3));
    final h = latest - (daysAgo * 100 + (incoming ? 5 : 10));
    final address = pool == 'u'
        ? 'u1...mock'
        : pool == 'sap'
            ? 'zs1...mock'
            : pool == 'orch'
                ? 'uo1...mock'
                : 't1...mock';
    final txId = 'timed_${pool}_${incoming ? 'in' : 'out'}_${daysAgo}';
    final fullId = 'timed_${pool}_${incoming ? 'incoming' : 'outgoing'}_${daysAgo}';
    addTx(
      id: id,
      height: h,
      ts: ts,
      value: (incoming ? 1 : -1) * (0.01 + daysAgo * 0.002),
      txId: txId,
      fullId: fullId,
      address: address,
      contact: contact,
      memo: memo ?? (incoming ? 'Incoming' : 'Outgoing'),
    );
  }

  // Today
  addTimedTx(id: 1000, daysAgo: 0, incoming: true, pool: 'orch', contact: 'Today Friend', memo: 'Coffee');
  // Yesterday
  addTimedTx(id: 1001, daysAgo: 1, incoming: false, pool: 'sap', contact: null, memo: 'Pay bill');
  // 2-7 days ago
  addTimedTx(id: 1002, daysAgo: 2, incoming: true, pool: 'u', contact: 'Peer 2');
  addTimedTx(id: 1003, daysAgo: 3, incoming: false, pool: 't', contact: null);
  addTimedTx(id: 1004, daysAgo: 4, incoming: true, pool: 'orch', contact: 'Peer 4');
  addTimedTx(id: 1005, daysAgo: 5, incoming: false, pool: 'sap', contact: null);
  addTimedTx(id: 1006, daysAgo: 6, incoming: true, pool: 'u', contact: null);
  addTimedTx(id: 1007, daysAgo: 7, incoming: false, pool: 'orch', contact: 'Vendor 7');
  // 45 days ago
  addTimedTx(id: 1045, daysAgo: 45, incoming: true, pool: 'u', contact: null, memo: 'Old airdrop');

  // Additional explicit transactions for verification
  // Another Yesterday
  addTimedTx(id: 1101, daysAgo: 1, incoming: true, pool: 'u', contact: 'Yesterday Peer', memo: 'Groceries');
  // Another 3 days ago
  addTimedTx(id: 1103, daysAgo: 3, incoming: true, pool: 'orch', contact: null, memo: 'Reimbursement');
  // Specific date: Jul 15 at 8:07 AM (current year)
  final jul15 = DateTime(now.year, 7, 15, 8, 7);
  final daysAgoJul15 = now.difference(jul15).inDays;
  addTx(
    id: 1115,
    height: latest - (daysAgoJul15 * 100 + 17),
    ts: jul15,
    value: 0.042,
    txId: 'fixed_jul15_in',
    fullId: 'fixed_jul15_in_full',
    address: 'u1...jul15',
    contact: null,
    memo: 'Fixed date sample',
  );
  for (int i = 0; i < 6; i++) {
    final incoming = i % 2 == 0;
    final orchard = i % 3 == 0;
    final poolLabel = orchard ? 'orch' : (i % 3 == 1 ? 'sap' : 'u');
    addTx(
      id: 100 + i,
      height: latest - 20 + i,
      ts: now.subtract(Duration(minutes: 30 - 3 * i)),
      value: (incoming ? 1 : -1) * (0.01 + i * 0.003),
      txId: '${poolLabel}_${incoming ? 'in' : 'out'}_$i',
      fullId: '${poolLabel}_${incoming ? 'incoming' : 'outgoing'}_$i',
      address: orchard ? 'uo1...mock' : (poolLabel == 'sap' ? 'zs1...mock' : 'u1...mock'),
      contact: incoming ? (i.isEven ? null : 'Friend $i') : (i.isOdd ? null : 'Payment $i'),
      memo: incoming ? 'Thanks #$i' : 'Payment #$i',
    );
  }

  aa.txs.items = demo;
  notify?.call();
}

// For preview on Balance page: if there are very few real txs, append some
// mock samples so the UI can be verified. Does nothing if we already have
// at least [minCount] txs.
void injectMockTxsIfFew({int minCount = 10, void Function()? notify}) {
  if (aa.txs.items.length >= minCount) return;
  if (aa.txs.items.isEmpty) {
    injectMockTxsIfEmpty(notify: notify);
    return;
  }
  final now = DateTime.now();
  final latest = syncStatus2.latestHeight ?? 3000000;
  final List<Tx> extra = [];

  void addTx({
    required int id,
    required int height,
    required DateTime ts,
    required double value,
    required String txId,
    required String fullId,
    String? address,
    String? contact,
    String? memo,
  }) {
    final confs = (syncStatus2.latestHeight?.let((h) => h - height + 1)) ?? 3;
    extra.add(Tx(
      id,
      height,
      confs,
      ts,
      txId,
      fullId,
      value,
      address,
      contact,
      memo,
      const [],
    ));
  }

  DateTime daysAgo(int d, {int hour = 10, int minute = 0}) =>
      DateTime(now.year, now.month, now.day, hour, minute).subtract(Duration(days: d));
  int h(int d, int off) => latest - (d * 100 + off);

  // Append Today, Yesterday, 3 days ago, and the fixed Jul 15 sample
  addTx(
    id: 900001,
    height: h(0, 21),
    ts: daysAgo(0, hour: 9, minute: 32),
    value: 0.031,
    txId: 'preview_today',
    fullId: 'preview_today_full',
    address: 'u1...preview',
    contact: 'Preview Today',
    memo: 'Demo',
  );
  addTx(
    id: 900002,
    height: h(1, 22),
    ts: daysAgo(1, hour: 11, minute: 5),
    value: -0.012,
    txId: 'preview_yesterday',
    fullId: 'preview_yesterday_full',
    address: 'zs1...preview',
    contact: null,
    memo: 'Demo',
  );
  addTx(
    id: 900003,
    height: h(3, 23),
    ts: daysAgo(3, hour: 14, minute: 40),
    value: 0.25,
    txId: 'preview_3days',
    fullId: 'preview_3days_full',
    address: 'uo1...preview',
    contact: 'Preview 3d',
    memo: 'Demo',
  );
  final jul15 = DateTime(now.year, 7, 15, 8, 7);
  final daysAgoJul15 = now.difference(jul15).inDays;
  addTx(
    id: 900004,
    height: h(daysAgoJul15, 24),
    ts: jul15,
    value: 0.042,
    txId: 'preview_jul15',
    fullId: 'preview_jul15_full',
    address: 'u1...jul15',
    contact: null,
    memo: 'Demo',
  );

  aa.txs.items = [...aa.txs.items, ...extra];
  notify?.call();
}

class TableListTxMetadata extends TableListItemMetadata<Tx> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget separator(BuildContext context) => Divider(
        height: 8,
        thickness: 0.5,
        color: Theme.of(context).dividerColor.withOpacity(0.25),
      );

  @override
  Widget toListTile(BuildContext context, int index, Tx tx,
      {void Function(void Function())? setState}) {
    ZMessage? message;
    try {
      message = aa.messages.items.firstWhere((m) => m.txId == tx.id);
    } on StateError {
      message = null;
    }
    return TxItem(tx, message, index: index);
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    return [
      ColumnDefinition(field: 'height', label: s.height, numeric: true),
      ColumnDefinition(field: 'confirmations', label: s.confs, numeric: true),
      ColumnDefinition(field: 'timestamp', label: s.datetime),
      ColumnDefinition(field: 'value', label: s.amount),
      ColumnDefinition(field: 'fullTxId', label: s.txID),
      ColumnDefinition(field: 'address', label: s.address),
      ColumnDefinition(field: 'memo', label: s.memo),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, Tx tx) {
    final t = Theme.of(context);
    final color = amountColor(context, tx.value);
    var style = t.textTheme.bodyMedium!.copyWith(color: color);
    style = weightFromAmount(style, tx.value);
    final a = tx.contact ?? centerTrim(tx.address ?? '');
    final m = tx.memo?.let((m) => m.substring(0, min(m.length, 32))) ?? '';

    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(Text("${tx.height}")),
          DataCell(Text("${tx.confirmations}")),
          DataCell(Text("${txDateFormat.format(tx.timestamp)}")),
          DataCell(Text(decimalToString(tx.value),
              style: style, textAlign: TextAlign.left)),
          DataCell(Text("${tx.txId}")),
          DataCell(Text("$a")),
          DataCell(Text("$m")),
        ],
        onSelectChanged: (_) => gotoTx(context, index));
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.txs.setSortOrder(field);
    return aa.txs.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}

class TxItem extends StatelessWidget {
  final Tx tx;
  final int? index;
  final ZMessage? message;
  TxItem(this.tx, this.message, {this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contact = tx.contact?.isEmpty ?? true ? '?' : tx.contact!;
    final initial = contact[0];
    final color = amountColor(context, tx.value);

    final onSurf = theme.colorScheme.onSurface;
    final baseStyle = theme.textTheme.titleLarge!;
    final todayStyle = theme.textTheme.bodySmall;
    final targetSize = todayStyle?.fontSize ?? baseStyle.fontSize;
    final valueStyle = baseStyle.copyWith(
      fontSize: targetSize,
      color: tx.value < 0 ? onSurf : color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final ticker = tx.symbol ?? coins[aa.coin].ticker;
    final valueText = appStore.hideBalances ? '\u2013 \u2013.\u2013 \u2013 $ticker' : '${decimalToStringTrim(tx.value)} $ticker';
    final value = Text(valueText, style: valueStyle);
    final trailing = Column(children: [value]);

    // Unified label/icon for both Balance preview and full History
    final addr = tx.address ?? '';
    final isCloak = CloakWalletManager.isCloak(aa.coin);
    String displayLabel;
    String? subtitle;
    if (isCloak) {
      final isTelos = _isTelosAccount(addr);
      if (addr == 'Vault Withdraw' || addr == 'Vault Deposit' || addr == 'Publish Vault' || addr == 'Burn Vault' || addr == 'Send Fee') {
        displayLabel = addr;
        subtitle = 'fee';
      } else if (tx.value >= 0) {
        if (addr == 'thezeosvault') {
          displayLabel = 'Vault Withdraw';
        } else if (isTelos && addr.isNotEmpty) {
          displayLabel = 'Shielded';
          subtitle = 'from $addr';
        } else {
          displayLabel = 'Received';
        }
      } else {
        if (addr == 'thezeosvault') {
          displayLabel = 'Vault Deposit';
        } else if (isTelos && addr.isNotEmpty) {
          displayLabel = 'Deshielded';
          subtitle = 'to $addr';
        } else {
          displayLabel = 'Sent';
        }
      }
    } else {
      displayLabel = (tx.value >= 0) ? 'Received' : 'Sent';
    }
    final isTransparent = isCloak
        ? _isTelosAccount(addr)
        : addr.startsWith('t');

    // CLOAK uses SVG icons: receive_quick (incoming), send_quick (outgoing), shield_check (shielded)
    final Widget av;
    if (isCloak) {
      final zashi = theme.extension<ZashiThemeExt>();
      final bg = zashi != null
          ? Color.lerp(zashi.quickGradTop, zashi.quickGradBottom, 0.5)!
          : initialToColor(initial);
      final String svgAsset;
      if (_isTelosAccount(addr) && addr != 'thezeosvault' && tx.value >= 0) {
        svgAsset = 'assets/icons/shield_check.svg';
      } else if (tx.value >= 0) {
        svgAsset = 'assets/icons/receive_quick.svg';
      } else {
        svgAsset = 'assets/icons/send_quick.svg';
      }
      av = CircleAvatar(
        backgroundColor: bg,
        radius: 16.0,
        child: SvgPicture.asset(
          svgAsset,
          width: 20,
          height: 20,
          colorFilter: ColorFilter.mode(onSurf, BlendMode.srcIn),
        ),
      );
    } else {
      av = avatar(initial, incoming: tx.value >= 0);
    }

    return GestureDetector(
        onTap: () {
          if (index != null) gotoTx(context, index!);
        },
        behavior: HitTestBehavior.translucent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              av,
              Gap(15),
              Expanded(
                child: MessageContentWidget(
                  displayLabel,
                  message,
                  tx.memo ?? '',
                  displayLabel: displayLabel,
                  subtitle: subtitle,
                  inlineIcon: !isTransparent
                      ? SvgPicture.asset(
                          'assets/icons/shield_check.svg',
                          width: 16,
                          height: 16,
                          colorFilter: ColorFilter.mode(
                            Theme.of(context).colorScheme.onSurface,
                            BlendMode.srcIn,
                          ),
                        )
                      : null,
                  timestamp: tx.timestamp,
                ),
              ),
              SizedBox(width: kTxTrailingWidth, child: Align(alignment: Alignment.centerRight, child: trailing)),
            ],
          ),
        ));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Transaction Details - Shared UI Components
// ════════════════════════════════════════════════════════════════════════════

/// Date format for transaction details: "Month Day, Year at HH:MM:SS AM/PM"
final DateFormat _txDetailDateFormat = DateFormat("MMMM d, yyyy 'at' h:mm:ss a");

/// Section label widget matching app design patterns
Widget _txSectionLabel(String text) {
  return Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Colors.white.withOpacity(0.35),
      letterSpacing: 2,
    ),
  );
}

/// Section description (layman explanation) widget
Widget _txSectionDescription(String text) {
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: Colors.white.withOpacity(0.4),
        height: 1.3,
      ),
    ),
  );
}

/// Data field card with optional copy button
Widget _txDataField({
  required String value,
  bool mono = false,
  VoidCallback? onCopy,
}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF2E2C2C),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withOpacity(0.08)),
    ),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: mono ? 'monospace' : null,
              fontSize: mono ? 12 : 14,
              color: Colors.white.withOpacity(0.85),
              height: 1.5,
            ),
          ),
        ),
        if (onCopy != null) ...[
          const SizedBox(width: 12),
          GestureDetector(
            onTap: onCopy,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.copy, size: 16, color: Colors.white.withOpacity(0.5)),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Status badge for confirmed/pending states
/// On Telos, if we have a txId the transaction is confirmed (instant finality)
Widget _txStatusBadge({required bool confirmed, int? confirmations}) {
  // If confirmed=true (we have a txId), show Confirmed regardless of confirmations count
  // Telos has instant finality - if a tx is in Hyperion history, it's confirmed
  final isConfirmed = confirmed;
  final statusText = isConfirmed
      ? (confirmations != null && confirmations > 0 ? 'Confirmed ($confirmations)' : 'Confirmed')
      : 'Pending';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: isConfirmed
          ? const Color(0xFF4CAF50).withOpacity(0.15)
          : Colors.orange.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: isConfirmed
            ? const Color(0xFF4CAF50).withOpacity(0.3)
            : Colors.orange.withOpacity(0.3),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isConfirmed ? Icons.check_circle : Icons.schedule,
          size: 14,
          color: isConfirmed ? const Color(0xFF4CAF50) : Colors.orange,
        ),
        const SizedBox(width: 6),
        Text(
          statusText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isConfirmed ? const Color(0xFF4CAF50) : Colors.orange,
          ),
        ),
      ],
    ),
  );
}

/// Copy helper with snackbar feedback
void _copyToClipboard(BuildContext context, String value, String label) {
  Clipboard.setData(ClipboardData(text: value));
  showSnackBar(S.of(context).copiedToClipboard);
}

/// Build the main transaction details content
Widget _buildTxDetailsContent(BuildContext context, Tx tx) {
  final s = S.of(context);
  final confirmations = tx.confirmations ?? 0;
  // Telos confirms in 1-3 seconds. If we have a trxId from Hyperion, it's confirmed.
  // The transaction wouldn't appear in Hyperion history if it wasn't confirmed.
  final hasTxId = tx.fullTxId.isNotEmpty;
  final isConfirmed = hasTxId; // If we have a trxId, it's confirmed on Telos

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // ── Status Section ──
      _txSectionLabel('STATUS'),
      _txSectionDescription('Current confirmation state of this transaction'),
      const SizedBox(height: 10),
      _txStatusBadge(confirmed: isConfirmed, confirmations: hasTxId ? confirmations : null),
      const SizedBox(height: 24),

      // ── Transaction Hash Section (only if available) ──
      if (hasTxId) ...[
        _txSectionLabel('TRANSACTION HASH'),
        _txSectionDescription('Unique identifier for this transaction on the blockchain'),
        const SizedBox(height: 10),
        _txDataField(
          value: tx.fullTxId,
          mono: true,
          onCopy: () => _copyToClipboard(context, tx.fullTxId, 'Transaction Hash'),
        ),
        const SizedBox(height: 24),
      ],

      // ── Block Number Section (only if available) ──
      if (tx.height > 0) ...[
        _txSectionLabel('BLOCK NUMBER'),
        _txSectionDescription('The block that contains this transaction'),
        const SizedBox(height: 10),
        _txDataField(
          value: tx.height.toString(),
          mono: true,
        ),
        const SizedBox(height: 24),
      ],

      // ── Transaction Time Section ──
      _txSectionLabel('TRANSACTION TIME'),
      _txSectionDescription('When this transaction occurred'),
      const SizedBox(height: 10),
      _txDataField(
        value: _txDetailDateFormat.format(tx.timestamp),
      ),
      const SizedBox(height: 24),

      // ── Amount Section ──
      _txSectionLabel('AMOUNT'),
      _txSectionDescription('The value transferred in this transaction'),
      const SizedBox(height: 10),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2E2C2C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Text(
          '${tx.value >= 0 ? '+' : ''}${decimalToString(tx.value)} ${tx.symbol ?? 'CLOAK'}',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: tx.value >= 0 ? const Color(0xFF4CAF50) : Colors.redAccent,
          ),
        ),
      ),
      const SizedBox(height: 24),

      // ── Address Section (if available) ──
      if (tx.address != null && tx.address!.isNotEmpty) ...[
        _txSectionLabel('ADDRESS'),
        _txSectionDescription('The recipient or sender address'),
        const SizedBox(height: 10),
        _txDataField(
          value: tx.address!,
          mono: true,
          onCopy: () => _copyToClipboard(context, tx.address!, 'Address'),
        ),
        const SizedBox(height: 24),
      ],

      // ── Contact Section (if available) ──
      if (tx.contact != null && tx.contact!.isNotEmpty) ...[
        _txSectionLabel('CONTACT'),
        _txSectionDescription('Known contact associated with this transaction'),
        const SizedBox(height: 10),
        _txDataField(value: tx.contact!),
        const SizedBox(height: 24),
      ],

      // ── Memo Section (if available) ──
      if (tx.memo != null && tx.memo!.isNotEmpty) ...[
        _txSectionLabel('MEMO'),
        _txSectionDescription('Private note attached to this transaction'),
        const SizedBox(height: 10),
        _txDataField(value: tx.memo!),
        const SizedBox(height: 24),
      ],

      // ── Additional Memos (if any) ──
      ...tx.memos.map((txm) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _txSectionLabel('MEMO'),
          _txSectionDescription('Additional memo from ${txm.address}'),
          const SizedBox(height: 10),
          _txDataField(value: txm.memo),
          const SizedBox(height: 24),
        ],
      )),

      // ── View in Explorer Button (only if txId available) ──
      if (hasTxId) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Material(
            color: const Color(0xFF2E2C2C),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => openTxInExplorer(tx.fullTxId),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.open_in_new, size: 18, color: Colors.white.withOpacity(0.7)),
                  const SizedBox(width: 10),
                  Text(
                    s.openInExplorer,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.85),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

// ════════════════════════════════════════════════════════════════════════════
// TransactionPage - Index-based Transaction Details
// ════════════════════════════════════════════════════════════════════════════

class TransactionPage extends StatefulWidget {
  final int txIndex;

  TransactionPage(this.txIndex);

  @override
  State<StatefulWidget> createState() => TransactionState();
}

class TransactionState extends State<TransactionPage> {
  late int idx;
  TransactionDetails? _details;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    idx = widget.txIndex;
    _loadDetails();
  }

  Tx get tx => aa.txs.items[idx];

  Future<void> _loadDetails() async {
    // Only fetch for CLOAK transactions (have timestamp but may lack trxId)
    if (CloakWalletManager.isCloak(aa.coin)) {
      final timestampMs = tx.timestamp.millisecondsSinceEpoch;

      // Check block-direct cache first (instant, no network)
      var details = CloakSync.getCachedTxDetails(timestampMs);

      // Fall back to Hyperion if not cached
      details ??= await fetchTransactionDetails(timestampMs);

      if (mounted) {
        setState(() {
          _details = details;
          _loading = false;
        });
      }
    } else {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    // Create an enhanced Tx with fetched details if available
    final displayTx = _details != null
        ? Tx(
            tx.id,
            _details!.blockNum > 0 ? _details!.blockNum : tx.height,
            tx.confirmations,
            tx.timestamp,
            _details!.trxId,
            _details!.trxId,
            tx.value,
            tx.address,
            tx.contact,
            tx.memo,
            tx.memos,
            symbol: tx.symbol,
          )
        : tx;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(s.transactionDetails),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
            )
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(8),
                    _buildTxDetailsContent(context, displayTx),
                    const Gap(32),
                  ],
                ),
              ),
            ),
    );
  }
}

void gotoTx(BuildContext context, int index) {
  // If this is a fee entry, find the parent transaction (same timestamp, not a fee)
  final txs = aa.txs.items;
  if (index >= 0 && index < txs.length) {
    final tx = txs[index];
    if (TxPageState.isFeeEntry(tx)) {
      // Find the parent transaction by matching timestamp
      for (int i = 0; i < txs.length; i++) {
        final other = txs[i];
        if (i != index &&
            !TxPageState.isFeeEntry(other) &&
            (tx.timestamp.millisecondsSinceEpoch - other.timestamp.millisecondsSinceEpoch).abs() < 5000) {
          // Found the parent transaction - navigate to it instead
          GoRouter.of(context).push('/tx_details?index=$i');
          return;
        }
      }
    }
  }
  // Transaction details as full-screen overlay via /tx_details
  GoRouter.of(context).push('/tx_details?index=$index');
}

void gotoTxById(BuildContext context, int txId, {String? from, int? threadIndex}) {
  final params = <String>['tx=$txId'];
  if (from != null && from.isNotEmpty) params.add('from=$from');
  if (threadIndex != null) params.add('thread=$threadIndex');
  GoRouter.of(context).push('/tx_details/byid?${params.join('&')}');
}

// ════════════════════════════════════════════════════════════════════════════
// TransactionByIdPage - ID-based Transaction Details with Observer
// ════════════════════════════════════════════════════════════════════════════

class TransactionByIdPage extends StatefulWidget {
  final int txId;
  final String? from;
  final int? threadIndex;

  TransactionByIdPage(this.txId, {this.from, this.threadIndex});

  @override
  State<StatefulWidget> createState() => TransactionByIdState();
}

class TransactionByIdState extends State<TransactionByIdPage> {
  late int _txId;
  bool _requested = false;
  String? _from;
  int? _threadIndex;
  TransactionDetails? _details;
  bool _detailsLoading = true;

  @override
  void initState() {
    super.initState();
    _txId = widget.txId;
    _from = widget.from;
    _threadIndex = widget.threadIndex;
  }

  void _ensureTxs() {
    if (_requested) return;
    _requested = true;
    Future(() async {
      try {
        aa.txs.read(aa.height);
      } catch (_) {}
    });
  }

  Future<void> _loadDetails(Tx tx) async {
    if (!_detailsLoading) return; // Already loaded
    if (CloakWalletManager.isCloak(aa.coin)) {
      final timestampMs = tx.timestamp.millisecondsSinceEpoch;
      final details = await fetchTransactionDetails(timestampMs);
      if (mounted) {
        setState(() {
          _details = details;
          _detailsLoading = false;
        });
      }
    } else {
      if (mounted) {
        setState(() => _detailsLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Observer(builder: (context) {
      // Track observables so this rebuilds when the tx list updates
      aa.txs.items; // depend on items list changes
      aaSequence.seqno; // global refresh ticks
      syncStatus2.changed; // sync updates
      final idx = aa.txs.indexOfTxId(_txId);

      // Loading state - tx not found yet
      if (idx < 0) {
        _ensureTxs();
        return Scaffold(
          backgroundColor: const Color(0xFF1E1E1E),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1E1E1E),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.maybePop(context),
            ),
            title: Text(s.transactionDetails),
          ),
          body: const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF4CAF50),
            ),
          ),
        );
      }

      final tx = aa.txs.items[idx];

      // Trigger detail loading once we have the tx
      if (_detailsLoading) {
        _loadDetails(tx);
      }

      // Create an enhanced Tx with fetched details if available
      final displayTx = _details != null
          ? Tx(
              tx.id,
              _details!.blockNum > 0 ? _details!.blockNum : tx.height,
              tx.confirmations,
              tx.timestamp,
              _details!.trxId,
              _details!.trxId,
              tx.value,
              tx.address,
              tx.contact,
              tx.memo,
              tx.memos,
              symbol: tx.symbol,
            )
          : tx;

      return Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E1E1E),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_from == 'messages' && _threadIndex != null) {
                // Return to the exact thread details view
                GoRouter.of(context).go('/messages/details?index=${_threadIndex}');
              } else {
                // Pop the overlay to reveal the page underneath
                GoRouter.of(context).pop();
              }
            },
          ),
          title: Text(s.transactionDetails),
        ),
        body: _detailsLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
              )
            : SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Gap(8),
                      _buildTxDetailsContent(context, displayTx),
                      const Gap(32),
                    ],
                  ),
                ),
              ),
      );
    });
  }
}

/// Returns true if [addr] looks like a Telos/EOSIO account name (1-12 chars, a-z1-5.)
bool _isTelosAccount(String addr) {
  if (addr.isEmpty || addr.length > 12) return false;
  return RegExp(r'^[a-z1-5.]{1,12}$').hasMatch(addr);
}
