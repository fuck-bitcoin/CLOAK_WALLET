import 'package:cloak_wallet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import '../../theme/zashi_tokens.dart';
import '../../cloak/cloak_types.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show pow;
import '../../coin/coins.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import '../../store2.dart';
import 'dart:async';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/cloak_db.dart';
import '../settings.dart';
import '../utils.dart';
import '../widgets.dart';
import '../main/balance.dart';
import '../main/sync_status.dart';
import '../../widgets/nft_image_widget.dart';
import '../scan.dart';

/// Validate a CLOAK/ZEOS address: shielded (za1...) or Telos account name (1-12 chars, a-z1-5.)
bool _isValidCloakAddress(String address) {
  if (address.startsWith('za1')) {
    // za1 addresses are bech32m: 3-char prefix + 75 data chars = 78 total
    if (address.length < 70 || address.length > 120) return false;
    final suffix = address.substring(3);
    final validChars = RegExp(r'^[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+$');
    return validChars.hasMatch(suffix);
  }
  // Vault deposit: 64-char hex commitment hash
  if (address.length == 64) {
    return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(address);
  }
  // Telos account name (for deshielded sends / off-ramp)
  if (address.isNotEmpty && address.length <= 12) {
    return RegExp(r'^[a-z1-5.]{1,12}$').hasMatch(address);
  }
  return false;
}

/// Check if a CLOAK address is a shielded za1 address (vs Telos account name)
bool _isCloakShieldedAddress(String address) {
  return address.startsWith('za1') && address.length >= 70 && address.length <= 120;
}

class SendContext {
  final String address; // underlying real address
  final int pools;
  final Amount amount;
  final MemoData? memo;
  // Snapshot of the FX rate used when the user entered the fiat amount
  final double? fx;
  // Optional display text to show in the address field (e.g., contact name)
  final String? display;
  // Launched from a Messages thread (enables special routing/read-only UI)
  final bool fromThread;
  // Index of the originating thread (for /messages/details?index=<idx>)
  final int? threadIndex;
  // Conversation id for the thread (base64url without padding)
  final String? threadCid;
  // Token being sent (null = CLOAK default)
  final String? tokenSymbol;    // e.g. 'CLOAK', 'USDT'
  final String? tokenContract;  // e.g. 'thezeostoken', 'eosio.token'
  final int? tokenPrecision;    // e.g. 4 for CLOAK
  // Vault withdrawal: if set, this is a vault authenticate (not a normal send)
  final String? vaultHash;      // 64-char commitment hash
  // NFT send/withdraw fields
  final String? nftId;          // NFT asset ID (u64 as string)
  final String? nftContract;    // NFT contract (e.g. 'atomicassets')
  final String? nftImageUrl;    // for display on confirm page
  final String? nftName;        // human-readable NFT name
  // Batch vault withdrawal (Quick Withdraw): withdraw ALL vault assets in one TX
  final bool isBatchWithdraw;
  final List<BatchAsset>? batchAssets;  // FTs and NFTs to withdraw
  // Quick Deposit from vault: send flow uses wallet balance, title says "Deposit"
  final bool isVaultDeposit;
  SendContext(this.address, this.pools, this.amount, this.memo, [this.fx, this.display, this.fromThread = false, this.threadIndex, this.threadCid, this.tokenSymbol, this.tokenContract, this.tokenPrecision, this.vaultHash, this.nftId, this.nftContract, this.nftImageUrl, this.nftName, this.isBatchWithdraw = false, this.batchAssets, this.isVaultDeposit = false]);
  static SendContext? fromPaymentURI(String puri) {
    // CLOAK doesn't use Zcash-style payment URIs
    throw S.of(navigatorKey.currentContext!).invalidPaymentURI;
  }

  @override
  String toString() {
    return 'SendContext($address, $pools, ${amount.value}, ${memo?.memo}, fx=$fx, display=$display, fromThread=$fromThread, threadIndex=$threadIndex, threadCid=$threadCid, token=$tokenSymbol@$tokenContract, vault=$vaultHash, nft=$nftId@$nftContract, nftName=$nftName, batch=$isBatchWithdraw, batchAssets=${batchAssets?.length})';
  }

  static SendContext? instance;
}

/// Descriptor for a single asset in a batch vault withdrawal.
class BatchAsset {
  final String symbol;       // e.g. 'CLOAK', 'USDT'
  final String contract;     // e.g. 'thezeostoken'
  final int precision;       // e.g. 4
  final int amountUnits;     // amount in smallest units (e.g. 10000 = 1.0000 CLOAK)
  final String? nftId;       // non-null for NFTs
  final String? nftName;     // human-readable NFT name
  final String? nftImageUrl; // NFT thumbnail URL

  const BatchAsset({
    required this.symbol,
    required this.contract,
    required this.precision,
    required this.amountUnits,
    this.nftId,
    this.nftName,
    this.nftImageUrl,
  });

  bool get isNft => nftId != null;

  String get formattedAmount {
    final amt = amountUnits / _pow10(precision);
    return '${amt.toStringAsFixed(precision)} $symbol';
  }

  static double _pow10(int n) {
    double r = 1;
    for (int i = 0; i < n; i++) r *= 10;
    return r;
  }
}

/// Lightweight token descriptor for the send asset picker.
class _SendToken {
  final String symbol;
  final String contract;
  final String amount;     // formatted string like "3.1000"
  final int precision;     // derived from decimal places
  final int balanceUnits;  // amount × 10^precision

  _SendToken({
    required this.symbol,
    required this.contract,
    required this.amount,
    required this.precision,
    required this.balanceUnits,
  });

  String? get logoUrl => _getSendTokenLogoUrl(symbol, contract);
}

String? _getSendTokenLogoUrl(String symbol, String contract) {
  const wellKnown = {
    'thezeostoken:CLOAK': 'asset:assets/cloak_logo.png',
    'eosio.token:TLOS': 'https://raw.githubusercontent.com/AnyswapIN/nftlist/main/telos.png',
  };
  return wellKnown['$contract:$symbol'];
}

Color _getSendTokenColor(String symbol) {
  switch (symbol) {
    case 'CLOAK': return Colors.purple;
    case 'TLOS': return Colors.blue;
    case 'USDT': return Colors.green;
    case 'USDC': return Colors.blue.shade700;
    case 'BTC': case 'WBTC': return Colors.orange;
    case 'ETH': case 'WETH': return Colors.indigo;
    default: return Colors.grey.shade600;
  }
}

/// Parse shielded tokens from getBalancesJson(). Returns list sorted with CLOAK first.
List<_SendToken> _parseShieldedTokens() {
  final raw = CloakWalletManager.getBalancesJson();
  final List<_SendToken> tokens = [];
  if (raw != null && raw.isNotEmpty) {
    try {
      final List<dynamic> parsed = jsonDecode(raw);
      for (final entry in parsed) {
        final str = entry.toString();
        final atIdx = str.lastIndexOf('@');
        if (atIdx < 0) continue;
        final quantityPart = str.substring(0, atIdx);
        final contract = str.substring(atIdx + 1);
        final spaceIdx = quantityPart.lastIndexOf(' ');
        if (spaceIdx < 0) continue;
        final amountStr = quantityPart.substring(0, spaceIdx);
        final symbol = quantityPart.substring(spaceIdx + 1);
        // Derive precision from decimal places in amount string
        final dotIdx = amountStr.indexOf('.');
        final precision = dotIdx >= 0 ? amountStr.length - dotIdx - 1 : 0;
        final scale = pow(10, precision).toInt();
        final balanceUnits = ((double.tryParse(amountStr) ?? 0.0) * scale).round();
        tokens.add(_SendToken(
          symbol: symbol,
          contract: contract,
          amount: amountStr,
          precision: precision,
          balanceUnits: balanceUnits,
        ));
      }
    } catch (_) {}
  }
  // Sort: CLOAK first, then alphabetical
  tokens.sort((a, b) {
    if (a.symbol == 'CLOAK' && b.symbol != 'CLOAK') return -1;
    if (b.symbol == 'CLOAK' && a.symbol != 'CLOAK') return 1;
    return a.symbol.compareTo(b.symbol);
  });
  return tokens;
}

