// ESR (EOSIO Signing Request) Service for CLOAK Shield
// Protocol spec: https://github.com/eosio-eps/EEPs/blob/master/EEPS/eep-7.md
//
// This service creates ESR URLs that open Anchor wallet for transaction signing.
// Uses proper binary serialization via eosdart as per the ESR protocol specification.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:url_launcher/url_launcher.dart';
import 'package:eosdart/eosdart.dart' as eosdart;
import 'package:eosdart_ecc/eosdart_ecc.dart' as ecc;
import 'package:crypto/crypto.dart' as crypto;

/// ESR Protocol Version 2
const int ESR_VERSION = 2;

/// Chain ID aliases (from ESR spec)
const Map<String, int> CHAIN_ALIASES = {
  'aca376f206b8fc25a6ed44dbdc66547c36c6c33e3a119ffbeaef943642f0e906': 1, // EOS Mainnet
  '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11': 2, // Telos Mainnet (NOT 4 - that's CryptoKylin!)
};

/// Service for creating and handling EOSIO Signing Requests (ESR)
class EsrService {
  // Telos Mainnet chain ID
  static const telosChainId = '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11';

  // ESR actor/permission placeholders
  // These are uint64 values that Anchor replaces with the user's account
  static const actorPlaceholder = '............1'; // Placeholder Name value
  static const permissionPlaceholder = '............2';

  // thezeosalias@public private key (published, anyone can use)
  // This key signs the begin/mint/end actions on behalf of the ZEOS protocol
  static const _aliasPrivateKey = '5KUxZHKVvF3mzHbCRAHCPJd4nLBewjnxHkDkG8LzVggX4GtnHn6';

  // Store pre-computed thezeosalias signature for use after Anchor returns
  static String? _lastPresignature;
  static Uint8List? _lastTxBytes;

  /// Create an ESR URL with pre-signed thezeosalias signature
  ///
  /// This is the CORRECT way to handle transactions that require both user's
  /// signature AND thezeosalias@public signature. We:
  /// 1. Fetch current block info from chain
  /// 2. Build the full transaction with all 5 actions
  /// 3. Sign it with thezeosalias@public key (store in _lastPresignature)
  /// 4. Store serialized tx bytes in _lastTxBytes
  /// 5. Create ESR with variant 2 (full transaction), flags=0
  /// 6. Anchor signs and returns the signed tx (does NOT broadcast)
  /// 7. Flutter combines both signatures and broadcasts via push_transaction
  ///
  /// [actions] - List of EOSIO actions
  /// [callback] - Optional callback URL
  ///
  /// Returns ESR URL string (esr://...)
  static Future<String> createSigningRequestWithPresig({
    required List<Map<String, dynamic>> actions,
    String? callback,
  }) async {
    // 1. Fetch chain info for ref_block_num and ref_block_prefix
    final chainInfo = await _fetchChainInfo();
    if (chainInfo == null) {
      throw Exception('Failed to fetch chain info');
    }

    // Calculate ref_block_num and ref_block_prefix from head_block_id
    final headBlockId = chainInfo['head_block_id'] as String;
    final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
    final refBlockPrefix = _reverseHex(headBlockId.substring(16, 24));

    // 2. Build the transaction
    final expiration = DateTime.now().add(const Duration(minutes: 10));
    final transaction = {
      // IMPORTANT: Add 'Z' suffix to indicate UTC, otherwise DateTime.parse treats it as local time
      'expiration': '${expiration.toUtc().toIso8601String().split('.')[0]}Z',
      'ref_block_num': refBlockNum,
      'ref_block_prefix': refBlockPrefix,
      'max_net_usage_words': 0,
      'max_cpu_usage_ms': 0,
      'delay_sec': 0,
      'context_free_actions': <Map<String, dynamic>>[],
      'actions': actions,
      'transaction_extensions': <dynamic>[],
    };

    // 3. Serialize transaction ONCE - this is critical for signature matching
    // We use the same bytes for signing AND for the ESR payload
    final txBytes = EsrTransactionHelper._serializeTransaction(transaction);

    // 4. Sign with thezeosalias@public key
    final chainIdBytes = hexToBytes(telosChainId);
    final contextFreeHash = Uint8List(32); // 32 zero bytes

    // Create signing digest: sha256(chainId + transaction + contextFreeHash)
    final digestInput = Uint8List(chainIdBytes.length + txBytes.length + contextFreeHash.length);
    digestInput.setRange(0, chainIdBytes.length, chainIdBytes);
    digestInput.setRange(chainIdBytes.length, chainIdBytes.length + txBytes.length, txBytes);
    digestInput.setRange(chainIdBytes.length + txBytes.length, digestInput.length, contextFreeHash);

    final digest = crypto.sha256.convert(digestInput);

    final privateKey = ecc.EOSPrivateKey.fromString(_aliasPrivateKey);
    final signature = privateKey.signHash(Uint8List.fromList(digest.bytes));
    final sigString = signature.toString();

    // 5. Create ESR with variant 2 (full transaction)
    // IMPORTANT: Use the SAME txBytes we signed, not re-serialized
    final buffer = EsrBuffer();

    // Chain ID variant 0 = chain_alias
    buffer.pushVarint32(0);
    buffer.pushUint8(2); // Telos

    // Request variant 2 = transaction
    buffer.pushVarint32(2);
    // Push the exact same bytes we signed - DO NOT re-serialize!
    buffer.pushRaw(txBytes);

    // FIX #2: Changed flags from 1 to 0 (2026-02-05)
    // Flags = 0 (Anchor signs but does NOT broadcast)
    // With flags=0, Anchor will:
    // 1. Add user's signature to the transaction
    // 2. Return the signed transaction via WebSocket (not broadcast it)
    //
    // Then Flutter will:
    // 1. Receive the signed transaction with user's signature
    // 2. Add the pre-computed thezeosalias signature (_lastPresignature)
    // 3. Broadcast the fully-signed transaction via push_transaction API
    //
    // This avoids the anchor-link cosig rejection issue:
    // - anchor-link rejects flags=1 with cosig info pairs
    // - flags=0 lets us handle signature assembly ourselves
    buffer.pushUint8(0);

    // Callback
    buffer.pushString(callback ?? '');

    // Info pairs - with flags=0, we don't need cosig in ESR
    // The thezeosalias signature is stored in _lastPresignature and will be
    // added by Flutter after Anchor returns the user-signed transaction.
    // No info pairs needed.
    buffer.pushVarint32(0); // 0 info pairs

    // Store the pre-computed signature for potential manual fallback
    _lastPresignature = sigString;
    _lastTxBytes = txBytes;

    // Encode
    final payload = buffer.asUint8List();

    final header = ESR_VERSION | 0x80;
    final codec = ZLibCodec(level: 9, raw: true);
    final compressed = codec.encode(payload);

    final result = Uint8List(1 + compressed.length);
    result[0] = header;
    result.setRange(1, result.length, compressed);

    final encoded = base64Url.encode(result).replaceAll('=', '');
    final esrUrl = 'esr://$encoded';

    return esrUrl;
  }

