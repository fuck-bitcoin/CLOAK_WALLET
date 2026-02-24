import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../accounts.dart';
import '../../cloak/cloak_db.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../router.dart' show router;

class BackupPage extends StatefulWidget {
  BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _loading = true;
  String? _error;

  // Account data
  String? _name;
  String? _seed;
  int _index = 0;
  String? _sk;
  String? _fvk;
  String? _ivk;
  String? _ovk;
  String? _address;

  // Vaults
  List<Map<String, dynamic>> _vaults = [];

  // Auth tokens
  List<_AuthToken> _unspentAts = [];
  List<_AuthToken> _spentAts = [];

  // Expand state
  bool _keysExpanded = false;
  bool _vaultsExpanded = false;
  bool _atsExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final account = await CloakDb.getAccount(aa.id);
      if (account == null) {
        setState(() { _error = 'Account not found'; _loading = false; });
        return;
      }

      _name = account['name'] as String?;
      _seed = account['seed'] as String?;
      _index = account['aindex'] as int? ?? 0;
      _sk = account['sk'] as String?;
      _address = account['address'] as String?;

      if (CloakWalletManager.isLoaded) {
        _fvk = CloakWalletManager.getFvkBech32m();
        _ivk = CloakWalletManager.getIvkBech32m();
        _ovk = CloakWalletManager.getOvkBech32m();
      }

      _vaults = await CloakWalletManager.getImportedVaults(accountId: aa.id);

      // Load auth tokens
      _unspentAts = _parseAts(CloakWalletManager.getAuthenticationTokensJson(spent: false));
      _spentAts = _parseAts(CloakWalletManager.getAuthenticationTokensJson(spent: true));