/// Mock NFT flag — matches home.dart
const _kMockNfts = true;

/// Lightweight NFT descriptor for the send asset picker.
class _SendNft {
  final String nftId;       // u64 asset ID as string
  final String contract;    // e.g. 'atomicassets'
  final String? name;       // optional display name
  final String? imageUrl;   // optional image (asset: or https:)

  _SendNft({required this.nftId, required this.contract, this.name, this.imageUrl});
}

/// Parse shielded NFTs from getNftsJson(). Injects mock data when empty and _kMockNfts is on.
List<_SendNft> _parseShieldedNfts() {
  final raw = CloakWalletManager.getNftsJson();
  final List<_SendNft> nfts = [];
  if (raw != null && raw.isNotEmpty) {
    try {
      final List<dynamic> parsed = jsonDecode(raw);
      for (final entry in parsed) {
        final str = entry.toString();
        final atIdx = str.lastIndexOf('@');
        if (atIdx < 0) continue;
        final nftId = str.substring(0, atIdx);
        final contract = str.substring(atIdx + 1);
        nfts.add(_SendNft(nftId: nftId, contract: contract));
      }
    } catch (_) {}
  }
  if (_kMockNfts && nfts.isEmpty) {
    nfts.addAll([
      _SendNft(nftId: '1099511627776', contract: 'atomicassets', name: 'CLOAK Gold Coin', imageUrl: 'asset:assets/nft/cloak-gold-coin.png'),
      _SendNft(nftId: '1099511627777', contract: 'atomicassets', name: 'CLOAK Front', imageUrl: 'asset:assets/nft/cloak-front.png'),
      _SendNft(nftId: '1099511627778', contract: 'atomicassets', name: 'Anonymous Face', imageUrl: 'asset:assets/nft/anonymous-face.png'),
    ]);
  }
  return nfts;
}

/// Parse vault FTs from activeVaultTokens
List<_SendToken> _parseVaultTokens() {
  final vt = activeVaultTokens;
  if (vt == null) return [];
  return vt.fts.map((ft) {
    final symbol = ft['symbol'] as String? ?? 'CLOAK';
    final contract = ft['contract'] as String? ?? '';
    final amount = ft['amount'] as String? ?? '0';
    final dotIdx = amount.indexOf('.');
    final precision = dotIdx >= 0 ? amount.length - dotIdx - 1 : 0;
    final scale = pow(10, precision).toInt();
    final balanceUnits = ((double.tryParse(amount) ?? 0.0) * scale).round();
    return _SendToken(symbol: symbol, contract: contract, amount: amount, precision: precision, balanceUnits: balanceUnits);
  }).toList();
}

/// Parse vault NFTs from activeVaultTokens
List<_SendNft> _parseVaultNfts() {
  final vt = activeVaultTokens;
  if (vt == null) return [];
  final List<_SendNft> nfts = vt.nfts.map((nft) => _SendNft(
    nftId: nft['id']?.toString() ?? '',
    contract: nft['contract']?.toString() ?? '',
    imageUrl: nft['imageUrl']?.toString(),
  )).toList();
  if (_kMockNfts && nfts.isEmpty) {
    nfts.addAll([
      _SendNft(nftId: '1099511627776', contract: 'atomicassets', name: 'CLOAK Gold Coin', imageUrl: 'asset:assets/nft/cloak-gold-coin.png'),
      _SendNft(nftId: '1099511627777', contract: 'atomicassets', name: 'CLOAK Front', imageUrl: 'asset:assets/nft/cloak-front.png'),
      _SendNft(nftId: '1099511627778', contract: 'atomicassets', name: 'Anonymous Face', imageUrl: 'asset:assets/nft/anonymous-face.png'),
    ]);
  }
  return nfts;
}

class QuickSendPage extends StatefulWidget {
  final SendContext? sendContext;
  final bool custom;
  final bool single;
  QuickSendPage({this.sendContext, this.custom = false, this.single = true});

  @override
  State<StatefulWidget> createState() => _QuickSendState();
}

class _QuickSendState extends State<QuickSendPage> with WithLoadingAnimation {
  final formKey = GlobalKey<FormBuilderState>();
  final poolKey = GlobalKey<PoolSelectionState>();
  // Removed legacy AmountPicker; ZashiAmountRow manages amount and fiat now
  final memoKey = GlobalKey<InputMemoState>();
  final _sendToTopController = TextEditingController();
  late PoolBalanceT balances = _getBalances();
  // Multi-asset send state
  List<_SendToken> _shieldedTokens = [];
  _SendToken? _selectedToken; // defaults to CLOAK
  // NFT send state
  List<_SendNft> _shieldedNfts = [];
  _SendNft? _selectedNft;       // non-null when sending an NFT
  bool get _isNftMode => _selectedNft != null;

  /// True when the send flow is operating as a vault withdrawal (not a deposit).
  /// isVaultDeposit sends FROM the wallet TO the vault, so it uses wallet state.
  bool get _isVaultWithdrawMode =>
      isVaultMode && !(widget.sendContext?.isVaultDeposit == true);

  PoolBalanceT _getBalances() {
    if (CloakWalletManager.isCloak(aa.coin)) {
      if (widget.sendContext?.isVaultDeposit == true) {
        // Vault deposit: use real wallet balance from Rust, not aa.poolBalances
        // (which holds vault balance in vault mode)
        return _getWalletBalanceFromRust();
      }
      return aa.poolBalances;
    }
    return aa.poolBalances; // Non-CLOAK path — return cached balances
  }