  // _signatureToAbiBytes and _bigIntToBytes32 were removed:
  // No longer needed since flags=0 flow doesn't embed cosig in ESR info pairs.
  // Signatures are now combined at broadcast time, not encoded in the ESR payload.

  /// Fetch chain info from Telos
  static Future<Map<String, dynamic>?> _fetchChainInfo() async {
    final endpoints = [
      'https://telos.eosusa.io',
      'https://mainnet.telos.caleos.io',
      'https://telos.caleos.io',
    ];

    for (final endpoint in endpoints) {
      try {
        final url = Uri.parse('$endpoint/v1/chain/get_info');
        final client = HttpClient();
        final request = await client.getUrl(url);
        final response = await request.close();

        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          return jsonDecode(body) as Map<String, dynamic>;
        }
      } catch (e) {
        print('[EsrService] Failed to fetch chain info from $endpoint: $e');
        continue;
      }
    }
    return null;
  }

  /// Convert hex string with byte reversal (for ref_block_prefix)
  static int _reverseHex(String hex) {
    final bytes = hexToBytes(hex);
    final reversed = bytes.reversed.toList();
    int result = 0;
    for (int i = 0; i < reversed.length; i++) {
      result = (result << 8) | reversed[i];
    }
    return result;
  }

  // _serializeTransactionToBuffer was removed - it was unused and duplicated
  // the canonical serialization in EsrTransactionHelper._serializeTransaction

  /// Create an ESR URL for Anchor wallet using proper binary serialization
  /// (Legacy method - use createSigningRequestWithPresig for transactions
  /// that require thezeosalias@public signature)
  ///
  /// [actions] - List of EOSIO actions to sign
  /// [callback] - Optional callback URL after signing
  ///
  /// Returns ESR URL string (esr://...)
  static String createSigningRequest({
    required List<Map<String, dynamic>> actions,
    String? callback,
  }) {
    final buffer = EsrBuffer();

    // ESR Payload structure:
    // 1. chain_id variant
    // 2. req variant (action[])
    // 3. flags (uint8)
    // 4. callback (string)
    // 5. info (pairs)

    // 1. Chain ID variant:
    //    - variant index 0 = chain_alias (uint8, e.g., 1=EOS, 2=Telos)
    //    - variant index 1 = full chain_id (checksum256, 32 bytes)
    // Using chain alias (simpler, single byte) - Telos = 2 (NOT 4, that's CryptoKylin!)
    buffer.pushVarint32(0); // variant index 0 = chain_alias
    buffer.pushUint8(2);    // Telos chain alias = 2

    // 2. Request - action[] (variant index 1)
    buffer.pushVarint32(1); // variant index 1 = action[]
    buffer.pushVarint32(actions.length); // number of actions

    for (int i = 0; i < actions.length; i++) {
      _serializeAction(buffer, actions[i]);
    }

    // 3. Flags - 0 = do not broadcast, return signed tx
    // Anchor signs and returns the transaction for client-side broadcast
    buffer.pushUint8(0);

    // 4. Callback - empty string
    buffer.pushString(callback ?? '');

    // 5. Info - empty array of key/value pairs
    buffer.pushVarint32(0);

    // Get the serialized payload
    final payload = buffer.asUint8List();

    // Create header byte: bits 0-6 = version, bit 7 = compression flag
    final header = ESR_VERSION | 0x80;  // version 2, compressed = 0x82 = 130

    // Compress payload with zlib deflate (raw deflate, not zlib wrapper)
    final codec = ZLibCodec(level: 9, raw: true);
    final compressed = codec.encode(payload);

    // Combine header + compressed payload
    final result = Uint8List(1 + compressed.length);
    result[0] = header;
    result.setRange(1, result.length, compressed);

    // Base64url encode (ESR uses base64url without padding)
    final encoded = base64Url.encode(result).replaceAll('=', '');

    final esrUrl = 'esr://$encoded';

    return esrUrl;
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Decode an ESR URL for debugging/validation purposes
  /// Returns a map with version, compressed flag, and payload info
  static Map<String, dynamic>? decodeEsrForDebug(String esrUrl) {
    try {
      // Strip esr:// prefix
      var encoded = esrUrl;
      if (encoded.startsWith('esr://')) {
        encoded = encoded.substring(6);
      } else if (encoded.startsWith('esr:')) {
        encoded = encoded.substring(4);
      }

      // Add back padding if needed for base64 decode
      var padded = encoded;
      while (padded.length % 4 != 0) {
        padded += '=';
      }

      // Decode base64url
      final bytes = base64Url.decode(padded);

      // Extract header
      final header = bytes[0];
      final version = header & 0x7F;  // bits 0-6
      final compressed = (header & 0x80) != 0;  // bit 7

      // Decompress if needed
      Uint8List payload;
      if (compressed) {
        final codec = ZLibCodec(raw: true);
        payload = Uint8List.fromList(codec.decode(bytes.sublist(1)));
      } else {
        payload = Uint8List.fromList(bytes.sublist(1));
      }

      return {
        'valid': true,
        'header': header,
        'version': version,
        'compressed': compressed,
        'payloadSize': payload.length,
        'payloadHex': _bytesToHex(payload),
      };
    } catch (e) {
      print('[EsrService.decode] Error: $e');
      return {'valid': false, 'error': e.toString()};
    }
  }

  /// Debug function to verify placeholder name encoding
  /// Placeholder names should encode to specific uint64 values:
  /// - ............1 = 0x0000000000000001 (1)
  /// - ............2 = 0x0000000000000002 (2)
  static void debugPlaceholderEncoding() {
    // Debug utility for verifying placeholder name encoding
    // Placeholder names should encode to specific uint64 values:
    // - ............1 = 0x0000000000000001 (1)
    // - ............2 = 0x0000000000000002 (2)
  }

  /// Serialize an EOSIO action to the buffer
  static void _serializeAction(EsrBuffer buffer, Map<String, dynamic> action) {
    // Action structure:
    // - account (name)
    // - name (name)
    // - authorization (permission_level[])
    // - data (bytes)

    // Account
    buffer.pushName(action['account'] as String);

    // Action name
    buffer.pushName(action['name'] as String);

    // Authorization array
    final auth = action['authorization'] as List;
    buffer.pushVarint32(auth.length);
    for (final perm in auth) {
      final permMap = perm as Map;
      buffer.pushName(permMap['actor'] as String);
      buffer.pushName(permMap['permission'] as String);
    }

    // Action data - serialize according to action type
    final actionName = action['name'] as String;
    final rawData = action['data'];
    final data = rawData is Map ? Map<String, dynamic>.from(rawData) : rawData as Map<String, dynamic>;

    final dataBytes = _serializeActionData(actionName, data);
    buffer.pushBytes(dataBytes);
  }

  /// Serialize action data based on action type using eosdart
  static Uint8List _serializeActionData(String actionName, Map<String, dynamic> data) {
    try {
      // Check if we have pre-serialized ABI data from Rust (hex_data)
      // This is set by CloakWalletManager when using wallet_transact_packed
      final hexData = data['_hex_data']?.toString();
      if (hexData != null && hexData.isNotEmpty) {
        return hexToBytes(hexData);
      }

      final sb = eosdart.SerialBuffer(Uint8List(0));

      switch (actionName) {
        case 'transfer':
          // Transfer: name from, name to, asset quantity, string memo
          sb.pushName(data['from']?.toString() ?? '');
          sb.pushName(data['to']?.toString() ?? '');
          sb.pushAsset(data['quantity']?.toString() ?? '0.0000 TLOS');
          sb.pushString(data['memo']?.toString() ?? '');
          break;

        case 'begin':
          // Begin action has no data (empty struct)
          break;

        case 'end':
          // End action has no data (empty struct)
          break;

        case 'mint':
          // Mint action data is complex - serialize as JSON bytes
          // NOTE: This fallback path should rarely be used now that we have hex_data
          _serializeMintData(sb, data);
          break;

        default:
          // For unknown actions, serialize as JSON (fallback)
          final jsonStr = jsonEncode(data);
          final jsonBytes = utf8.encode(jsonStr);
          sb.pushVaruint32(jsonBytes.length);
          sb.pushArray(jsonBytes);
      }

      final result = sb.asUint8List();
      return result;
    } catch (e) {
      print('[EsrService] Error serializing action data for $actionName: $e');
      // Return empty bytes as fallback
      return Uint8List(0);
    }
  }

  /// Serialize mint action data using proper EOSIO ABI encoding
  ///
  /// The mint action ABI structure (from thezeosalias contract):
  /// ```
  /// mint {
  ///   actions: pls_mint[]
  ///   note_ct: string[]
  /// }
  ///
  /// pls_mint {
  ///   cm: bytes        // commitment (variable length)
  ///   value: uint64    // amount
  ///   symbol: uint64   // token symbol as uint64
  ///   contract: name   // token contract (8 bytes)
  ///   proof: bytes     // ZK proof (variable length)
  /// }
  /// ```
  static void _serializeMintData(eosdart.SerialBuffer sb, Map<String, dynamic> data) {
    try {
      // 1. Serialize 'actions' array (pls_mint[])
      final actions = data['actions'];
      if (actions is List) {
        sb.pushVaruint32(actions.length);

        for (int i = 0; i < actions.length; i++) {
          final action = actions[i] as Map<String, dynamic>;
          _serializePlsMint(sb, action, i);
        }
      } else {
        sb.pushVaruint32(0); // empty array
      }

      // 2. Serialize 'note_ct' array (string[])
      final noteCt = data['note_ct'];
      if (noteCt is List) {
        sb.pushVaruint32(noteCt.length);

        for (final note in noteCt) {
          final noteStr = note?.toString() ?? '';
          sb.pushString(noteStr);
        }
      } else {
        sb.pushVaruint32(0); // empty array
      }
    } catch (e) {
      print('[EsrService] Error serializing mint data: $e');
      // Push empty arrays as fallback
      sb.pushVaruint32(0); // empty actions
      sb.pushVaruint32(0); // empty note_ct
    }
  }

  /// Serialize a single pls_mint struct
  /// Fields in order: cm (bytes), value (uint64), symbol (uint64), contract (name), proof (bytes)
  static void _serializePlsMint(eosdart.SerialBuffer sb, Map<String, dynamic> action, int index) {
    // 1. cm (bytes) - commitment
    final cm = action['cm'];
    final cmBytes = _toBytes(cm, 'cm');
    sb.pushBytes(cmBytes);

    // 2. value (uint64) - amount
    final value = _toUint64(action['value'], 'value');
    sb.pushNumberAsUint64(value);

    // 3. symbol (uint64) - token symbol as uint64
    final symbol = _toUint64(action['symbol'], 'symbol');
    sb.pushNumberAsUint64(symbol);

    // 4. contract (name) - token contract
    final contract = action['contract']?.toString() ?? '';
    sb.pushName(contract);

    // 5. proof (bytes) - ZK proof
    final proof = action['proof'];
    final proofBytes = _toBytes(proof, 'proof');
    sb.pushBytes(proofBytes);
  }

  /// Convert various input types to Uint8List for bytes fields
  static Uint8List _toBytes(dynamic value, String fieldName) {
    if (value == null) {
      return Uint8List(0);
    }

    if (value is Uint8List) {
      return value;
    }

    if (value is List<int>) {
      return Uint8List.fromList(value);
    }

    if (value is List) {
      // List of dynamic, try to convert to ints
      try {
        final ints = value.map((e) => (e as num).toInt()).toList();
        return Uint8List.fromList(ints);
      } catch (e) {
        return Uint8List(0);
      }
    }

    if (value is String) {
      // Could be hex string or base64
      if (value.isEmpty) return Uint8List(0);

      // Try hex first (if it looks like hex)
      if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
        try {
          return hexToBytes(value);
        } catch (_) {}
      }

      // Try base64
      try {
        return Uint8List.fromList(base64.decode(value));
      } catch (_) {}

      // Last resort: UTF-8 bytes
      return Uint8List.fromList(utf8.encode(value));
    }

    return Uint8List(0);
  }

  /// Convert various input types to uint64
  static int _toUint64(dynamic value, String fieldName) {
    if (value == null) {
      return 0;
    }

    if (value is int) {
      return value;
    }

    if (value is double) {
      return value.toInt();
    }

    if (value is String) {
      // Check if it's an EOSIO symbol string like "4,CLOAK"
      if (value.contains(',') && fieldName == 'symbol') {
        return _encodeSymbol(value);
      }

      // Could be a number string
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;

      // Could be BigInt string
      final big = BigInt.tryParse(value);
      if (big != null) return big.toInt();

      return 0;
    }

    return 0;
  }

  /// Encode EOSIO symbol string (e.g., "4,CLOAK") to uint64
  /// Format: precision (1 byte) | symbol_code (7 bytes, ASCII, right-padded with 0)
  static int _encodeSymbol(String symbolStr) {
    try {
      final parts = symbolStr.split(',');
      if (parts.length != 2) {
        return 0;
      }

      final precision = int.parse(parts[0].trim());
      final symbolCode = parts[1].trim().toUpperCase();

      // Symbol is encoded as: precision | (symbol_code << 8)
      // Symbol code is up to 7 characters, each char is ASCII
      int encoded = precision;
      for (int i = 0; i < symbolCode.length && i < 7; i++) {
        encoded |= (symbolCode.codeUnitAt(i) << (8 * (i + 1)));
      }

      return encoded;
    } catch (e) {
      print('[EsrService] Failed to encode symbol $symbolStr: $e');
      return 0;
    }
  }

  /// Check if Anchor wallet is already running on Linux
  static Future<bool> isAnchorRunning() async {
    if (!Platform.isLinux) return false;

    try {
      final result = await Process.run('pgrep', ['-f', 'anchor']);
      return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
    } catch (e) {
      print('[EsrService] pgrep failed: $e');
      return false;
    }
  }

  /// Launch Anchor wallet with the signing request
  ///
  /// Strategy:
  /// 1. Check if Anchor is already running
  /// 2. If running, use xdg-open to send ESR to existing instance
  /// 3. If not running, try to launch Anchor directly
  /// 4. Fallback to web resolver
  static Future<bool> launchAnchor(String esrUrl) async {
    // On Linux, use a smart approach
    if (Platform.isLinux) {
      // Check if Anchor is already running
      final isRunning = await isAnchorRunning();

      if (isRunning) {
        // Anchor is running - use xdg-open to send ESR to existing instance
        // This works because Anchor registers as the esr:// protocol handler
        try {
          final result = await Process.run('xdg-open', [esrUrl]);
          if (result.exitCode == 0) {
            return true;
          }
        } catch (_) {}
      }

      // Try to launch Anchor directly
      final anchorPaths = [
        '/opt/Anchor Wallet/anchor-wallet',
        '/home/kameron/Applications/anchor-wallet.sh',
        '/home/kameron/Applications/anchor-wallet.AppImage',
        '/usr/bin/anchor-wallet',
        'anchor-wallet',
        'anchor',
      ];

      for (final path in anchorPaths) {
        try {
          await Process.start(
            path,
            [esrUrl],
            mode: ProcessStartMode.detached,
          );
          return true;
        } catch (_) {
          continue;
        }
      }

      // Try xdg-open as fallback (launches Anchor if protocol handler is registered)
      try {
        final result = await Process.run('xdg-open', [esrUrl]);
        if (result.exitCode == 0) {
          return true;
        }
      } catch (_) {}
    }

    // Try the ESR URL directly (works on macOS/Windows)
    final esrUri = Uri.parse(esrUrl);

    try {
      if (await canLaunchUrl(esrUri)) {
        final launched = await launchUrl(esrUri, mode: LaunchMode.externalApplication);
        if (launched) {
          return true;
        }
      }
    } catch (_) {}

    // Fallback: Open eosio.to web resolver
    try {
      final webUrl = Uri.parse('https://eosio.to/$esrUrl');
      final launched = await launchUrl(webUrl, mode: LaunchMode.externalApplication);
      if (launched) {
        return true;
      }
    } catch (_) {}

    print('[EsrService] All launch methods failed');
    return false;
  }

  /// Build shield (mint) transaction actions
  ///
  /// Creates the actions needed to shield tokens:
  /// 1. begin - Initialize the transaction on thezeosalias
  /// 2. transfer - Send tokens from user to zeosprotocol
  /// 3. transfer - Send fee (0.3 CLOAK) to thezeosalias
  /// 4. mint - ZK proof creates shielded note
  /// 5. end - Finalize the transaction
  ///
  /// Contract ABIs:
  /// - thezeosalias: has begin, mint, end actions
  /// - zeosprotocol: has mint, spend, withdraw (but NOT begin/end)
  static List<Map<String, dynamic>> buildShieldActions({
    required String tokenContract,
    required String quantity,
    required Map<String, dynamic> mintProof,
    String feeQuantity = '0.3000 CLOAK',
  }) {
    // Memo must match exactly what the ZEOS protocol expects
    // From working transaction a8e29db3...: "ZEOS transfer & mint"
    const memo = 'ZEOS transfer & mint';

    return [
      // Action 1: begin - thezeosalias contract
      {
        'account': 'thezeosalias',
        'name': 'begin',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },

      // Action 2: transfer tokens to zeosprotocol
      // Requires user signature
      {
        'account': tokenContract,
        'name': 'transfer',
        'authorization': [
          {'actor': actorPlaceholder, 'permission': permissionPlaceholder}
        ],
        'data': {
          'from': actorPlaceholder,
          'to': 'zeosprotocol',
          'quantity': quantity,
          'memo': memo,
        },
      },

      // Action 3: transfer fee to thezeosalias
      // Requires user signature
      // Memo must match exactly: "tx fee" (from working transaction a8e29db3...)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': actorPlaceholder, 'permission': permissionPlaceholder}
        ],
        'data': {
          'from': actorPlaceholder,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'tx fee',
        },
      },

      // Action 4: mint - thezeosalias contract
      {
        'account': 'thezeosalias',
        'name': 'mint',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': mintProof,
      },

      // Action 5: end - thezeosalias contract
      {
        'account': 'thezeosalias',
        'name': 'end',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
    ];
  }

  /// Build actions for publishing an auth token (vault) to blockchain
  ///
  /// This is required before the auth token can be used for vault deposits.
  /// The auth token is a note with quantity=0 that acts as an identifier.
  ///
  /// Actions:
  /// 1. begin (thezeosalias signs)
  /// 2. fee transfer (user signs) - pays for publish
  /// 3. mint with quantity=0 (thezeosalias signs) - the auth token
  /// 4. end (thezeosalias signs)
  static List<Map<String, dynamic>> buildAuthTokenPublishActions({
    required Map<String, dynamic> mintProof,
    required String userAccount,
    String userPermission = 'active',
    String feeQuantity = '0.3000 CLOAK',
  }) {
    return [
      // Action 1: begin - thezeosalias contract
      {
        'account': 'thezeosalias',
        'name': 'begin',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },

      // Action 2: transfer fee to thezeosalias (user signs)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'publish vault',
        },
      },

      // Action 3: mint auth token (thezeosalias signs)
      // This is the ZK proof for the auth token (quantity=0)
      {
        'account': 'thezeosalias',
        'name': 'mint',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': mintProof,
      },

      // Action 4: end - thezeosalias contract
      {
        'account': 'thezeosalias',
        'name': 'end',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
    ];
  }

  /// Build shield actions with actual user account (no placeholders)
  /// This is needed for variant 2 ESR where we pre-sign the transaction
  ///
  /// Contract ABIs:
  /// - thezeosalias: has begin, mint, end actions
  /// - zeosprotocol: has mint, spend, withdraw (but NOT begin/end)
  static List<Map<String, dynamic>> buildShieldActionsWithAccount({
    required String tokenContract,
    required String quantity,
    required Map<String, dynamic> mintProof,
    required String userAccount,
    String userPermission = 'active',
    String feeQuantity = '0.3000 CLOAK',
  }) {
    // Memo must match exactly what the ZEOS protocol expects
    // From working transaction a8e29db3...: "ZEOS transfer & mint"
    const memo = 'ZEOS transfer & mint';

    return [
      // Action 1: begin - thezeosalias contract has this action
      {
        'account': 'thezeosalias',
        'name': 'begin',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
      // Action 2: transfer tokens to zeosprotocol (user signs)
      {
        'account': tokenContract,
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'zeosprotocol',
          'quantity': quantity,
          'memo': memo,
        },
      },
      // Action 3: transfer fee to thezeosalias (user signs)
      // Memo must match exactly: "tx fee" (from working transaction a8e29db3...)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'tx fee',
        },
      },
      // Action 4: mint - thezeosalias contract has this action
      {
        'account': 'thezeosalias',
        'name': 'mint',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': mintProof,
      },
      // Action 5: end - thezeosalias contract has this action
      {
        'account': 'thezeosalias',
        'name': 'end',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
    ];
  }

  /// Build a begin + fee_transfer + end transaction to clear the assetbuffer.
  /// No mint action, no ZK proof needed. Just pays the begin fee and calls end.
  /// The end action should clear orphaned assetbuffer entries.
  static List<Map<String, dynamic>> buildClearBufferActions({
    required String userAccount,
    String userPermission = 'active',
    String feeQuantity = '0.2000 CLOAK',
  }) {
    return [
      // Action 1: begin (thezeosalias@public)
      {
        'account': 'thezeosalias',
        'name': 'begin',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
      // Action 2: transfer fee to thezeosalias (user signs)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'tx fee',
        },
      },
      // Action 3: end (thezeosalias@public)
      {
        'account': 'thezeosalias',
        'name': 'end',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
    ];
  }

  /// Build ONLY the user transfer actions for ESR (simple actions Anchor can handle)
  /// The begin/mint/end actions will be added later and signed with thezeosalias key
  static List<Map<String, dynamic>> buildUserTransferActions({
    required String tokenContract,
    required String quantity,
    required String userAccount,
    String userPermission = 'active',
    String feeQuantity = '0.3000 CLOAK',
  }) {
    // Memo must match exactly what the ZEOS protocol expects
    // From working transaction a8e29db3...: "ZEOS transfer & mint"
    const memo = 'ZEOS transfer & mint';

    return [
      // Transfer tokens to zeosprotocol (user signs)
      {
        'account': tokenContract,
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'zeosprotocol',
          'quantity': quantity,
          'memo': memo,
        },
      },
      // Transfer fee to thezeosalias (user signs)
      // Memo must match exactly: "tx fee" (from working transaction a8e29db3...)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': userPermission}
        ],
        'data': {
          'from': userAccount,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'tx fee',
        },
      },
    ];
  }

  /// Create a simple ESR for just the user's transfer actions
  /// Returns ESR URL that Anchor can easily decode and sign
  static Future<String> createTransferOnlyEsr({
    required String tokenContract,
    required String quantity,
    required String userAccount,
    String feeQuantity = '0.3000 CLOAK',
  }) async {
    final actions = buildUserTransferActions(
      tokenContract: tokenContract,
      quantity: quantity,
      userAccount: userAccount,
      feeQuantity: feeQuantity,
    );

    // Use simple ESR (variant 1 = action array) with broadcast=false
    // so we get the signed transaction back to combine with our signatures
    final buffer = EsrBuffer();

    // Chain ID variant 0 = chain_alias, Telos = 2
    buffer.pushVarint32(0);
    buffer.pushUint8(2);

    // Request variant 1 = action[]
    buffer.pushVarint32(1);
    buffer.pushVarint32(actions.length);
    for (final action in actions) {
      _serializeAction(buffer, action);
    }

    // Flags = 0 (DO NOT broadcast - return signed tx to us)
    buffer.pushUint8(0);

    // Callback - empty (we'll use Anchor Link WebSocket)
    buffer.pushString('');

    // Info pairs - empty
    buffer.pushVarint32(0);

    // Encode
    final payload = buffer.asUint8List();
    final header = ESR_VERSION | 0x80;
    final codec = ZLibCodec(level: 9, raw: true);
    final compressed = codec.encode(payload);

    final result = Uint8List(1 + compressed.length);
    result[0] = header;
    result.setRange(1, result.length, compressed);

    final encoded = base64Url.encode(result).replaceAll('=', '');
    final esrUrl = 'esr://$encoded';

    return esrUrl;
  }

  /// Build and broadcast the complete shield transaction
  ///
  /// This takes the user's signatures from Anchor and combines them with
  /// our signatures for begin/mint/end, then broadcasts the complete transaction.
  ///
  /// [userSignatures] - Signatures from Anchor for the transfer actions
  /// [tokenContract] - Token contract being shielded
  /// [quantity] - Amount being shielded
  /// [userAccount] - User's Telos account
  /// [mintProof] - ZK proof data (with _hex_data for serialization)
  /// [feeQuantity] - Fee amount
  ///
  /// Returns transaction ID on success
  static Future<String> buildAndBroadcastShieldTransaction({
    required List<String> userSignatures,
    required String tokenContract,
    required String quantity,
    required String userAccount,
    required Map<String, dynamic> mintProof,
    String feeQuantity = '0.3000 CLOAK',
  }) async {
    // Memo must match exactly what the ZEOS protocol expects
    // From working transaction a8e29db3...: "ZEOS transfer & mint"
    const memo = 'ZEOS transfer & mint';

    // 1. Fetch chain info for transaction header
    final chainInfo = await _fetchChainInfo();
    if (chainInfo == null) {
      throw Exception('Failed to fetch chain info');
    }

    final headBlockId = chainInfo['head_block_id'] as String;
    final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
    final refBlockPrefix = _reverseHex(headBlockId.substring(16, 24));

    // 2. Build the complete 5-action transaction
    final expiration = DateTime.now().add(const Duration(minutes: 10));

    // Build all 5 actions
    final allActions = [
      // Action 1: begin (thezeosalias signs)
      {
        'account': 'thezeosalias',
        'name': 'begin',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
      // Action 2: transfer tokens (user signs)
      {
        'account': tokenContract,
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': 'active'}
        ],
        'data': {
          'from': userAccount,
          'to': 'zeosprotocol',
          'quantity': quantity,
          'memo': memo,
        },
      },
      // Action 3: transfer fee (user signs)
      // Memo must match exactly: "tx fee" (from working transaction a8e29db3...)
      {
        'account': 'thezeostoken',
        'name': 'transfer',
        'authorization': [
          {'actor': userAccount, 'permission': 'active'}
        ],
        'data': {
          'from': userAccount,
          'to': 'thezeosalias',
          'quantity': feeQuantity,
          'memo': 'tx fee',
        },
      },
      // Action 4: mint (thezeosalias signs)
      {
        'account': 'thezeosalias',
        'name': 'mint',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': mintProof,
      },
      // Action 5: end (thezeosalias signs)
      {
        'account': 'thezeosalias',
        'name': 'end',
        'authorization': [
          {'actor': 'thezeosalias', 'permission': 'public'}
        ],
        'data': {},
      },
    ];

    final transaction = {
      'expiration': '${expiration.toUtc().toIso8601String().split('.')[0]}Z',
      'ref_block_num': refBlockNum,
      'ref_block_prefix': refBlockPrefix,
      'max_net_usage_words': 0,
      'max_cpu_usage_ms': 0,
      'delay_sec': 0,
      'context_free_actions': <Map<String, dynamic>>[],
      'actions': allActions,
      'transaction_extensions': <dynamic>[],
    };

    // 3. Serialize transaction for signing
    // Use the canonical serialization path (same as createSigningRequestWithPresig)
    // The mint action's data map already contains _hex_data from the mintProof
    final txBytes = EsrTransactionHelper._serializeTransaction(transaction);
    final chainIdBytes = hexToBytes(telosChainId);
    final contextFreeHash = Uint8List(32);

    final digestInput = Uint8List(chainIdBytes.length + txBytes.length + contextFreeHash.length);
    digestInput.setRange(0, chainIdBytes.length, chainIdBytes);
    digestInput.setRange(chainIdBytes.length, chainIdBytes.length + txBytes.length, txBytes);
    digestInput.setRange(chainIdBytes.length + txBytes.length, digestInput.length, contextFreeHash);

    final digest = crypto.sha256.convert(digestInput);

    // 4. Sign with thezeosalias@public key
    final privateKey = ecc.EOSPrivateKey.fromString(_aliasPrivateKey);
    final aliasSignature = privateKey.signHash(Uint8List.fromList(digest.bytes));

    // 5. Combine signatures (user's + ours)
    final allSignatures = [...userSignatures, aliasSignature.toString()];

    // 6. Broadcast via shared broadcast path
    final packedTrx = bytesToHex(txBytes);
    return await _broadcastSignedTransaction(
      packedTrx: packedTrx,
      signatures: allSignatures,
    );
  }

  /// Add thezeosalias signature to Anchor's signed transaction and broadcast
  ///
  /// When using flags=0, Anchor returns the signed transaction via WebSocket.
  /// We extract it, add our pre-computed thezeosalias signature, and broadcast.
  ///
  /// The flow is:
  /// 1. Extract packed_trx and user signatures from Anchor's response
  /// 2. Use the pre-stored _lastPresignature (computed at ESR creation time)
  ///    since we signed the same transaction bytes
  /// 3. Broadcast with both signatures via push_transaction API
  static Future<String> addSignatureAndBroadcast(Map<String, dynamic> anchorResponse) async {

    // Extract the serialized transaction from Anchor's response
    // Anchor Link returns: { signatures: [...], serializedTransaction: "hex...", ... }
    String? packedTrx;
    List<String> userSignatures = [];

    // Try different response formats
    if (anchorResponse.containsKey('serializedTransaction')) {
      packedTrx = anchorResponse['serializedTransaction'] as String?;
    } else if (anchorResponse.containsKey('packed_trx')) {
      packedTrx = anchorResponse['packed_trx'] as String?;
    } else if (anchorResponse.containsKey('transaction')) {
      final tx = anchorResponse['transaction'];
      if (tx is Map && tx.containsKey('serializedTransaction')) {
        packedTrx = tx['serializedTransaction'] as String?;
      } else if (tx is Map && tx.containsKey('packed_trx')) {
        packedTrx = tx['packed_trx'] as String?;
      }
    }

    // Extract signatures
    final sigs = anchorResponse['signatures'] ?? anchorResponse['signature'];
    if (sigs is List) {
      userSignatures = sigs.map((s) => s.toString()).toList();
    } else if (sigs is String) {
      userSignatures = [sigs];
    }

    // If we don't have packed_trx from Anchor but we have the stored transaction bytes,
    // use those instead (Anchor signed the same transaction we created)
    if ((packedTrx == null || packedTrx.isEmpty) && _lastTxBytes != null) {
      packedTrx = bytesToHex(_lastTxBytes!);
    }

    if (packedTrx == null || packedTrx.isEmpty) {
      throw Exception('No serialized transaction in Anchor response. Keys: ${anchorResponse.keys}');
    }

    if (userSignatures.isEmpty) {
      throw Exception('No signatures in Anchor response');
    }

    // Use the pre-computed thezeosalias signature if available
    // This was computed at ESR creation time over the same transaction bytes
    String aliasSignatureStr;
    if (_lastPresignature != null) {
      aliasSignatureStr = _lastPresignature!;
    } else {
      // Fallback: re-compute the signature (should not normally happen)
      final txBytes = hexToBytes(packedTrx);

      // Compute signing digest: sha256(chainId + txBytes + contextFreeHash)
      final chainIdBytes = hexToBytes(telosChainId);
      final contextFreeHash = Uint8List(32); // 32 zero bytes

      final digestInput = Uint8List(chainIdBytes.length + txBytes.length + contextFreeHash.length);
      digestInput.setRange(0, chainIdBytes.length, chainIdBytes);
      digestInput.setRange(chainIdBytes.length, chainIdBytes.length + txBytes.length, txBytes);
      digestInput.setRange(chainIdBytes.length + txBytes.length, digestInput.length, contextFreeHash);

      final digest = crypto.sha256.convert(digestInput);

      final privateKey = ecc.EOSPrivateKey.fromString(_aliasPrivateKey);
      final aliasSignature = privateKey.signHash(Uint8List.fromList(digest.bytes));
      aliasSignatureStr = aliasSignature.toString();
    }

    // Combine signatures (user's + ours)
    final allSignatures = [...userSignatures, aliasSignatureStr];

    // Broadcast the fully-signed transaction directly via push_transaction
    // This is the same approach the official CLOAK GUI uses
    final txId = await _broadcastSignedTransaction(
      packedTrx: packedTrx,
      signatures: allSignatures,
    );

    // Clear stored data after successful broadcast
    _lastTxBytes = null;
    _lastPresignature = null;

    return txId;
  }

  /// Broadcast transaction using manually-entered user signature
  ///
  /// This is used when Anchor Desktop shows the raw signature and user
  /// copies/pastes it into our app. We combine it with the pre-computed
  /// thezeosalias signature and broadcast.
  static Future<String> broadcastWithManualSignature(String userSignature) async {
    // Validate we have the stored transaction data
    if (_lastTxBytes == null || _lastPresignature == null) {
      throw Exception('No pending transaction. Please generate a new ESR first.');
    }

    // Validate signature format
    final sig = userSignature.trim();
    if (!sig.startsWith('SIG_K1_')) {
      throw Exception('Invalid signature format. Should start with SIG_K1_');
    }

    // Convert transaction bytes to hex for packed_trx
    final packedTrx = bytesToHex(_lastTxBytes!);

    // Combine signatures (user's + thezeosalias)
    final allSignatures = [sig, _lastPresignature!];

    // Broadcast via push_transaction
    final txId = await _broadcastSignedTransaction(
      packedTrx: packedTrx,
      signatures: allSignatures,
    );

    // Clear stored data after successful broadcast
    _lastTxBytes = null;
    _lastPresignature = null;

    return txId;
  }

  /// Broadcast a fully-signed transaction to the Telos network
  ///
  /// This is the common broadcast path used by all shield flows (Anchor WebSocket,
  /// manual signature entry, and direct build-and-broadcast). It mirrors how the
  /// official CLOAK GUI broadcasts via push_transaction.
  ///
  /// [packedTrx] - Hex-encoded serialized transaction bytes
  /// [signatures] - All required signatures (user + thezeosalias)
  ///
  /// Returns transaction ID on success, throws on failure
  static Future<String> _broadcastSignedTransaction({
    required String packedTrx,
    required List<String> signatures,
  }) async {
    final signedTx = {
      'signatures': signatures,
      'compression': 'none',
      'packed_context_free_data': '',
      'packed_trx': packedTrx,
    };

    // Try multiple Telos API endpoints
    final endpoints = [
      'https://telos.eosusa.io',
      'https://mainnet.telos.caleos.io',
      'https://telos.caleos.io',
    ];

    String? lastError;
    for (final endpoint in endpoints) {
      try {
        final url = Uri.parse('$endpoint/v1/chain/push_transaction');

        final client = HttpClient();
        final request = await client.postUrl(url);
        request.headers.set('Content-Type', 'application/json');
        request.write(jsonEncode(signedTx));
        final response = await request.close();

        final responseBody = await response.transform(utf8.decoder).join();
        final result = jsonDecode(responseBody) as Map<String, dynamic>;

        if (response.statusCode == 200 || response.statusCode == 202) {
          final txId = result['transaction_id'] as String?;
          return txId ?? 'unknown';
        } else {
          // Extract meaningful error message
          final error = result['error'] as Map<String, dynamic>?;
          final details = error?['details'] as List?;
          if (details != null && details.isNotEmpty) {
            lastError = details[0]['message']?.toString() ?? responseBody;
          } else {
            lastError = error?['what']?.toString() ?? responseBody;
          }
          print('[EsrService] Broadcast error from $endpoint: $lastError');
          continue;
        }
      } catch (e) {
        print('[EsrService] Broadcast failed for $endpoint: $e');
        lastError = e.toString();
        continue;
      }
    }

    throw Exception(lastError ?? 'Failed to broadcast transaction to all endpoints');
  }

  /// Check if there's a pending transaction ready for manual signature
  static bool get hasPendingTransaction => _lastTxBytes != null && _lastPresignature != null;

  // _serializeFullTransaction and _serializeActionForSigning were removed
  // to eliminate dual serialization divergence (Bug #2).
  // All serialization now goes through the canonical path:
  // EsrTransactionHelper._serializeTransaction -> _serializeActionToBuffer -> _serializeActionData

  /// Build a simple transfer action (for testing or other uses)
  static Map<String, dynamic> buildTransferAction({
    required String tokenContract,
    required String to,
    required String quantity,
    String memo = '',
  }) {
    return {
      'account': tokenContract,
      'name': 'transfer',
      'authorization': [
        {'actor': actorPlaceholder, 'permission': permissionPlaceholder}
      ],
      'data': {
        'from': actorPlaceholder,
        'to': to,
        'quantity': quantity,
        'memo': memo,
      },
    };
  }

  /// Create a test ESR URL with a simple transfer (for debugging)
  static String createTestTransferEsr({
    required String to,
    required String quantity,
    String memo = 'test',
  }) {
    final action = buildTransferAction(
      tokenContract: 'eosio.token',
      to: to,
      quantity: quantity,
      memo: memo,
    );
    return createSigningRequest(actions: [action]);
  }
}

