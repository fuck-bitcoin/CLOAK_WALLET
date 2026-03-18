import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../cloak/cloak_db.dart';
import '../../cloak/eosio_client.dart' show getAccount;
import '../../theme/zashi_tokens.dart';

class TelosAccountsPage extends StatefulWidget {
  const TelosAccountsPage({super.key});

  @override
  State<TelosAccountsPage> createState() => _TelosAccountsPageState();
}

class _TelosAccountsPageState extends State<TelosAccountsPage> {
  List<Map<String, dynamic>> _accounts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final accounts = await CloakDb.getTelosAccounts();
    if (mounted) setState(() { _accounts = accounts; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Builder(builder: (context) {
          final base = t.appBarTheme.titleTextStyle ??
              t.textTheme.titleLarge ??
              t.textTheme.titleMedium ??
              t.textTheme.bodyMedium;
          final reduced = (base?.fontSize != null)
              ? base!.copyWith(fontSize: base.fontSize! * 0.75)
              : base;
          return Text('TELOS ACCOUNTS', style: reduced);
        }),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _accounts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'No Telos accounts saved yet.\nTap the button below to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: balanceTextColor.withOpacity(0.5),
                        fontFamily: balanceFontFamily,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  itemCount: _accounts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final acct = _accounts[index];
                    final name = acct['account_name'] as String;
                    final label = acct['label'] as String? ?? '';
                    final id = acct['id'] as int;
                    return Material(
                      color: t.colorScheme.surfaceVariant.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            // Telos ring icon
                            SvgPicture.asset(
                              'assets/icons/telos_ring.svg',
                              width: 28,
                              height: 28,
                              colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      color: balanceTextColor,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  if (label.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      label,
                                      style: TextStyle(
                                        color: balanceTextColor.withOpacity(0.5),
                                        fontFamily: balanceFontFamily,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.edit_outlined, color: balanceTextColor.withOpacity(0.5), size: 20),
                              onPressed: () => _showEditLabelDialog(id, label),
                              splashRadius: 20,
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: balanceTextColor.withOpacity(0.4), size: 20),
                              onPressed: () => _showDeleteDialog(id, name),
                              splashRadius: 20,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            colors: [
              Color.lerp(const Color(0xFF5CE1E6), Colors.black, 0.35)!,
              Color.lerp(const Color(0xFF38A1DB), Colors.black, 0.35)!,
              Color.lerp(const Color(0xFFCB6CE6), Colors.black, 0.35)!,
            ],
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: _showAddDialog,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.white.withOpacity(0.3), blurRadius: 8, spreadRadius: 1),
                      ],
                    ),
                    child: SvgPicture.asset(
                      'assets/icons/telos_ring.svg',
                      width: 22,
                      height: 22,
                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text('Add Account', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Dialogs (matching app UX pattern) ----

  Future<void> _showAddDialog() async {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final nameController = TextEditingController();
    final labelController = TextEditingController();
    String? errorText;
    bool validating = false;

    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
    );
    final radius = BorderRadius.circular(14);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              title: Text('Add Telos Account', style: titleStyle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    cursorColor: balanceTextColor,
                    style: TextStyle(color: balanceTextColor, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: 'Account Address',
                      hintStyle: TextStyle(color: balanceTextColor.withOpacity(0.3), fontFamily: balanceFontFamily),
                      filled: true,
                      fillColor: const Color(0xFF2E2C2C),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      errorText: errorText,
                      errorStyle: TextStyle(color: Colors.redAccent.withOpacity(0.8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: labelController,
                    cursorColor: balanceTextColor,
                    style: TextStyle(color: balanceTextColor, fontFamily: balanceFontFamily),
                    decoration: InputDecoration(
                      hintText: 'Label (optional)',
                      hintStyle: TextStyle(color: balanceTextColor.withOpacity(0.3), fontFamily: balanceFontFamily),
                      filled: true,
                      fillColor: const Color(0xFF2E2C2C),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                  ),
                  if (validating) ...[
                    const SizedBox(height: 16),
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: Material(
                            color: balanceTextColor.withOpacity(0.15),
                            shape: RoundedRectangleBorder(borderRadius: radius),
                            child: InkWell(
                              borderRadius: radius,
                              onTap: () => Navigator.of(ctx).pop(),
                              child: Center(
                                child: Text('Cancel', style: bodyStyle),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: Material(
                            color: balanceTextColor,
                            shape: RoundedRectangleBorder(borderRadius: radius),
                            child: InkWell(
                              borderRadius: radius,
                              onTap: validating
                                  ? null
                                  : () async {
                                      final name = nameController.text.trim().toLowerCase();
                                      if (name.isEmpty) {
                                        setDialogState(() => errorText = 'Account name is required');
                                        return;
                                      }
                                      final exists = await CloakDb.telosAccountExists(name);
                                      if (exists) {
                                        setDialogState(() => errorText = 'Account already saved');
                                        return;
                                      }
                                      setDialogState(() { validating = true; errorText = null; });
                                      final acctInfo = await getAccount(name);
                                      if (acctInfo == null) {
                                        setDialogState(() { validating = false; errorText = 'Account not found on Telos'; });
                                        return;
                                      }
                                      await CloakDb.addTelosAccount(name, label: labelController.text.trim());
                                      if (ctx.mounted) Navigator.of(ctx).pop();
                                      await _loadAccounts();
                                    },
                              child: Center(
                                child: Text(
                                  'Add',
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
                    ],
                  ),
                ],
              ),
              actions: const [], // Buttons are inline above
            );
          },
        );
      },
    );
  }

  Future<void> _showEditLabelDialog(int id, String currentLabel) async {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: balanceTextColor, fontFamily: balanceFontFamily, fontWeight: FontWeight.w400,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor, fontFamily: balanceFontFamily,
    );
    final radius = BorderRadius.circular(14);
    final controller = TextEditingController(text: currentLabel);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          title: Text('Edit Label', style: titleStyle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                cursorColor: balanceTextColor,
                style: TextStyle(color: balanceTextColor, fontFamily: balanceFontFamily),
                decoration: InputDecoration(
                  hintText: 'Label',
                  hintStyle: TextStyle(color: balanceTextColor.withOpacity(0.3)),
                  filled: true,
                  fillColor: const Color(0xFF2E2C2C),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(height: 44, child: Material(
                      color: balanceTextColor.withOpacity(0.15),
                      shape: RoundedRectangleBorder(borderRadius: radius),
                      child: InkWell(borderRadius: radius, onTap: () => Navigator.of(ctx).pop(),
                        child: Center(child: Text('Cancel', style: bodyStyle))),
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(height: 44, child: Material(
                      color: balanceTextColor,
                      shape: RoundedRectangleBorder(borderRadius: radius),
                      child: InkWell(borderRadius: radius, onTap: () async {
                        await CloakDb.updateTelosAccountLabel(id, controller.text.trim());
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        await _loadAccounts();
                      }, child: Center(child: Text('Save', style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                        fontFamily: balanceFontFamily, fontWeight: FontWeight.w600, color: t.colorScheme.background,
                      )))),
                    )),
                  ),
                ],
              ),
            ],
          ),
          actions: const [],
        );
      },
    );
  }

  Future<void> _showDeleteDialog(int id, String name) async {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
      color: balanceTextColor, fontFamily: balanceFontFamily, fontWeight: FontWeight.w400,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor, fontFamily: balanceFontFamily,
    );
    final radius = BorderRadius.circular(14);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          title: Text('Delete Account', style: titleStyle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Remove "$name" from saved accounts?', style: bodyStyle),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(height: 44, child: Material(
                      color: balanceTextColor.withOpacity(0.15),
                      shape: RoundedRectangleBorder(borderRadius: radius),
                      child: InkWell(borderRadius: radius, onTap: () => Navigator.of(ctx).pop(false),
                        child: Center(child: Text('Cancel', style: bodyStyle))),
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(height: 44, child: Material(
                      color: Colors.redAccent.withOpacity(0.8),
                      shape: RoundedRectangleBorder(borderRadius: radius),
                      child: InkWell(borderRadius: radius, onTap: () => Navigator.of(ctx).pop(true),
                        child: Center(child: Text('Delete', style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                          fontFamily: balanceFontFamily, fontWeight: FontWeight.w600, color: Colors.white,
                        )))),
                    )),
                  ),
                ],
              ),
            ],
          ),
          actions: const [],
        );
      },
    );
    if (confirmed == true) {
      await CloakDb.deleteTelosAccount(id);
      await _loadAccounts();
    }
  }
}