  /// Get the real CLOAK wallet balance directly from Rust FFI,
  /// bypassing aa.poolBalances which may hold vault balance.
  static PoolBalanceT _getWalletBalanceFromRust() {
    final raw = CloakWalletManager.getBalancesJson();
    final bal = PoolBalanceT();
    if (raw != null && raw.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(raw);
        for (final entry in parsed) {
          final str = entry.toString();
          if (str.contains('CLOAK@thezeostoken')) {
            final spaceIdx = str.indexOf(' ');
            if (spaceIdx > 0) {
              final amt = double.tryParse(str.substring(0, spaceIdx)) ?? 0.0;
              bal.sapling = (amt * 10000).round();
            }
            break;
          }
        }
      } catch (_) {}
    }
    return bal;
  }
  String _address = '';
  int _pools = 7;
  Amount _amount = Amount(0, false);
  MemoData _memo =
      MemoData(appSettings.includeReplyTo != 0, '', '');
  String? _contactReplyToUA;
  bool isShielded = false;
  int addressPools = 0;
  bool isTex = false;
  int rp = 0;
  late bool custom;
  String? _addressError;
  bool _addressIsValid = false;
  bool _showAddContactHelp = false;
  Timer? _addContactTimer;

  @override
  void initState() {
    super.initState();
    custom = widget.custom ^ appSettings.customSend;
    // Load shielded tokens and NFTs for multi-asset send picker
    if (CloakWalletManager.isCloak(aa.coin)) {
      if (_isVaultWithdrawMode) {
        _shieldedTokens = _parseVaultTokens();
        _shieldedNfts = _parseVaultNfts();
      } else {
        _shieldedTokens = _parseShieldedTokens();
        _shieldedNfts = _parseShieldedNfts();
      }
      // Default to CLOAK (always first if present)
      _selectedToken = _shieldedTokens.isNotEmpty
          ? _shieldedTokens.first
          : _SendToken(symbol: 'CLOAK', contract: 'thezeostoken', amount: '0.0000', precision: 4, balanceUnits: 0);
    }
    // Defer inherited widget access (e.g., S.of(context)) until after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _didUpdateSendContext(widget.sendContext);
      }
    });
  }

  @override
  void didUpdateWidget(QuickSendPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    balances = _getBalances();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _didUpdateSendContext(widget.sendContext);
    });
  }

  @override
  Widget build(BuildContext context) {
    final customSendSettings = appSettings.customSendSettings;
    final bool _isCloakSelected = (_selectedToken?.symbol ?? 'CLOAK') == 'CLOAK';
    final spendable = CloakWalletManager.isCloak(aa.coin) && !_isCloakSelected
        ? _selectedToken!.balanceUnits
        : getSpendable(_pools, balances);
    final numReceivers = numPoolsOf(addressPools);
    // Exact fill to match transaction icon background color
    const addressFillColor = Color(0xFF2E2C2C);
    final t = Theme.of(context);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    // Revert mini button (chip) styling
    // Slightly lighter than field fill, with subtle themed border
    final chipBgColor = Color.lerp(addressFillColor, Colors.black, 0.06) ?? addressFillColor;
    final chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
    // Cursor color aligned with the ZEC balance text color
    final balanceCursorColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () {
              final sc = widget.sendContext;
              if (sc?.fromThread == true && sc?.threadIndex != null) {
                // Pop QuickSend so thread remains static; rely on push from thread
                GoRouter.of(context).pop();
              } else {
                GoRouter.of(context).pop();
              }
            },
            icon: Icon(Icons.arrow_back),
          ),
          title: Builder(builder: (context) {
            final t = Theme.of(context);
            final base = t.appBarTheme.titleTextStyle ??
                t.textTheme.titleLarge ??
                t.textTheme.titleMedium ??
                t.textTheme.bodyMedium;
            final reduced = (base?.fontSize != null)
                ? base!.copyWith(fontSize: base.fontSize! * 0.75)
                : base;
            final title = (widget.sendContext?.isVaultDeposit == true)
                ? 'DEPOSIT'
                : _isVaultWithdrawMode
                    ? 'WITHDRAW'
                    : S.of(context).send.toUpperCase();
            return Text(
              title,
              style: reduced,
            );
          }),
          centerTitle: true,
          actions: const [],
        ),
        body: wrapWithLoading(SingleChildScrollView(
          child: Column(
            children: [
              SyncStatusWidget(),
              Gap(8),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: FormBuilder(
                  key: formKey,
                  child: Column(
                    children: [
                      BalanceWidget(0,
                        balanceOverride: (widget.sendContext?.isVaultDeposit == true)
                            ? balances.sapling : null,
                      ),
                      Gap(24),
                      Gap(8),
                      // Centered, 4% narrower container for label + field
                      Align(
                        alignment: Alignment.center,
                        child: FractionallySizedBox(
                          widthFactor: 0.96, // shrink width by 4%
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                Text(
                                  'Send to',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontFamily: balanceFontFamily),
                                ),
                                const Gap(8),
                                TextField(
                                  controller: _sendToTopController,
                                  onChanged: (v) => _setAddressFromTop(v),
                                  onSubmitted: (v) => _setAddressFromTop(v),
                                  readOnly: (widget.sendContext?.fromThread ?? false) || (widget.sendContext?.isVaultDeposit == true),
                                  cursorColor: balanceCursorColor,
                                  style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
                                    fontFamily: balanceFontFamily,
                                    color: Theme.of(context).colorScheme.onSurface,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: CloakWalletManager.isCloak(aa.coin) ? (_isVaultWithdrawMode ? 'CLOAK or Telos Address' : 'Address, Account, or Vault Hash') : 'Zcash Address',
                                    hintStyle: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
                                        .copyWith(
                                      fontFamily: balanceFontFamily,
                                      fontWeight: FontWeight.w400,
                                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                    ),
                                    filled: true,
                                    fillColor: MaterialStateColor.resolveWith((_) => addressFillColor),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                    errorText: _addressError,
                                    errorStyle: (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
                                        .copyWith(color: Theme.of(context).colorScheme.error),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2),
                                    ),
                                    suffixIcon: (widget.sendContext?.isVaultDeposit == true) ? null : Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _SuffixChip(
                                            icon: SvgPicture.string(
                                              _ZASHI_CONTACT_GLYPH,
                                              width: 32,
                                              height: 32,
                                              colorFilter: ColorFilter.mode(t.colorScheme.onSurface, BlendMode.srcIn),
                                            ),
                                            backgroundColor: chipBgColor,
                                            borderColor: chipBorderColor,
                                            onTap: () async {
                                              if ((widget.sendContext?.fromThread ?? false)) {
                                                // In thread-launched mode, do not change destination
                                                return;
                                              }
                                              final String currentText = _sendToTopController.text.trim();
                                              // If field is empty: open contacts picker
                                              if (currentText.isEmpty) {
                                                final picked = await GoRouter.of(context).push('/contacts_overlay/pick');
                                                if (picked is Contact) {
                                                  final t = picked.unpack();
                                                  final addr = (t.address ?? '').trim();
                                                  final name = (t.name ?? '').trim();
                                                  if (addr.isNotEmpty) {
                                                    _address = addr;
                                                    _sendToTopController.text = name.isNotEmpty ? name : addr;
                                                    _didUpdateAddress(_address);
                                                    _cancelAddContactHint();
                                                  }
                                                }
                                                return;
                                              }
                                              // If field has something, check if it's a valid address
                                              final String asEntered = currentText;
                                              String candidate = asEntered;
                                              bool parsedTex = false;
                                              bool isValidAddr = false;
                                              if (CloakWalletManager.isCloak(aa.coin)) {
                                                // CLOAK address validation
                                                isValidAddr = _isValidCloakAddress(candidate);
                                              } else {
                                                // Non-CLOAK address validation not supported
                                                isValidAddr = false;
                                              }
                                              if (isValidAddr) {
                                                // Check if address matches an existing contact
                                                String? existingName;
                                                try {
                                                  for (final c in contacts.contacts) {
                                                    final t = c.unpack();
                                                    final ad = (t.address ?? '').trim();
                                                    if (ad == candidate) { existingName = (t.name ?? '').trim(); break; }
                                                  }
                                                } catch (_) {}
                                                if ((existingName ?? '').isNotEmpty) {
                                                  // Show dialog: Contact Exists
                                                  await showDialog<void>(
                                                    context: context,
                                                    builder: (ctx) => AlertDialog(
                                                      title: const Text('Contact Exists'),
                                                      content: const Text('This address is already associated with a contact.'),
                                                      actions: [
                                                        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
                                                      ],
                                                    ),
                                                  );
                                                  // Fill visible field with the contact name; keep underlying address
                                                  _address = candidate;
                                                  _sendToTopController.text = existingName!;
                                                  _didUpdateAddress(_address);
                                                  return;
                                                } else {
                                                  // Not in contacts: open Add Contact prefilled with address
                                                  GoRouter.of(context).push('/contacts/add', extra: candidate);
                                                  return;
                                                }
                                              }
                                              // Otherwise (not a valid address): open picker
                                              final picked2 = await GoRouter.of(context).push('/contacts_overlay/pick');
                                              if (picked2 is Contact) {
                                                final t2 = picked2.unpack();
                                                final addr2 = (t2.address ?? '').trim();
                                                final name2 = (t2.name ?? '').trim();
                                                if (addr2.isNotEmpty) {
                                                  _address = addr2;
                                                  _sendToTopController.text = name2.isNotEmpty ? name2 : addr2;
                                                  _didUpdateAddress(_address);
                                                  _cancelAddContactHint();
                                                }
                                              }
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          _SuffixChip(
                                            icon: SvgPicture.string(
                                              _ZASHI_QR_GLYPH,
                                              width: 32,
                                              height: 32,
                                              colorFilter: ColorFilter.mode(t.colorScheme.onSurface, BlendMode.srcIn),
                                            ),
                                            backgroundColor: chipBgColor,
                                            borderColor: chipBorderColor,
                                            onTap: () async {
                                              if ((widget.sendContext?.fromThread ?? false)) {
                                                return;
                                              }
                                              final text = await scanQRCode(context, validator: addressValidator);
                                              _setAddressFromTop(text);
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (CloakWalletManager.isCloak(aa.coin)) ...[
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      'Accepts CLOAK address, Telos account, or vault hash',
                                      style: (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
                                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                      ),
                                    ),
                                  ),
                                ],
                                const Gap(8),
                                // Helper is overlayed instead of inline (see Positioned overlay below)
                                const SizedBox(height: 0),
                                const Gap(12),
                                // Asset picker (CLOAK only — Zcash has single asset)
                                if (CloakWalletManager.isCloak(aa.coin) && (_selectedToken != null || _selectedNft != null)) ...[
                                  Text(
                                    'Asset',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontFamily: balanceFontFamily),
                                  ),
                                  const Gap(8),
                                  Material(
                                    color: addressFillColor,
                                    borderRadius: BorderRadius.circular(14),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () => _showSendAssetSheet(context),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        child: _isNftMode
                                          ? Column(
                                              children: [
                                                // NFT card preview
                                                Container(
                                                  width: double.infinity,
                                                  height: 180,
                                                  decoration: BoxDecoration(
                                                    borderRadius: BorderRadius.circular(12),
                                                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                                                  ),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(12),
                                                    child: Stack(
                                                      fit: StackFit.expand,
                                                      children: [
                                                        Container(
                                                          color: const Color(0xFF1C1C1E),
                                                          child: NftImageWidget(imageUrl: _selectedNft!.imageUrl, assetId: _selectedNft!.nftId, alignment: Alignment.topCenter),
                                                        ),
                                                        // Bottom gradient with name + contract
                                                        Positioned(
                                                          left: 0, right: 0, bottom: 0,
                                                          child: Container(
                                                            padding: const EdgeInsets.fromLTRB(12, 24, 12, 10),
                                                            decoration: BoxDecoration(
                                                              gradient: LinearGradient(
                                                                begin: Alignment.topCenter,
                                                                end: Alignment.bottomCenter,
                                                                colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                                                              ),
                                                            ),
                                                            child: Row(
                                                              children: [
                                                                Expanded(
                                                                  child: Column(
                                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                                    children: [
                                                                      Text(
                                                                        _selectedNft!.name ?? 'NFT #${_selectedNft!.nftId}',
                                                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                                                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                                                      ),
                                                                      const SizedBox(height: 2),
                                                                      Text(
                                                                        _selectedNft!.contract,
                                                                        style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                                Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.5), size: 20),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Row(
                                              children: [
                                                _SendTokenIcon(
                                                  logoUrl: _selectedToken!.logoUrl,
                                                  symbol: _selectedToken!.symbol,
                                                  size: 32,
                                                  fallbackColor: _getSendTokenColor(_selectedToken!.symbol),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        _selectedToken!.symbol,
                                                        style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
                                                          fontFamily: balanceFontFamily,
                                                          fontWeight: FontWeight.w600,
                                                          color: Theme.of(context).colorScheme.onSurface,
                                                        ),
                                                      ),
                                                      Text(
                                                        '${_selectedToken!.amount} available',
                                                        style: (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
                                                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                                              ],
                                            ),
                                      ),
                                    ),
                                  ),
                                  const Gap(12),
                                ],
                                // Amount section (hidden in NFT mode — NFTs are indivisible, qty=1)
                                if (!_isNftMode) ...[
                                Text(
                                  'Amount',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontFamily: balanceFontFamily),
                                ),
                                const Gap(8),
                                ZashiAmountRow(
                                  initialAmount: _amount.value,
                                  fiatCode: appSettings.currency,
                                  availableZatoshis: spendable,
                                  tokenSymbol: _selectedToken?.symbol ?? 'CLOAK',
                                  showFiat: _isCloakSelected,
                                  tokenPrecision: _selectedToken?.precision ?? 4,
                                  onAmountChanged: (int value) {
                                    setState(() {
                                      _amount = Amount(value, _amount.deductFee);
                                      if (value > 0 && (_address.isEmpty)) {
                                        _addressError = CloakWalletManager.isCloak(aa.coin) ? 'Enter address, account, or vault hash' : 'Enter Zcash Address';
                                      } else if (value == 0 && _address.isEmpty) {
                                        _addressError = null;
                                      }
                                    });
                                  },
                                ),
                                ],
                              ],
                              ),
                              if (_showAddContactHelp)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 62,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Color.lerp(addressFillColor, Colors.white, 0.08),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.center,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          SvgPicture.string(
                                            _ZASHI_CONTACT_GLYPH,
                                            width: 40,
                                            height: 40,
                                            colorFilter: ColorFilter.mode(Theme.of(context).colorScheme.onSurface, BlendMode.srcIn),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Add contact by tapping on the contact icon.',
                                            maxLines: 1,
                                            softWrap: false,
                                            style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
                                              fontFamily: balanceFontFamily,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const Gap(12),
                      if (isShielded && customSendSettings.memo)
                        Align(
                          alignment: Alignment.center,
                          child: FractionallySizedBox(
                            widthFactor: 0.96,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Message',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontFamily: balanceFontFamily),
                                ),
                                const Gap(8),
                                InputMemo(
                                  _memo,
                                  key: memoKey,
                                  onChanged: (v) => _memo = v!,
                                  custom: custom,
                                ),
                                // Removed extra reply-to UA display per request
                              ],
                            ),
                          ),
                        ),
                      if (numReceivers > 1 &&
                          custom &&
                          customSendSettings.recipientPools)
                        FieldUA(rp,
                            name: 'recipient_pools',
                            label: S.of(context).receivers,
                            onChanged: (v) => setState(() => rp = v!),
                            radio: false,
                            pools: addressPools),
                      Gap(8),
                      if (widget.single &&
                          custom &&
                          customSendSettings.pools &&
                          !isTex)
                        PoolSelection(
                          _pools,
                          key: poolKey,
                          balances: aa.poolBalances,
                          onChanged: (v) => setState(() => _pools = v!),
                        ),
                      Gap(8),
                      // AmountPicker removed
                      Gap(8),
                      const Gap(12),
                      if (_addressIsValid && (_isNftMode || (_amount.value > 0 && _amount.value <= spendable)) && (CloakWalletManager.isCloak(aa.coin) || appStore.proverReady))
                        Align(
                          alignment: Alignment.center,
                          child: FractionallySizedBox(
                            widthFactor: 0.96,
                            child: SizedBox(
                              height: 48,
                              child: Material(
                                color: balanceCursorColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: send,
                                  child: Center(
                                    child: Text(
                                      _isVaultWithdrawMode ? 'Review Withdrawal' : 'Review',
                                      style: (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
                                        fontFamily: balanceFontFamily,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context).colorScheme.background,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Vault fee explanation — hidden when Review button is showing
                      if (_isVaultWithdrawMode && CloakWalletManager.isCloak(aa.coin) && !(_addressIsValid && (_isNftMode || (_amount.value > 0 && _amount.value <= spendable))))
                        Padding(
                          padding: const EdgeInsets.only(top: 16, left: 20, right: 20),
                          child: Text(
                            'The withdrawal amount comes from your vault. The network fee is paid from your wallet\'s shielded CLOAK balance.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45),
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      // Vault deposit fee explanation — hidden when Review button is showing
                      if (widget.sendContext?.isVaultDeposit == true && CloakWalletManager.isCloak(aa.coin) && !(_addressIsValid && (_isNftMode || (_amount.value > 0 && _amount.value <= spendable))))
                        Padding(
                          padding: const EdgeInsets.only(top: 16, left: 20, right: 20),
                          child: Text(
                            'The deposit amount and network fee are both paid from your wallet\'s shielded CLOAK balance.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45),
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      if (_addressIsValid && !_isNftMode && _amount.value > 0 && _amount.value <= spendable && !CloakWalletManager.isCloak(aa.coin) && !appStore.proverReady)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(width: 8),
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF4B728)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text('Preparing prover…', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        )));
  }

  send() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      form.save();
      logger.d(
          'send $_address $rp $_amount $_pools ${_memo.reply} ${_memo.subject} ${_memo.memo}');
      // Preserve thread context (fromThread/threadIndex/threadCid/display) if present
      final prev = widget.sendContext;
      final sc = SendContext(
        _address,
        _pools,
        _isNftMode ? Amount(1, false) : _amount,
        _memo,
        marketPrice.price,
        prev?.display,
        prev?.fromThread ?? false,
        prev?.threadIndex,
        prev?.threadCid,
        _isNftMode ? null : (_isVaultWithdrawMode ? 'CLOAK' : _selectedToken?.symbol),
        _isNftMode ? null : (_isVaultWithdrawMode ? 'thezeostoken' : _selectedToken?.contract),
        _isNftMode ? null : (_isVaultWithdrawMode ? 4 : _selectedToken?.precision),
        _isVaultWithdrawMode ? activeVaultHash : null,
        _selectedNft?.nftId,
        _selectedNft?.contract,
        _selectedNft?.imageUrl,
        _selectedNft?.name,
        prev?.isBatchWithdraw ?? false,
        prev?.batchAssets,
        prev?.isVaultDeposit ?? false,
      );
      SendContext.instance = sc;
      // Prepare memo with potential hidden header before assembling recipient
      MemoData effectiveMemo = _memo;
      try {
        final scExtra = widget.sendContext;
        if (scExtra?.fromThread == true) {
          String? cid = scExtra?.threadCid;
          if (cid == null || cid.isEmpty) {
            try { cid = await CloakDb.getProperty('contact_cid_' + aa.id.toString()) ?? ''; } catch (_) {}
          }
          if (cid != null && cid.isNotEmpty) {
            int mySeq = 1;
            try {
              final s0 = (await CloakDb.getProperty('cid_my_seq_' + cid) ?? '').trim();
              final v0 = int.tryParse(s0);
              mySeq = (v0 != null && v0 > 0) ? (v0 + 1) : 1;
            } catch (_) { mySeq = 1; }
            try { await CloakDb.setProperty('cid_my_seq_' + cid, mySeq.toString()); } catch (_) {}
            final amt = _amount.value;
            String header = 'v1; type=payment; conversation_id=' + cid + '; seq=' + mySeq.toString() + (amt > 0 ? '; amount_zat=' + amt.toString() : '');
            final bodyOnly = (effectiveMemo.memo).trim();
            effectiveMemo = MemoData(effectiveMemo.reply, effectiveMemo.subject, header + '\n\n' + bodyOnly);
          }
        }
      } catch (_) {}
      // CLOAK uses different transaction flow
      if (CloakWalletManager.isCloak(aa.coin)) {
        if (widget.single) {
          // For vault withdrawals, clear memo for privacy (no on-chain data leakage)
          if (_isVaultWithdrawMode) {
            effectiveMemo = MemoData(false, '', '');
          }
          // Update SendContext with effective memo (includes thread header if applicable)
          SendContext.instance = SendContext(
            _address,
            _pools,
            _isNftMode ? Amount(1, false) : _amount,
            effectiveMemo,
            marketPrice.price,
            prev?.display,
            prev?.fromThread ?? false,
            prev?.threadIndex,
            prev?.threadCid,
            _isNftMode ? null : (_isVaultWithdrawMode ? 'CLOAK' : _selectedToken?.symbol),
            _isNftMode ? null : (_isVaultWithdrawMode ? 'thezeostoken' : _selectedToken?.contract),
            _isNftMode ? null : (_isVaultWithdrawMode ? 4 : _selectedToken?.precision),
            _isVaultWithdrawMode ? activeVaultHash : null,
            _selectedNft?.nftId,
            _selectedNft?.contract,
            _selectedNft?.imageUrl,
            _selectedNft?.name,
            prev?.isBatchWithdraw ?? false,
            prev?.batchAssets,
            prev?.isVaultDeposit ?? false,
          );
          // Invalidate fee cache so confirm page fetches fresh from chain
          CloakWalletManager.invalidateShieldFeeCache();
          // Navigate to CLOAK confirmation/review page
          GoRouter.of(context).go('/account/cloak_confirm');
        } else {
          // For multi-recipient, just return the address info
          GoRouter.of(context).pop({'address': _address, 'amount': _amount.value});
        }
      } else {
        // Non-CLOAK transaction flow no longer supported
        showMessageBox2(context, S.of(context).error, 'Only CLOAK transactions are supported');
      }
    }
  }

  _onAddress(String? v) {
    if (v == null) return;

    // CLOAK doesn't use Zcash-style payment URIs
    if (CloakWalletManager.isCloak(aa.coin)) {
      _address = v;
      _didUpdateAddress(v);
      setState(() {});
      return;
    }

    // Non-CLOAK: treat as plain address
    _address = v;
    _didUpdateAddress(v);
    setState(() {});
  }

  void _didUpdateSendContext(SendContext? sendContext) {
    if (sendContext == null) return;
    _address = sendContext.address; // real underlying address
    _pools = sendContext.pools;
    _amount = sendContext.amount;
    _memo = sendContext.memo ??
        MemoData(appSettings.includeReplyTo != 0, '', '');
    // Show display text if provided (e.g., contact name), otherwise show the address
    _sendToTopController.text = (sendContext.display?.isNotEmpty ?? false)
        ? sendContext.display!
        : sendContext.address;
    memoKey.currentState?.setMemoBody(_memo.memo);
    // If launched from a thread and we will inject a payment header, pre-reserve bytes in the counter
    if (sendContext.fromThread == true) {
      final cid = (sendContext.threadCid ?? '').trim();
      final int amt = _amount.value;
      // Rough header: v1; type=payment; conversation_id=<cid>; seq=<nn>[; amount_zat=<amt>]\n\n
      // We don’t know seq yet; reserve up to 10 chars for seq and 2 for key/punct.
      final headerFixed = 'v1; type=payment; conversation_id=${cid}; '.length + '\n\n'.length;
      final amountPart = (amt > 0) ? ('; amount_zat=${amt}'.length) : 0;
      // conservative reservation: 12 chars for seq/in_reply_to punctuation and value
      final reserved = headerFixed + amountPart + 12;
      memoKey.currentState?.setReservedBytes(reserved.clamp(0, 512));
    } else {
      memoKey.currentState?.setReservedBytes(0);
    }
    _didUpdateAddress(_address);
    // Pre-select token if sendContext carries token fields
    if (sendContext.tokenSymbol != null && sendContext.tokenContract != null) {
      final matchIdx = _shieldedTokens.indexWhere(
        (t) => t.symbol == sendContext.tokenSymbol && t.contract == sendContext.tokenContract,
      );
      if (matchIdx >= 0) {
        setState(() {
          _selectedToken = _shieldedTokens[matchIdx];
          _selectedNft = null;
        });
      }
    }
    // Pre-select NFT if sendContext carries NFT fields
    if (sendContext.nftId != null && sendContext.nftContract != null) {
      final matchIdx = _shieldedNfts.indexWhere(
        (n) => n.nftId == sendContext.nftId && n.contract == sendContext.nftContract,
      );
      setState(() {
        if (matchIdx >= 0) {
          _selectedNft = _shieldedNfts[matchIdx];
        } else {
          // NFT not in parsed list (e.g. metadata not yet cached) — create stub
          _selectedNft = _SendNft(
            nftId: sendContext.nftId!,
            contract: sendContext.nftContract!,
            imageUrl: sendContext.nftImageUrl,
            name: sendContext.nftName,
          );
        }
        _selectedToken = null;
        _amount = Amount(1, false);
      });
    }
  }

  _didUpdateAddress(String? address) {
    if (address == null) return;
    isTex = false;
    var address2 = address;

    // CLOAK uses different address format
    if (CloakWalletManager.isCloak(aa.coin)) {
      final validAddr = _isValidCloakAddress(address);
      isShielded = _isCloakShieldedAddress(address);
      addressPools = validAddr ? (isShielded ? 2 : 1) : 0;
      rp = addressPools;

      final bool fromThread = widget.sendContext?.fromThread ?? false;
      if (address.isEmpty) {
        _addressIsValid = false;
        _cancelAddContactHint();
        _addressError = fromThread ? null : (_amount.value > 0 ? 'Enter address, account, or vault hash' : null);
      } else {
        if (fromThread) {
          _addressError = null;
          _addressIsValid = validAddr;
        } else {
          _addressError = validAddr ? null : S.of(context).invalidAddress;
          _addressIsValid = validAddr;
        }
        if (_addressIsValid) _showAddContactHint();
      }
      return;
    }

    // Non-CLOAK address handling (stub)
    final bool fromThread = widget.sendContext?.fromThread ?? false;
    if (address.isEmpty) {
      _addressIsValid = false;
      _cancelAddContactHint();
      _addressError = fromThread ? null : 'Enter address';
    } else {
      _addressError = null;
      _addressIsValid = false; // Non-CLOAK addresses not validated
    }
    _contactReplyToUA = null;
  }

  void _showAddContactHint() {
    // Suppress hint when launched from an existing thread with prefilled recipient
    final bool fromThread = widget.sendContext?.fromThread ?? false;
    if (fromThread || widget.sendContext?.isVaultDeposit == true) {
      _cancelAddContactHint();
      setState(() => _showAddContactHelp = false);
      return;
    }
    _cancelAddContactHint();
    setState(() => _showAddContactHelp = true);
    _addContactTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      setState(() => _showAddContactHelp = false);
    });
  }

  void _cancelAddContactHint() {
    _addContactTimer?.cancel();
    _addContactTimer = null;
    if (_showAddContactHelp) setState(() => _showAddContactHelp = false);
  }

  void _showSendAssetSheet(BuildContext context) {
    // Refresh token/NFT lists before showing sheet
    if (_isVaultWithdrawMode) {
      _shieldedTokens = _parseVaultTokens();
      _shieldedNfts = _parseVaultNfts();
    } else {
      _shieldedTokens = _parseShieldedTokens();
      _shieldedNfts = _parseShieldedNfts();
    }
    // Start on the tab matching current selection
    int sheetTab = _isNftMode ? 1 : 0;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final t = Theme.of(ctx);
            final zashi = t.extension<ZashiThemeExt>();
            final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
            final selectedColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
            final unselectedColor = t.colorScheme.onSurface.withOpacity(0.5);
            final gradTop = zashi?.quickGradTop ?? t.colorScheme.onSurface.withOpacity(0.12);
            final gradBottom = zashi?.quickGradBottom ?? t.colorScheme.onSurface.withOpacity(0.08);
            final indicatorBorder = zashi?.quickBorderColor ?? t.dividerColor;
            final isDark = t.brightness == Brightness.dark;
            final hasNfts = _shieldedNfts.isNotEmpty;

            // ── Tokens list ──
            Widget buildTokensList() {
              if (_shieldedTokens.isEmpty) {
                return Padding(
                  key: const ValueKey('tokens_empty'),
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('No shielded tokens', style: t.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                  ),
                );
              }
              return Column(
                key: const ValueKey('tokens_list'),
                mainAxisSize: MainAxisSize.min,
                children: List.generate(_shieldedTokens.length, (i) {
                  final token = _shieldedTokens[i];
                  final isSelected = !_isNftMode && _selectedToken?.symbol == token.symbol && _selectedToken?.contract == token.contract;
                  return Material(
                    color: isSelected ? Colors.white.withOpacity(0.06) : Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _selectedToken = token;
                          _selectedNft = null;
                          _amount = Amount(0, _amount.deductFee);
                        });
                        Navigator.of(ctx).pop();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(
                          children: [
                            _SendTokenIcon(
                              logoUrl: token.logoUrl,
                              symbol: token.symbol,
                              size: 40,
                              fallbackColor: _getSendTokenColor(token.symbol),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    token.symbol,
                                    style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    token.contract,
                                    style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${token.amount} ${token.symbol}',
                              style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle, size: 20, color: Colors.greenAccent),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              );
            }

            // ── NFT card builder ──
            Widget _buildSendNftCard(BuildContext ctx, ThemeData t, dynamic nft) {
              final isSelected = _isNftMode && _selectedNft?.nftId == nft.nftId && _selectedNft?.contract == nft.contract;
              return AspectRatio(
                aspectRatio: 1.0,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedNft = nft;
                      _selectedToken = null;
                      _amount = Amount(1, false);
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: isSelected
                        ? Border.all(color: Colors.greenAccent, width: 2)
                        : Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(isSelected ? 10 : 12),
                      child: Container(
                        color: t.colorScheme.onSurface.withOpacity(0.06),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            NftImageWidget(imageUrl: nft.imageUrl, assetId: nft.nftId),
                            if (isSelected)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.greenAccent,
                                  ),
                                  child: const Icon(Icons.check, size: 14, color: Colors.black),
                                ),
                              ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                                  ),
                                ),
                                padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      nft.name ?? 'NFT #${nft.nftId.length > 8 ? '${nft.nftId.substring(0, 8)}…' : nft.nftId}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                                    ),
                                    Text(
                                      nft.contract,
                                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10),
                                    ),
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

            // ── NFTs grid ──
            Widget buildNftsGrid() {
              if (_shieldedNfts.isEmpty) {
                return Padding(
                  key: const ValueKey('nfts_empty'),
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.diamond_outlined, size: 40, color: Colors.grey.shade700),
                        const SizedBox(height: 8),
                        Text('No NFTs', style: t.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                      ],
                    ),
                  ),
                );
              }
              return Padding(
                key: const ValueKey('nfts_grid'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    for (int i = 0; i < _shieldedNfts.length; i += 2) ...[
                      if (i > 0) const SizedBox(height: 10),
                      Row(
                        children: [
                          for (int j = i; j < i + 2; j++) ...[
                            if (j > i) const SizedBox(width: 10),
                            Expanded(
                              child: j < _shieldedNfts.length
                                ? _buildSendNftCard(ctx, t, _shieldedNfts[j])
                                : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: [
                  // ── Handle ──
                  const Gap(12),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade600,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const Gap(16),
                  // ── Title ──
                  Text(
                    'Select Asset',
                    style: t.textTheme.titleSmall?.copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Gap(16),
                  // ── Segmented Toggle ──
                  if (hasNfts)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        height: 36,
                        decoration: BoxDecoration(
                          color: t.colorScheme.onSurface.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            const tabCount = 2;
                            final segWidth = constraints.maxWidth / tabCount;
                            final labels = ['Tokens', 'NFTs'];
                            return Stack(
                              children: [
                                // Sliding indicator
                                AnimatedPositioned(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOutCubic,
                                  left: sheetTab * segWidth,
                                  top: 0,
                                  bottom: 0,
                                  width: segWidth,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [gradTop, gradBottom],
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: indicatorBorder),
                                    ),
                                  ),
                                ),
                                // Labels
                                Row(
                                  children: List.generate(tabCount, (i) => Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => setSheetState(() => sheetTab = i),
                                      child: Center(
                                        child: Text(
                                          labels[i],
                                          style: TextStyle(
                                            color: sheetTab == i ? selectedColor : unselectedColor,
                                            fontWeight: sheetTab == i ? FontWeight.w700 : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  const Gap(12),
                  // ── Content area ──
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        );
                      },
                      child: ColoredBox(
                        key: ValueKey(sheetTab),
                        color: const Color(0xFF1A1A1A),
                        child: SingleChildScrollView(
                          child: sheetTab == 0
                              ? buildTokensList()
                              : buildNftsGrid(),
                        ),
                      ),
                    ),
                  ),
                  const Gap(8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  _toggleCustom() {
    setState(() => custom = !custom);
  }

  void _setAddressFromTop(String v) {
    _sendToTopController.text = v;
    _onAddress(v);
  }
}

class _SuffixChip extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;
  final Color backgroundColor;
  final Color borderColor;

  const _SuffixChip({
    required this.icon,
    required this.onTap,
    required this.backgroundColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: borderColor)),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: icon,
          ),
        ),
      ),
    );
  }
}

class _SendTokenIcon extends StatefulWidget {
  final String? logoUrl;
  final String symbol;
  final double size;
  final Color fallbackColor;

  const _SendTokenIcon({
    this.logoUrl,
    required this.symbol,
    required this.size,
    required this.fallbackColor,
  });

  @override
  State<_SendTokenIcon> createState() => _SendTokenIconState();
}

class _SendTokenIconState extends State<_SendTokenIcon> {
  bool _imageLoadFailed = false;

  bool get _hasImage => widget.logoUrl != null && widget.logoUrl!.isNotEmpty && !_imageLoadFailed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: _hasImage
            ? Border.all(color: const Color(0x33FFFFFF), width: 0.5)
            : null,
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _hasImage ? Colors.transparent : widget.fallbackColor,
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildImage(),
      ),
    );
  }

  Widget _buildImage() {
    if (widget.logoUrl == null || widget.logoUrl!.isEmpty) {
      return _buildFallback();
    }
    if (widget.logoUrl!.startsWith('asset:')) {
      final assetPath = widget.logoUrl!.substring(6);
      return Image.asset(
        assetPath,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _imageLoadFailed = true);
          });
          return _buildFallback();
        },
      );
    }
    return Image.network(
      widget.logoUrl!,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _imageLoadFailed = true);
        });
        return _buildFallback();
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildFallback() {
    return Container(
      color: widget.fallbackColor,
      child: Center(
        child: Text(
          widget.symbol.isNotEmpty ? widget.symbol[0] : '?',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: widget.size * 0.45,
          ),
        ),
      ),
    );
  }
}

class ZashiAmountRow extends StatefulWidget {
  final int initialAmount;
  final String fiatCode;
  final ValueChanged<int> onAmountChanged;
  final int availableZatoshis;
  final String tokenSymbol;   // e.g. 'CLOAK', 'USDT' — drives hint text
  final bool showFiat;        // false hides fiat column entirely
  final int tokenPrecision;   // decimal places for the token

  const ZashiAmountRow({super.key, required this.initialAmount, required this.fiatCode, required this.availableZatoshis, required this.onAmountChanged, this.tokenSymbol = 'CLOAK', this.showFiat = true, this.tokenPrecision = 4});

  @override
  State<ZashiAmountRow> createState() => _ZashiAmountRowState();
}

class _ZashiAmountRowState extends State<ZashiAmountRow> {
  final TextEditingController _zecCtl = TextEditingController();
  final TextEditingController _fiatCtl = TextEditingController();
  double? _fxRate;
  // CLOAK uses 4 decimal places (10000 units = 1.0 CLOAK), ZEC uses 8 (100000000 = 1.0 ZEC)
  final bool _isCloak = CloakWalletManager.isCloak(aa.coin);
  late int _unitScale;
  late int _decimals;
  late NumberFormat _zecFmt;
  late String _currentTokenSymbol;
  late int _currentTokenPrecision;
  late final NumberFormat _fiatFmt = NumberFormat.decimalPatternDigits(locale: Platform.localeName, decimalDigits: 2);
  /// Dynamic fiat formatting for tiny CLOAK prices (avoids showing $0.00)
  String _formatFiatDynamic(double x) {
    final abs = x.abs();
    if (abs == 0 || abs >= 0.01) return _fiatFmt.format(x);
    int digits = 2;
    double threshold = 0.01;
    while (threshold > abs && digits < 8) { digits++; threshold /= 10; }
    digits++;
    if (digits > 8) digits = 8;
    return NumberFormat.decimalPatternDigits(locale: Platform.localeName, decimalDigits: digits).format(x);
  }
  bool _updating = false;
  bool _userEditing = false; // true while user is typing → skip didUpdateWidget reformat
  bool _syncing = false;
  bool _insufficient = false;

  @override
  void initState() {
    super.initState();
    _currentTokenSymbol = widget.tokenSymbol;
    _currentTokenPrecision = _isCloak ? widget.tokenPrecision : 8;
    _unitScale = _isCloak ? pow(10, _currentTokenPrecision).toInt() : 100000000;
    _decimals = _isCloak ? _currentTokenPrecision : decimalDigits(appSettings.fullPrec);
    _zecFmt = NumberFormat.decimalPatternDigits(locale: Platform.localeName, decimalDigits: _decimals);
    if (widget.initialAmount > 0) {
      _zecCtl.text = _isCloak
          ? decimalToStringTrim(widget.initialAmount / _unitScale.toDouble())
          : amountToStringDynamic(widget.initialAmount);
    } else {
      _zecCtl.text = '';
    }
    _fiatCtl.text = '';
    _updateFx();
    // Kick off a quick background refresh so the USD field is fresh on first load
    // and never sits indefinitely on "Syncing...".
    // If it fails or times out, we fall back to "Tap to Sync...".
    Future.microtask(_bootstrapPrice);
  }

  @override
  void didUpdateWidget(ZashiAmountRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Token changed — recalculate scale/format and clear fields
    if (widget.tokenSymbol != _currentTokenSymbol || widget.tokenPrecision != _currentTokenPrecision) {
      _currentTokenSymbol = widget.tokenSymbol;
      _currentTokenPrecision = _isCloak ? widget.tokenPrecision : 8;
      _unitScale = _isCloak ? pow(10, _currentTokenPrecision).toInt() : 100000000;
      _decimals = _isCloak ? _currentTokenPrecision : decimalDigits(appSettings.fullPrec);
      _zecFmt = NumberFormat.decimalPatternDigits(locale: Platform.localeName, decimalDigits: _decimals);
      _zecCtl.text = '';
      _fiatCtl.text = '';
      _insufficient = false;
      return;
    }
    // Skip reformat when the change came from user typing (onChanged → onAmountChanged → rebuild)
    if (_userEditing) return;
    // Update ZEC field if initialAmount changes (e.g., Max button, external set)
    if (widget.initialAmount != oldWidget.initialAmount) {
      if (widget.initialAmount > 0) {
        _zecCtl.text = _isCloak
            ? decimalToStringTrim(widget.initialAmount / _unitScale.toDouble())
            : amountToStringDynamic(widget.initialAmount);
        _syncFiatFromZec();
      } else {
        _zecCtl.text = '';
        _fiatCtl.text = '';
      }
    }
  }

  Future<void> _updateFx() async {
    // Prefer the store's last fetched price to avoid a second network call
    final cached = marketPrice.price;
    if (cached != null) {
      if (!mounted) return;
      setState(() => _fxRate = cached);
      _syncFiatFromZec();
      return;
    }
    final c = coins[aa.coin];
    final fx = await getFxRate(c.currency, widget.fiatCode);
    if (!mounted) return;
    setState(() => _fxRate = fx);
    _syncFiatFromZec();
  }

  bool _isFreshNow() {
    final ts = marketPrice.timestamp;
    return ts != null && DateTime.now().difference(ts).inSeconds <= 120;
  }

  Future<void> _triggerSyncAndFx() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await marketPrice.update().timeout(const Duration(seconds: 8));
      // Use updated store price immediately
      if (mounted) setState(() => _fxRate = marketPrice.price);
      _syncFiatFromZec();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _bootstrapPrice() async {
    if (_syncing) return;
    // Seed from any cached value first, so UI can display USD quickly
    if (marketPrice.price != null && mounted) {
      setState(() => _fxRate = marketPrice.price);
      _syncFiatFromZec();
    }
    setState(() => _syncing = true);
    try {
      await marketPrice.update().timeout(const Duration(seconds: 4));
      if (mounted) setState(() => _fxRate = marketPrice.price);
      _syncFiatFromZec();
    } catch (_) {
      // ignore; UI will show Tap to Sync... if still stale
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _syncFiatFromZec() {
    if (_fxRate == null) return;
    try {
      final raw = _zecCtl.text.trim();
      _updating = true;
      if (raw.isEmpty) {
        _fiatCtl.text = '';
        _insufficient = false;
      } else {
        final z = _zecFmt.parse(raw).toDouble();
        final fiat = z * _fxRate!;
        _fiatCtl.text = _isCloak ? _formatFiatDynamic(fiat) : _fiatFmt.format(fiat);
        final valueZats = (z * _unitScale).round();
        _insufficient = valueZats > widget.availableZatoshis;
      }
    } catch (_) {
      _fiatCtl.text = '';
      _insufficient = false;
    }
    _updating = false;
  }

  void _syncZecFromFiat() {
    if (_fxRate == null) return;
    try {
      final raw = _fiatCtl.text.trim();
      _updating = true;
      if (raw.isEmpty) {
        _zecCtl.text = '';
        _insufficient = false;
      } else {
        final f = _fiatFmt.parse(raw).toDouble();
        final int valueZats = ((f * _unitScale) / _fxRate!).round();
        _zecCtl.text = decimalToStringTrim(valueZats / _unitScale.toDouble());
        _insufficient = valueZats > widget.availableZatoshis;
      }
    } catch (_) {
      _zecCtl.text = '';
      _insufficient = false;
    }
    _updating = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final addressFillColor = const Color(0xFF2E2C2C);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final balanceTextColor = t.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    // Container background is removed; we use TextField filled decoration to match the address field
    final boxDecoration = BoxDecoration(borderRadius: BorderRadius.circular(14));
    // Crypto-only TextField (shared between fiat and no-fiat layouts)
    final cryptoField = Theme(
      data: t.copyWith(
        textSelectionTheme: TextSelectionThemeData(
          selectionColor: Colors.transparent,
          selectionHandleColor: t.colorScheme.onSurface,
        ),
      ),
      child: TextField(
        controller: _zecCtl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        textAlignVertical: TextAlignVertical.center,
        cursorColor: balanceTextColor,
        style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontFamily: balanceFontFamily,
          color: balanceTextColor,
        ),
        decoration: InputDecoration(
          filled: true,
          fillColor: addressFillColor,
          hintText: _isCloak ? _currentTokenSymbol : 'ZEC',
          hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontFamily: balanceFontFamily,
            fontWeight: FontWeight.w400,
            color: balanceTextColor.withOpacity(0.7),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
          ),
          errorText: _insufficient ? 'Insufficient funds' : null,
          errorStyle: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(color: Theme.of(context).colorScheme.error),
        ),
        onChanged: (_) {
          if (_updating) return;
          _userEditing = true;
          if (widget.showFiat) _syncFiatFromZec();
          final txt = _zecCtl.text.trim();
          final z = txt.isEmpty ? 0.0 : _zecFmt.parse(txt).toDouble();
          final value = (z * _unitScale).round();
          _insufficient = value > widget.availableZatoshis;
          widget.onAmountChanged(value);
          _userEditing = false;
        },
      ),
    );

    // When fiat is hidden, just show the crypto field full-width
    if (!widget.showFiat) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cryptoField,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // ZEC box
            Expanded(child: cryptoField),
            const SizedBox(width: 8),
            // arrows (placeholder two arrows)
            Column(
              children: const [
                Icon(Icons.keyboard_double_arrow_right, size: 18),
                Icon(Icons.keyboard_double_arrow_left, size: 18),
              ],
            ),
            const SizedBox(width: 8),
            // Fiat box
            Expanded(
              child: Observer(builder: (_) {
                // Gate USD input by FX availability, freshness (<= 2m), and not currently syncing
                final bool isFresh = _isFreshNow();
                final bool usdEnabled = _fxRate != null && isFresh && !_syncing;
                final String hint = _syncing
                    ? 'Syncing...'
                    : (!usdEnabled ? 'Tap to Sync...' : widget.fiatCode);
                return Theme(
                  data: t.copyWith(
                    textSelectionTheme: TextSelectionThemeData(
                      selectionColor: Colors.transparent,
                      selectionHandleColor: t.colorScheme.onSurface,
                    ),
                  ),
                  child: Stack(
                    children: [
                      TextField(
                        controller: _fiatCtl,
                        enabled: usdEnabled,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                        ],
                        textAlignVertical: TextAlignVertical.center,
                        cursorColor: balanceTextColor,
                        style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                          fontFamily: balanceFontFamily,
                          color: balanceTextColor,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: addressFillColor,
                          hintText: hint,
                          hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w400,
                            color: balanceTextColor.withOpacity(0.7),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
                          ),
                          disabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: _insufficient ? BorderSide(color: Theme.of(context).colorScheme.error, width: 1.2) : BorderSide.none,
                          ),
                          errorText: _insufficient ? 'Insufficient funds' : null,
                          errorStyle: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(color: Theme.of(context).colorScheme.error),
                        ),
                        onChanged: (_) {
                          if (_updating) return;
                          if (_fxRate == null) return;
                          try {
                            final raw = _fiatCtl.text.trim();
                            if (raw.isEmpty) {
                              _zecCtl.text = '';
                              _insufficient = false;
                              widget.onAmountChanged(0);
                            } else {
                              final f = _fiatFmt.parse(raw).toDouble();
                              final int valueZats = ((f * _unitScale) / _fxRate!).round();
                              _zecCtl.text = decimalToStringTrim(valueZats / _unitScale.toDouble());
                              _insufficient = valueZats > widget.availableZatoshis;
                              widget.onAmountChanged(valueZats);
                            }
                          } catch (_) {
                            _zecCtl.text = '';
                            _insufficient = false;
                            widget.onAmountChanged(0);
                          }
                        },
                      ),
                      if (!usdEnabled)
                        Positioned.fill(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: _triggerSyncAndFx,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ],
    );
  }
}

// Exact Zashi glyphs (inside 36x36 viewport). Box is provided by _SuffixChip.
const String _ZASHI_CONTACT_GLYPH =
    '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(0.5,0.5)">\n'
    '    <path d="M10.5 24.667C12.446 22.602 15.089 21.333 18 21.333C20.911 21.333 23.553 22.602 25.5 24.667M21.75 14.25C21.75 16.321 20.071 18 18 18C15.929 18 14.25 16.321 14.25 14.25C14.25 12.179 15.929 10.5 18 10.5C20.071 10.5 21.75 12.179 21.75 14.25Z" stroke="#231F20" stroke-width="1.6" stroke-linecap="square" stroke-linejoin="miter" fill="none"/>\n'
    '  </g>\n'
    '</svg>';

const String _ZASHI_QR_GLYPH =
    '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(0.5,0.5)">\n'
    '    <path d="M13.833 18H18V22.167M10.508 18H10.5M14.675 22.167H14.667M18.008 25.5H18M25.508 18H25.5M10.5 22.167H11.75M20.917 18H22.583M10.5 25.5H14.667M18 9.667V14.667M22.667 25.5H24.167C24.633 25.5 24.867 25.5 25.045 25.409C25.202 25.329 25.329 25.202 25.409 25.045C25.5 24.867 25.5 24.633 25.5 24.167V22.667C25.5 22.2 25.5 21.967 25.409 21.788C25.329 21.632 25.202 21.504 25.045 21.424C24.867 21.333 24.633 21.333 24.167 21.333H22.667C22.2 21.333 21.967 21.333 21.788 21.424C21.632 21.504 21.504 21.632 21.424 21.788C21.333 21.967 21.333 22.2 21.333 22.667V24.167C21.333 24.633 21.333 24.867 21.424 25.045C21.504 25.202 21.632 25.329 21.788 25.409C21.967 25.5 22.2 25.5 22.667 25.5ZM22.667 14.667H24.167C24.633 14.667 24.867 14.667 25.045 14.576C25.202 14.496 25.329 14.368 25.409 14.212C25.5 14.033 25.5 13.8 25.5 13.333V11.833C25.5 11.367 25.5 11.133 25.409 10.955C25.329 10.798 25.202 10.671 25.045 10.591C24.867 10.5 24.633 10.5 24.167 10.5H22.667C22.2 10.5 21.967 10.5 21.788 10.591C21.632 10.671 21.504 10.798 21.424 10.955C21.333 11.133 21.333 11.367 21.333 11.833V13.333C21.333 13.8 21.333 14.033 21.424 14.212C21.504 14.368 21.632 21.504 21.788 21.632C21.967 21.788 22.2 21.967 22.667 21.967ZM11.833 14.667H13.333C13.8 14.667 14.033 14.667 14.212 14.576C14.368 14.496 14.496 14.368 14.576 14.212C14.667 14.033 14.667 13.8 14.667 13.333V11.833C14.667 11.367 14.667 11.133 14.576 10.955C14.496 10.798 14.368 10.671 14.212 10.591C14.033 10.5 13.8 10.5 13.333 10.5H11.833C11.367 10.5 11.133 10.5 10.955 10.591C10.798 10.671 10.671 10.798 10.591 10.955C10.5 11.133 10.5 11.367 10.5 11.833V13.333C10.5 13.8 10.5 14.033 10.591 14.212C10.671 14.368 10.798 14.496 10.955 14.576C11.133 14.667 11.367 14.667 11.833 14.667Z" stroke="#231F20" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter" fill="none"/>\n'
    '  </g>\n'
    '</svg>';