/// Buffer for serializing ESR data in EOSIO binary format
/// Uses eosdart's SerialBuffer internally for consistent EOSIO encoding
class EsrBuffer {
  final eosdart.SerialBuffer _sb = eosdart.SerialBuffer(Uint8List(0));

  /// Get the serialized data as Uint8List
  Uint8List asUint8List() => _sb.asUint8List();

  /// Push a single byte
  void pushUint8(int value) {
    _sb.push([value & 0xFF]);
  }

  /// Push a 16-bit unsigned integer (little-endian)
  void pushUint16(int value) {
    _sb.pushUint16(value);
  }

  /// Push a 32-bit unsigned integer (little-endian)
  void pushUint32(int value) {
    _sb.pushUint32(value);
  }

  /// Push a 64-bit unsigned integer (little-endian)
  void pushUint64(int value) {
    _sb.pushNumberAsUint64(value);
  }

  /// Push a variable-length integer (LEB128/varuint32 encoding)
  void pushVarint32(int value) {
    _sb.pushVaruint32(value);
  }

  /// Push raw bytes WITHOUT length prefix (for fixed-size types like checksum256)
  void pushRaw(Uint8List bytes) {
    _sb.pushArray(bytes);
  }

  /// Push raw bytes with length prefix (for variable-size bytes type)
  void pushBytes(Uint8List bytes) {
    _sb.pushBytes(bytes);
  }