      setState(() => _loading = false);
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  List<_AuthToken> _parseAts(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return list.whereType<String>().map((s) {
        final parts = s.split('@');
        return _AuthToken(
          hash: parts[0],
          contract: parts.length > 1 ? parts[1] : 'unknown',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        backgroundColor: const Color(0xFF4CAF50),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Seed, Keys & Auth Tokens'),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Color(0xFFEF5350))))
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Seed Phrase ──
          if (_seed != null) ...[
            _sectionLabel('RECOVERY PHRASE'),
            const SizedBox(height: 10),
            _seedCard(),
            const SizedBox(height: 8),
            Text(
              'Your 24-word recovery phrase is the master key that can restore your entire wallet. Keep it safe and never share it.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.4),
                height: 1.4,
              ),
            ),
          ],

          // ── Address ──
          if (_address != null) ...[
            const SizedBox(height: 28),
            _sectionLabel('SHIELDED ADDRESS'),
            const SizedBox(height: 10),
            _dataField(
              value: _address!,
              mono: true,
              onCopy: () => _copy(_address!, 'Address'),
              onTap: () => router.push('/showqr?title=Address', extra: _address!),
            ),
            const SizedBox(height: 8),
            Text(
              'Share this to receive CLOAK payments.',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4), height: 1.4),
            ),
          ],

          // ── Viewing Keys (collapsible) ──
          if (_fvk != null || _ivk != null || _ovk != null || _sk != null) ...[
            const SizedBox(height: 28),
            _expandableHeader(
              label: 'VIEWING KEYS',
              expanded: _keysExpanded,
              onTap: () => setState(() => _keysExpanded = !_keysExpanded),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 250),
              crossFadeState: _keysExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_sk != null)
                      _keyEntry('Secret Key', _sk!, 'Full spending authority. Never share.'),
                    if (_fvk != null && _fvk!.isNotEmpty)
                      _keyEntry('Full Viewing Key', _fvk!, 'View both incoming AND outgoing transactions.'),
                    if (_ivk != null && _ivk!.isNotEmpty)
                      _keyEntry('Incoming Viewing Key', _ivk!, 'View incoming transactions only.'),
                    if (_ovk != null && _ovk!.isNotEmpty)
                      _keyEntry('Outgoing Viewing Key', _ovk!, 'View outgoing transactions only.'),
                  ],
                ),
              ),
            ),
          ],

          // ── Vaults (collapsible) ──
          if (_vaults.isNotEmpty) ...[
            const SizedBox(height: 28),
            _expandableHeader(
              label: 'CLOAK VAULTS (${_vaults.length})',
              expanded: _vaultsExpanded,
              onTap: () => setState(() => _vaultsExpanded = !_vaultsExpanded),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 250),
              crossFadeState: _vaultsExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  children: _vaults.map((v) => _vaultCard(v)).toList(),
                ),
              ),
            ),
          ],

          // ── Auth Tokens (collapsible) ──
          if (_unspentAts.isNotEmpty || _spentAts.isNotEmpty) ...[
            const SizedBox(height: 28),
            _expandableHeader(
              label: 'AUTH TOKENS (${_unspentAts.length + _spentAts.length})',
              expanded: _atsExpanded,
              onTap: () => setState(() => _atsExpanded = !_atsExpanded),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 250),
              crossFadeState: _atsExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_unspentAts.isNotEmpty) ...[
                      _atSubLabel('Unspent (${_unspentAts.length})'),
                      const SizedBox(height: 6),
                      ..._unspentAts.map((at) => _atCard(at, spent: false)),
                    ],
                    if (_spentAts.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _atSubLabel('Spent (${_spentAts.length})'),
                      const SizedBox(height: 6),
                      ..._spentAts.map((at) => _atCard(at, spent: true)),
                    ],
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ── Section label ──
  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Colors.white.withOpacity(0.35),
        letterSpacing: 2,
      ),
    );
  }

  // ── Expandable header with animated chevron ──
  Widget _expandableHeader({
    required String label,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white.withOpacity(0.35),
                letterSpacing: 2,
              ),
            ),
          ),
          AnimatedRotation(
            turns: expanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: Icon(
              Icons.expand_more,
              size: 20,
              color: Colors.white.withOpacity(0.35),
            ),
          ),
        ],
      ),
    );
  }

  // ── Seed card (prominent, styled like splash page) ──
  Widget _seedCard() {
    var seedText = _seed!;
    if (_index != 0) seedText += ' [$_index]';
    final words = seedText.split(' ');

    return GestureDetector(
      onTap: () => router.push('/showqr?title=Seed', extra: seedText),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF2E2C2C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF4CAF50).withOpacity(0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 8,
              children: List.generate(words.length, (i) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '${i + 1}  ',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withOpacity(0.25),
                            fontFamily: 'monospace',
                          ),
                        ),
                        TextSpan(
                          text: words[i],
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _actionPill(Icons.copy, 'Copy', () => _copy(seedText, 'Seed phrase')),
                const SizedBox(width: 8),
                _actionPill(Icons.qr_code, 'QR', () => router.push('/showqr?title=Seed', extra: seedText)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Data field (for address, keys, etc.) ──
  Widget _dataField({
    required String value,
    bool mono = false,
    VoidCallback? onCopy,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2E2C2C),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: TextStyle(
                  fontFamily: mono ? 'monospace' : null,
                  fontSize: mono ? 12 : 14,
                  color: Colors.white.withOpacity(0.8),
                  height: 1.5,
                ),
              ),
            ),
            if (onCopy != null) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onCopy,
                child: Icon(Icons.copy, size: 18, color: Colors.white.withOpacity(0.4)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Key entry (inside viewing keys section) ──
  Widget _keyEntry(String label, String value, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 6),
          _dataField(
            value: value,
            mono: true,
            onCopy: () => _copy(value, label),
            onTap: () => router.push('/showqr?title=$label', extra: value),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35), height: 1.4),
          ),
        ],
      ),
    );
  }

  // ── Vault card ──
  Widget _vaultCard(Map<String, dynamic> vault) {
    final hash = vault['commitment_hash'] as String? ?? '';
    final seed = vault['seed'] as String? ?? '';
    final contract = vault['contract'] as String? ?? 'thezeostoken';
    final label = vault['label'] as String? ?? 'Vault';
    final truncHash = hash.length >= 24
        ? '${hash.substring(0, 12)}...${hash.substring(hash.length - 8)}'
        : hash;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF2E2C2C),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showVaultDetails(vault),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.lock_outline, size: 20, color: Color(0xFF4CAF50)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        truncHash,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.white.withOpacity(0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: Colors.white.withOpacity(0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Vault detail sheet ──
  void _showVaultDetails(Map<String, dynamic> vault) {
    final hash = vault['commitment_hash'] as String? ?? '';
    final seed = vault['seed'] as String? ?? '';
    final contract = vault['contract'] as String? ?? 'thezeostoken';
    final label = vault['label'] as String? ?? 'Vault';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                label,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const SizedBox(height: 20),
              _sheetField(ctx, 'Commitment Hash', hash, mono: true),
              const SizedBox(height: 14),
              _sheetField(ctx, 'Seed', seed, mono: false),
              const SizedBox(height: 14),
              _sheetField(ctx, 'Contract', contract, mono: false),
              const SizedBox(height: 14),
              _sheetField(ctx, 'Deposit To', 'thezeosvault', mono: true),
              const SizedBox(height: 14),
              _sheetField(ctx, 'Deposit Memo', 'AUTH:$hash|', mono: true),
              const SizedBox(height: 24),
              // Deposit button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: Material(
                  color: const Color(0xFF4CAF50),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      Navigator.pop(ctx);
                      _copy('AUTH:$hash|', 'Deposit memo');
                    },
                    child: const Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy, size: 18, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            'Copy Deposit Memo',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Auth token sub-label ──
  Widget _atSubLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: Colors.white.withOpacity(0.5),
      ),
    );
  }

  // ── Auth token card ──
  Widget _atCard(_AuthToken at, {required bool spent}) {
    final truncHash = at.hash.length >= 24
        ? '${at.hash.substring(0, 12)}...${at.hash.substring(at.hash.length - 8)}'
        : at.hash;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF2E2C2C),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showAtDetails(at, spent: spent),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (spent
                        ? Colors.white.withOpacity(0.06)
                        : const Color(0xFF4CAF50).withOpacity(0.15)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    spent ? Icons.token_outlined : Icons.token,
                    size: 20,
                    color: spent ? Colors.white.withOpacity(0.3) : const Color(0xFF4CAF50),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        truncHash,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Colors.white.withOpacity(spent ? 0.4 : 0.8),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        at.contract,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.35),
                        ),
                      ),
                    ],
                  ),
                ),
                if (spent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'SPENT',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.3),
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                if (!spent)
                  Icon(Icons.chevron_right, size: 20, color: Colors.white.withOpacity(0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Auth token detail sheet ──
  void _showAtDetails(_AuthToken at, {required bool spent}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text(
                    'Auth Token',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  if (spent)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'SPENT',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withOpacity(0.3),
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              _sheetField(ctx, 'Hash', at.hash, mono: true),
              const SizedBox(height: 14),
              _sheetField(ctx, 'Token Contract', at.contract, mono: false),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sheet field (used in both vault + auth token detail sheets) ──
  Widget _sheetField(BuildContext ctx, String label, String value, {bool mono = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Colors.white.withOpacity(0.35),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF2E2C2C),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: TextStyle(
                    fontFamily: mono ? 'monospace' : null,
                    fontSize: mono ? 12 : 14,
                    color: Colors.white.withOpacity(0.8),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _copy(value, label),
                child: Icon(Icons.copy, size: 16, color: Colors.white.withOpacity(0.35)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Small action pill (Copy / QR buttons) ──
  Widget _actionPill(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white.withOpacity(0.5)),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthToken {
  final String hash;
  final String contract;
  _AuthToken({required this.hash, required this.contract});
}
