import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import '../../cloak/cloak_types.dart';

import '../../accounts.dart';
import '../../cloak/cloak_db.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../generated/intl/messages.dart';
import '../accounts/send.dart';
import '../utils.dart';

/// Backup data for CLOAK accounts (mirrors Backup structure)
class CloakBackup {
  final String? name;
  final String? seed;
  final int index;
  final String? sk;
  final String? fvk;  // Full Viewing Key (bech32m encoded: fvk1...)
  final String? ivk;  // Incoming Viewing Key (bech32m encoded: ivk1...)
  final String? ovk;  // Outgoing Viewing Key (bech32m encoded: ovk1...)
  final String? address;

  CloakBackup({
    this.name,
    this.seed,
    this.index = 0,
    this.sk,
    this.fvk,
    this.ivk,
    this.ovk,
    this.address,
  });
}

/// Key type descriptions for CLOAK
class CloakKeyDescriptions {
  static const seed = 'Your 24-word recovery phrase. '
      'This is the master key that can restore your entire wallet. '
      'Keep it safe and never share it.';
  static const fvk = 'Full Viewing Key. '
      'View both incoming AND outgoing transactions. '
      'Share with auditors or services that need complete visibility.';
  static const ivk = 'Incoming Viewing Key. '
      'View incoming transactions only. '
      'Share to let others monitor deposits without seeing your spending.';
  static const ovk = 'Outgoing Viewing Key. '
      'View outgoing transactions only. '
      'Share to let others verify your payments.';
  static const address = 'Your shielded payment address. '
      'Share this to receive CLOAK payments.';
}

class BackupPage extends StatefulWidget {
  // For Zcash/Ycash
  Backup? zcashBackup;
  // For CLOAK
  CloakBackup? cloakBackup;
  String primary = '';  // Mutable - set async for CLOAK
  late final bool isCloak;

  BackupPage() {
    isCloak = CloakWalletManager.isCloak(aa.coin);

    if (isCloak) {
      // CLOAK: Get backup from CloakDb (async, will be loaded in state)
      cloakBackup = null; // Will be loaded async
      // primary will be set in _loadCloakBackup()
    } else {
      // Non-CLOAK: no longer supported
      throw 'Only CLOAK accounts are supported';
    }
  }

  @override
  State<StatefulWidget> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> {
  bool showSubKeys = false;
  bool showVaults = false;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _vaults = [];

  @override
  void initState() {
    super.initState();
    if (widget.isCloak) {
      _loadCloakBackup();
    } else {
      _loading = false;
    }
  }

  Future<void> _loadCloakBackup() async {
    try {
      final account = await CloakDb.getAccount(aa.id);
      if (account == null) {
        setState(() {
          _error = 'Account not found';
          _loading = false;
        });
        return;
      }

      // Get all viewing keys from the live wallet if available
      String? fvk;
      String? ivk;
      String? ovk;
      if (CloakWalletManager.isLoaded) {
        fvk = CloakWalletManager.getFvkBech32m();
        ivk = CloakWalletManager.getIvkBech32m();
        ovk = CloakWalletManager.getOvkBech32m();
      }

      widget.cloakBackup = CloakBackup(
        name: account['name'] as String?,
        seed: account['seed'] as String?,
        index: account['aindex'] as int? ?? 0,
        sk: account['sk'] as String?,
        fvk: fvk,
        ivk: ivk,
        ovk: ovk,
        address: account['address'] as String?,
      );

      // Set primary key
      if (widget.cloakBackup!.seed != null) {
        widget.primary = widget.cloakBackup!.seed!;
      } else if (widget.cloakBackup!.ivk != null) {
        widget.primary = widget.cloakBackup!.ivk!;
      } else if (widget.cloakBackup!.address != null) {
        widget.primary = widget.cloakBackup!.address!;
      } else {
        _error = 'Account has no key';
      }

      // Load imported vaults
      _vaults = await CloakWalletManager.getImportedVaults(accountId: aa.id);

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = 'Error loading backup: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(s.backup),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(s.backup),
        ),
        body: Center(child: Text(_error!, style: TextStyle(color: Colors.red))),
      );
    }

    // Build cards based on whether this is CLOAK or Zcash
    List<Widget> cards = [];
    TextStyle? style;
    final small = t.textTheme.bodySmall!;
    final String name;