  /// Push a string with length prefix
  void pushString(String str) {
    _sb.pushString(str);
  }

  /// Push an EOSIO Name (64-bit encoded) using eosdart
  void pushName(String name) {
    _sb.pushName(name);
  }
}

/// Convert hex string to bytes
Uint8List hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

/// Convert bytes to hex string
String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

/// Transaction signing and broadcasting utilities
class EsrTransactionHelper {
  /// Sign the transaction with thezeosalias@public key
  ///
  /// This is needed because the shield transaction has actions that require
  /// authorization from thezeosalias@public (begin, mint, end), but Anchor
  /// doesn't have that key. The key is published and anyone can use it.
  ///
  /// [transaction] - The transaction returned from Anchor (serialized or JSON)
  /// [signatures] - Existing signatures from Anchor
  ///
  /// Returns the combined list of signatures (Anchor's + ours)
  static Future<List<String>> signWithAliasKey({
    required Map<String, dynamic> transaction,
    required List<String> existingSignatures,
  }) async {
    try {
      // Get the private key for thezeosalias@public
      final privateKey = ecc.EOSPrivateKey.fromString(EsrService._aliasPrivateKey);

      // The transaction needs to be serialized to get the signing digest
      // We need to create the digest from: chainId + serialized transaction + context-free data hash
      final chainIdBytes = hexToBytes(EsrService.telosChainId);

      // Serialize the transaction to get bytes
      final txBytes = _serializeTransaction(transaction);

      // Context-free data hash (empty = 32 zero bytes)
      final contextFreeDataHash = Uint8List(32);

      // Create the signing digest: sha256(chainId + transaction + contextFreeHash)
      final digestInput = Uint8List(chainIdBytes.length + txBytes.length + contextFreeDataHash.length);
      digestInput.setRange(0, chainIdBytes.length, chainIdBytes);
      digestInput.setRange(chainIdBytes.length, chainIdBytes.length + txBytes.length, txBytes);
      digestInput.setRange(chainIdBytes.length + txBytes.length, digestInput.length, contextFreeDataHash);

      final digest = crypto.sha256.convert(digestInput);

      // Sign the digest
      final signature = privateKey.signHash(Uint8List.fromList(digest.bytes));
      final sigString = signature.toString();

      // Combine signatures
      final allSignatures = [...existingSignatures, sigString];

      return allSignatures;
    } catch (e) {
      print('[EsrTransactionHelper] Error signing transaction: $e');
      rethrow;
    }
  }

  /// Serialize a transaction to bytes for signing
  static Uint8List _serializeTransaction(Map<String, dynamic> transaction) {
    final sb = eosdart.SerialBuffer(Uint8List(0));

    // Transaction header
    // expiration (uint32) - seconds since epoch (EOSIO uses UTC)
    final expiration = transaction['expiration'];
    if (expiration is String) {
      // Ensure we parse as UTC - add 'Z' if not present
      final expStrUtc = expiration.endsWith('Z') ? expiration : '${expiration}Z';
      final dt = DateTime.parse(expStrUtc);
      sb.pushUint32(dt.millisecondsSinceEpoch ~/ 1000);
    } else if (expiration is int) {
      sb.pushUint32(expiration);
    } else {
      // Default to now + 30 minutes (UTC)
      sb.pushUint32(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 600);
    }

    // ref_block_num (uint16)
    final refBlockNum = transaction['ref_block_num'] ?? 0;
    sb.pushUint16(refBlockNum is int ? refBlockNum : int.parse(refBlockNum.toString()));

    // ref_block_prefix (uint32)
    final refBlockPrefix = transaction['ref_block_prefix'] ?? 0;
    sb.pushUint32(refBlockPrefix is int ? refBlockPrefix : int.parse(refBlockPrefix.toString()));

    // max_net_usage_words (varuint32)
    sb.pushVaruint32(transaction['max_net_usage_words'] ?? 0);

    // max_cpu_usage_ms (uint8)
    sb.push([transaction['max_cpu_usage_ms'] ?? 0]);

    // delay_sec (varuint32)
    sb.pushVaruint32(transaction['delay_sec'] ?? 0);

    // context_free_actions (action[])
    final contextFreeActions = transaction['context_free_actions'] as List? ?? [];
    sb.pushVaruint32(contextFreeActions.length);
    for (final action in contextFreeActions) {
      _serializeActionToBuffer(sb, action as Map<String, dynamic>);
    }

    // actions (action[])
    final actions = transaction['actions'] as List? ?? [];
    sb.pushVaruint32(actions.length);
    for (final action in actions) {
      _serializeActionToBuffer(sb, action as Map<String, dynamic>);
    }

    // transaction_extensions (pair<uint16, bytes>[])
    final extensions = transaction['transaction_extensions'] as List? ?? [];
    sb.pushVaruint32(extensions.length);

    return sb.asUint8List();
  }