    if (widget.isCloak) {
      final backup = widget.cloakBackup!;
      name = backup.name ?? 'CLOAK Account';

      if (backup.seed != null) {
        var seed = backup.seed!;
        if (backup.index != 0) seed += ' [${backup.index}]';
        cards.add(BackupPanelWithDescription(
          name,
          s.seed,
          seed,
          Icon(Icons.save),
          CloakKeyDescriptions.seed,
        ));
        style = small;
      }
      if (backup.sk != null) {
        cards.add(BackupPanel(
            name, s.secretKey, backup.sk!, Icon(Icons.vpn_key),
            style: style));
        style = small;
      }
      if (backup.fvk != null && backup.fvk!.isNotEmpty) {
        cards.add(BackupPanelWithDescription(
          name,
          'Full Viewing Key',
          backup.fvk!,
          Icon(Icons.visibility),
          CloakKeyDescriptions.fvk,
          style: style,
        ));
        style = small;
      }
      if (backup.ivk != null && backup.ivk!.isNotEmpty) {
        cards.add(BackupPanelWithDescription(
          name,
          'Incoming Viewing Key',
          backup.ivk!,
          Icon(Icons.visibility_outlined),
          CloakKeyDescriptions.ivk,
          style: style,
        ));
        style = small;
      }
      if (backup.ovk != null && backup.ovk!.isNotEmpty) {
        cards.add(BackupPanelWithDescription(
          name,
          'Outgoing Viewing Key',
          backup.ovk!,
          Icon(Icons.send),
          CloakKeyDescriptions.ovk,
          style: style,
        ));
        style = small;
      }
      if (backup.address != null) {
        cards.add(BackupPanelWithDescription(
          name,
          'Address',
          backup.address!,
          Icon(Icons.qr_code),
          CloakKeyDescriptions.address,
          style: style,
        ));
        style = small;
      }

      // Add vaults section if any vaults exist
      if (_vaults.isNotEmpty) {
        cards.add(_buildVaultsSection(name, small));
      }
    } else {
      name = 'Account';
    }