  /// Serialize a single action to the buffer
  static void _serializeActionToBuffer(eosdart.SerialBuffer sb, Map<String, dynamic> action) {
    // account (name)
    sb.pushName(action['account'] as String);

    // name (name)
    final actionName = action['name'] as String;
    sb.pushName(actionName);

    // authorization (permission_level[])
    final auth = action['authorization'] as List? ?? [];
    sb.pushVaruint32(auth.length);
    for (final perm in auth) {
      final permMap = perm as Map;
      sb.pushName(permMap['actor'] as String);
      sb.pushName(permMap['permission'] as String);
    }

    // data (bytes) - handle different formats
    final data = action['data'];
    if (data is String) {
      // Hex-encoded data
      final dataBytes = hexToBytes(data);
      sb.pushBytes(dataBytes);
    } else if (data is List) {
      sb.pushBytes(Uint8List.fromList(data.cast<int>()));
    } else if (data is Map) {
      // Map data - need to serialize based on action type
      final mapData = Map<String, dynamic>.from(data);
      final dataBytes = EsrService._serializeActionData(actionName, mapData);
      sb.pushBytes(dataBytes);
    } else {
      // Empty data
      sb.pushBytes(Uint8List(0));
    }
  }

  /// Broadcast a signed transaction to the Telos network
  ///
  /// [transaction] - The full transaction object (will be serialized)
  /// [signatures] - All required signatures (from Anchor + thezeosalias)
  ///
  /// Returns the transaction result or throws on error
  static Future<Map<String, dynamic>> broadcastTransaction({
    required Map<String, dynamic> transaction,
    required List<String> signatures,
  }) async {
    final packedTrx = _serializeTransactionToHex(transaction);
    final txId = await EsrService._broadcastSignedTransaction(
      packedTrx: packedTrx,
      signatures: signatures,
    );

    return {'transaction_id': txId};
  }