    if (cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(s.backup),
        ),
        body: Center(child: Text('No keys available')),
      );
    }

    final subKeys = cards.length > 1 ? cards.sublist(1) : <Widget>[];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(s.backup),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            cards[0],
            if (subKeys.isNotEmpty)
              FormBuilderSwitch(
                name: 'subkeys',
                title: Text(s.showSubKeys),
                initialValue: showSubKeys,
                onChanged: (v) => setState(() => showSubKeys = v!),
              ),
            if (showSubKeys) ...subKeys,
            Gap(8),
            // Only show backup reminder for Zcash (CLOAK doesn't use WarpApi)
            if (!widget.isCloak)
              FormBuilderSwitch(
                  name: 'remind',
                  title: Text(s.noRemindBackup),
                  initialValue: aa.saved,
                  onChanged: _remind)
          ]),
        ),
      ),
    );
  }

  _remind(bool? v) {
    // CLOAK doesn't use backup reminders
  }

  /// Build the vaults section widget
  Widget _buildVaultsSection(String accountName, TextStyle smallStyle) {
    return Card(
      elevation: 2,
      margin: EdgeInsets.only(top: 16),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_balance_wallet, color: Colors.green),
                SizedBox(width: 8),
                Text(
                  'CLOAK Vaults (${_vaults.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Spacer(),
                IconButton(
                  icon: Icon(showVaults ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => showVaults = !showVaults),
                ),
              ],
            ),
            if (showVaults) ...[
              Divider(),
              ..._vaults.map((vault) => _buildVaultCard(vault, accountName, smallStyle)),
            ],
          ],
        ),
      ),
    );
  }

  /// Build a single vault card
  Widget _buildVaultCard(Map<String, dynamic> vault, String accountName, TextStyle smallStyle) {
    final commitmentHash = vault['commitment_hash'] as String? ?? '';
    final seed = vault['seed'] as String? ?? '';
    final contract = vault['contract'] as String? ?? 'thezeostoken';
    final label = vault['label'] as String? ?? 'Vault';

    return GestureDetector(
      onTap: () => _showVaultDetails(context, vault, accountName),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        margin: EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Label
              Text(
                label,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              // Commitment hash (truncated)
              Row(
                children: [
                  Icon(Icons.tag, size: 16, color: Colors.grey),
                  SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${commitmentHash.substring(0, 16)}...${commitmentHash.substring(commitmentHash.length - 8)}',
                      style: smallStyle.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 4),
              // Contract
              Row(
                children: [
                  Icon(Icons.token, size: 16, color: Colors.grey),
                  SizedBox(width: 4),
                  Text(contract, style: smallStyle),
                ],
              ),
              SizedBox(height: 8),
              Text(
                'Tap to view full details',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Show vault details dialog (similar to CLOAK GUI Auth Token Details)
  void _showVaultDetails(BuildContext context, Map<String, dynamic> vault, String accountName) {
    final commitmentHash = vault['commitment_hash'] as String? ?? '';
    final seed = vault['seed'] as String? ?? '';
    final contract = vault['contract'] as String? ?? 'thezeostoken';
    final label = vault['label'] as String? ?? 'Vault';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.account_balance_wallet),
            SizedBox(width: 8),
            Text('Auth Token Details'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Deposit To
              _buildDetailField(
                context,
                'Deposit To',
                'thezeosvault',
                canCopy: true,
                isMonospace: true,
              ),
              SizedBox(height: 16),
              // Deposit Memo
              _buildDetailField(
                context,
                'Deposit Memo',
                'AUTH:$commitmentHash|',
                canCopy: true,
                isMonospace: true,
              ),
              SizedBox(height: 16),
              // Commitment Hash
              _buildDetailField(
                context,
                'Commitment Hash',
                commitmentHash,
                canCopy: true,
                isMonospace: true,
              ),
              SizedBox(height: 16),
              // Seed
              _buildDetailField(
                context,
                'Seed',
                seed,
                canCopy: true,
                isMonospace: false,
              ),
              SizedBox(height: 16),
              // Contract
              _buildDetailField(
                context,
                'Contract',
                contract,
                canCopy: true,
                isMonospace: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              GoRouter.of(context).push('/account/quick_send', extra: SendContext(
                'thezeosvault',
                7,
                Amount(0, false),
                MemoData(false, '', 'AUTH:$commitmentHash|'),
              ));
            },
            icon: const Icon(Icons.savings, size: 18),
            label: const Text('Deposit'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  /// Build a detail field with copy functionality
  Widget _buildDetailField(
    BuildContext context,
    String label,
    String value, {
    bool canCopy = false,
    bool isMonospace = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
        SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: TextStyle(
                    fontFamily: isMonospace ? 'monospace' : null,
                    fontSize: isMonospace ? 12 : 14,
                  ),
                ),
              ),
              if (canCopy)
                IconButton(
                  icon: Icon(Icons.copy, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Copied $label to clipboard')),
                    );
                  },
                  tooltip: 'Copy',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class BackupPanel extends StatelessWidget {
  final String name;
  final String label;
  final String value;
  final Icon icon;
  final TextStyle? style;

  BackupPanel(this.name, this.label, this.value, this.icon, {this.style});
  @override
  Widget build(BuildContext context) {
    final qrLabel = '$label of $name';
    return GestureDetector(
        onTap: () => showQR(context, value, qrLabel),
        child: Card(
          elevation: 2,
          child: Padding(
            padding: EdgeInsets.all(8),
            child: InputDecorator(
              decoration: InputDecoration(
                  label: Text(label), icon: icon, border: OutlineInputBorder()),
              child: Text(
                value,
                style: style,
                maxLines: 6,
              ),
            ),
          ),
        ));
  }

  showQR(BuildContext context, String value, String title) {
    GoRouter.of(context).push('/showqr?title=$title', extra: value);
  }
}

/// BackupPanel with description text below the value
class BackupPanelWithDescription extends StatelessWidget {
  final String name;
  final String label;
  final String value;
  final Icon icon;
  final String description;
  final TextStyle? style;

  BackupPanelWithDescription(
    this.name,
    this.label,
    this.value,
    this.icon,
    this.description, {
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final qrLabel = '$label of $name';
    return GestureDetector(
      onTap: () => showQR(context, value, qrLabel),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: InputDecoration(
                  label: Text(label),
                  icon: icon,
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  value,
                  style: style,
                  maxLines: 6,
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: 40, top: 8, right: 8),
                child: Text(
                  description,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  showQR(BuildContext context, String value, String title) {
    GoRouter.of(context).push('/showqr?title=$title', extra: value);
  }
}