  /// Serialize transaction to hex string for broadcasting
  static String _serializeTransactionToHex(Map<String, dynamic> transaction) {
    final bytes = _serializeTransaction(transaction);
    return bytesToHex(bytes);
  }

  /// Process the response from Anchor Link WebSocket
  ///
  /// 1. Extract the transaction and user's signature
  /// 2. Sign with thezeosalias@public key
  /// 3. Broadcast the transaction
  ///
  /// Returns the broadcast result
  static Future<Map<String, dynamic>> processAnchorResponse(
    Map<String, dynamic> response,
  ) async {
    // Extract transaction
    final transaction = response['transaction'] as Map<String, dynamic>?;
    if (transaction == null) {
      throw Exception('No transaction in Anchor response');
    }

    // Extract signatures
    final sigs = response['signatures'];
    List<String> existingSignatures;
    if (sigs is List) {
      existingSignatures = sigs.cast<String>();
    } else if (sigs is String) {
      existingSignatures = [sigs];
    } else {
      existingSignatures = [];
    }

    // Sign with thezeosalias@public key
    final allSignatures = await signWithAliasKey(
      transaction: transaction,
      existingSignatures: existingSignatures,
    );

    // Broadcast the transaction
    final result = await broadcastTransaction(
      transaction: transaction,
      signatures: allSignatures,
    );

    return result;
  }
}
