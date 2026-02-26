// EOSIO HTTP Client for CLOAK/Telos blockchain
// Provides methods to interact with Telos API for syncing

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Hyperion API endpoint for Telos
const String hyperionEndpoint = 'https://telos.eosusa.io';

/// Telos token list URLs (contains logo URLs for native EOSIO tokens)
/// We fetch multiple lists for maximum coverage
const List<String> _tokenListUrls = [
  // Primary: Telos mainnet token list (different format - has 'account' and 'logo_sm')
  'https://raw.githubusercontent.com/telosnetwork/token-list/main/telosmain.json',
  // Secondary: Telos-specific tokens (standard format - has 'contract' and 'logo')
  'https://raw.githubusercontent.com/telosnetwork/token-list/main/tokens.telos.json',
  // Tertiary: EOS tokens that may also be on Telos
  'https://raw.githubusercontent.com/telosnetwork/token-list/main/tokens.eos.json',
];

/// Cached token logos from Telos token list (fetched on-demand)
Map<String, String>? _cachedTokenLogos;
DateTime? _tokenLogoCacheTimestamp;
const Duration _tokenLogoCacheMaxAge = Duration(hours: 24);

/// Fetch Telos token list from GitHub and cache logo URLs
/// This fetches small JSON files (~10-50KB each), NOT the actual images.
/// Images are loaded lazily by Flutter's Image.network() when displayed.
Future<void> fetchTelosTokenList() async {
  // Check cache validity
  if (_cachedTokenLogos != null &&
      _tokenLogoCacheTimestamp != null &&
      DateTime.now().difference(_tokenLogoCacheTimestamp!) < _tokenLogoCacheMaxAge) {
    return; // Cache still valid
  }

  _cachedTokenLogos = {};

  for (final urlStr in _tokenListUrls) {
    try {
      final url = Uri.parse(urlStr);
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        // Handle different formats:
        // 1. telosmain.json: {"tokens": [...], ...} with 'account' and 'logo_sm'
        // 2. tokens.telos.json / tokens.eos.json: [...] with 'contract' and 'logo'
        List<dynamic> tokens;
        if (decoded is List) {
          tokens = decoded;
        } else if (decoded is Map && decoded['tokens'] != null) {
          tokens = decoded['tokens'] as List;
        } else {
          continue;
        }

        for (final token in tokens) {
          // Get contract/account (different field names in different formats)
          final contract = token['contract'] as String? ?? token['account'] as String?;
          final symbol = token['symbol'] as String?;
          // Get logo URL (different field names in different formats)
          final logo = token['logo'] as String? ??
                       token['logo_sm'] as String? ??
                       token['logo_lg'] as String?;

          if (contract != null && symbol != null && logo != null && logo.isNotEmpty) {
            // Don't overwrite if already exists (first list takes priority)
            final key = '$contract:$symbol';
            if (!_cachedTokenLogos!.containsKey(key)) {
              _cachedTokenLogos![key] = logo;
            }
          }
        }
      }
    } catch (e) {
      // Continue to next URL
    }
  }

  _tokenLogoCacheTimestamp = DateTime.now();
}

/// Get logo URL from cached Telos token list
String? _getTokenLogoFromCache(String contract, String symbol) {
  return _cachedTokenLogos?['$contract:$symbol'];
}

/// Well-known Telos Zero (native EOSIO) token logos (fallback if token list fetch fails)
/// Use 'asset:' prefix for local Flutter assets
const Map<String, String> _wellKnownTokenLogos = {
  // CLOAK/ZEOS ecosystem - use local asset
  'thezeostoken:CLOAK': 'asset:assets/cloak_logo.png',

  // Native TLOS - official Telos logo
  'eosio.token:TLOS': 'https://raw.githubusercontent.com/telosnetwork/token-list/main/logos/telos.png',

  // Common Telos Zero native tokens
  'vapaeetokens:KANDA': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/KANDA.png',
  'revelation21:SQRL': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/SQRL.png',
  'boidcomtoken:BOID': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/BOID.png',
  'seedsharvest:SEEDS': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/SEEDS.png',
  'qubaboraacnt:QUBE': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/QUBE.png',

  // Stablecoins - Telos token list
  'tethertether:USDT': 'https://raw.githubusercontent.com/telosnetwork/token-list/master/logos/USDT.png',

  // Stablecoins - Trust Wallet assets (for bridged variants)
  'tokens.swaps:USDT': 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xdAC17F958D2ee523a2206206994597C13D831ec7/logo.png',
  'tokens.swaps:USDC': 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/logo.png',

  // Wrapped tokens on Telos Zero
  'tokens.swaps:WBTC': 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599/logo.png',
  'tokens.swaps:WETH': 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png',

  // pTokens bridged assets
  'btc.ptokens:PBTC': 'https://raw.githubusercontent.com/pnetwork-association/token-list/master/logos/pbtc.png',
  'eth.ptokens:PETH': 'https://raw.githubusercontent.com/pnetwork-association/token-list/master/logos/peth.png',
};

/// Get token logo URL for Telos EVM assets (for future EVM support)
String? getEvmTokenLogo(String contractAddress) {
  // Use Trust Wallet assets for EVM tokens
  final address = contractAddress.toLowerCase();
  // Telos EVM chainId is 40
  return 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/telos/assets/$address/logo.png';
}

/// Token balance model for Hyperion API responses
class TokenBalance {
  final String contract;
  final String symbol;
  final String amount;
  final int precision;
  final String? logoUrl;

  TokenBalance({
    required this.contract,
    required this.symbol,
    required this.amount,
    required this.precision,
    this.logoUrl,
  });

  /// Full quantity string (e.g., "100.0000 CLOAK")
  String get quantity => '$amount $symbol';

  /// Numeric amount as double
  double get numericAmount => double.tryParse(amount) ?? 0.0;

  /// Get the best available logo URL for Telos Zero tokens
  String? get bestLogoUrl {
    // Priority 1: Logo from Hyperion API (rarely provided but check first)
    if (logoUrl != null && logoUrl!.isNotEmpty) return logoUrl;

    final key = '$contract:$symbol';

    // Priority 2: Cached token list from GitHub (fetched on-demand)
    final cachedLogo = _getTokenLogoFromCache(contract, symbol);
    if (cachedLogo != null) return cachedLogo;

    // Priority 3: Hardcoded well-known tokens map (fallback)
    if (_wellKnownTokenLogos.containsKey(key)) return _wellKnownTokenLogos[key];

    // Priority 4: Return null - UI will show colored letter fallback
    // This is better than guessing a URL that might 404
    return null;
  }

  factory TokenBalance.fromHyperion(Map<String, dynamic> json) {
    final contract = json['contract'] as String? ?? '';
    final symbol = json['symbol'] as String? ?? '';
    // Some Hyperion responses include logo URL
    String? logoUrl = json['logo'] as String?;
    logoUrl ??= json['logo_url'] as String?;
    logoUrl ??= json['icon'] as String?;

    return TokenBalance(
      contract: contract,
      symbol: symbol,
      amount: json['amount']?.toString() ?? '0',
      precision: json['precision'] as int? ?? 4,
      logoUrl: logoUrl,
    );
  }

  @override
  String toString() => 'TokenBalance($quantity @ $contract)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenBalance &&
          runtimeType == other.runtimeType &&
          contract == other.contract &&
          symbol == other.symbol;

  @override
  int get hashCode => contract.hashCode ^ symbol.hashCode;
}

class EosioClient {
  final String endpoint;
  final http.Client _client;

  /// HTTP timeout for all API calls (prevents hangs on slow/unresponsive endpoints)
  static const _timeout = Duration(seconds: 15);

  EosioClient(this.endpoint) : _client = http.Client();

  /// Get chain info (head block, chain ID, etc.)
  Future<ChainInfo> getInfo() async {
    final response = await _client.post(
      Uri.parse('$endpoint/v1/chain/get_info'),
      headers: {'Content-Type': 'application/json'},
    ).timeout(_timeout);
    
    if (response.statusCode != 200) {
      throw Exception('Failed to get chain info: ${response.statusCode}');
    }
    
    final json = jsonDecode(response.body);
    return ChainInfo.fromJson(json);
  }

  /// Get a specific block by number
  Future<Map<String, dynamic>> getBlock(int blockNum) async {
    final response = await _client.post(
      Uri.parse('$endpoint/v1/chain/get_block'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'block_num_or_id': blockNum}),
    ).timeout(_timeout);
    
    if (response.statusCode != 200) {
      throw Exception('Failed to get block $blockNum: ${response.statusCode}');
    }
    
    return jsonDecode(response.body);
  }

  /// Get multiple blocks in a range (for batch syncing)
  Future<List<Map<String, dynamic>>> getBlocks(int startBlock, int endBlock) async {
    final blocks = <Map<String, dynamic>>[];
    for (int i = startBlock; i <= endBlock; i++) {
      try {
        final block = await getBlock(i);
        blocks.add(block);
      } catch (_) {
        // Continue with next block
      }
    }
    return blocks;
  }

  /// Get table rows from a contract
  Future<Map<String, dynamic>> getTableRows({
    required String code,
    required String scope,
    required String table,
    int limit = 100,
    String lowerBound = '',
    String upperBound = '',
  }) async {
    final response = await _client.post(
      Uri.parse('$endpoint/v1/chain/get_table_rows'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'scope': scope,
        'table': table,
        'json': true,
        'limit': limit,
        'lower_bound': lowerBound,
        'upper_bound': upperBound,
      }),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Failed to get table rows: ${response.statusCode}');
    }

    return jsonDecode(response.body);
  }

  /// Get table rows with secondary index support
  Future<Map<String, dynamic>> getTableRowsWithIndex({
    required String code,
    required String scope,
    required String table,
    int limit = 100,
    String lowerBound = '',
    String upperBound = '',
    String keyType = '',
    int indexPosition = 1,
  }) async {
    final body = <String, dynamic>{
      'code': code,
      'scope': scope,
      'table': table,
      'json': true,
      'limit': limit,
      'lower_bound': lowerBound,
      'upper_bound': upperBound,
    };
    if (keyType.isNotEmpty) {
      body['key_type'] = keyType;
    }
    if (indexPosition > 1) {
      body['index_position'] = indexPosition.toString();
    }

    final response = await _client.post(
      Uri.parse('$endpoint/v1/chain/get_table_rows'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Failed to get table rows: ${response.statusCode} - ${response.body}');
    }

    return jsonDecode(response.body);
  }

  /// Push a signed transaction
  Future<Map<String, dynamic>> pushTransaction(String signedTxJson) async {
    final response = await _client.post(
      Uri.parse('$endpoint/v1/chain/push_transaction'),
      headers: {'Content-Type': 'application/json'},
      body: signedTxJson,
    ).timeout(const Duration(seconds: 30));
    
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception('Failed to push transaction: ${response.statusCode} - ${response.body}');
    }
    
    return jsonDecode(response.body);
  }

  void close() {
    _client.close();
  }

  /// Get action traces for a contract (v1/history/get_actions)
  /// Note: Not all EOSIO endpoints support this. May need Hyperion API.
  /// [skip] - number of actions already processed (for incremental sync)
  Future<List<ZeosActionTrace>> getZeosActions({
    String account = 'thezeosalias',
    int skip = 0,
  }) async {
    // Always use Hyperion v2 API - it supports filtering and returns all matching actions
    // The old v1/history/get_actions only returns the last 100 actions which misses older notes
    return await _getZeosActionsHyperion(account, skip: skip);
  }

  /// Get action history via Hyperion API (more reliable)
  /// [skip] - number of actions to skip (ascending order) for incremental fetch
  /// Paginates automatically to fetch ALL matching actions.
  Future<List<ZeosActionTrace>> _getZeosActionsHyperion(String account, {int skip = 0}) async {
    // Telos Hyperion endpoints
    final hyperionEndpoints = [
      'https://telos.eosusa.io',
      'https://mainnet.telos.caleos.io',
    ];

    for (final hyperion in hyperionEndpoints) {
      try {
        final allActions = <ZeosActionTrace>[];
        int currentSkip = skip;
        const pageSize = 1000;

        while (true) {
          var url = '$hyperion/v2/history/get_actions?account=$account'
              '&filter=*:mint,*:spend,*:publishnotes,*:authenticate'
              '&sort=asc&limit=$pageSize';
          if (currentSkip > 0) url += '&skip=$currentSkip';

          final response = await _client.get(Uri.parse(url)).timeout(_timeout);

          if (response.statusCode != 200) break;

          final json = jsonDecode(response.body);
          final actions = json['actions'] as List? ?? [];
          if (actions.isEmpty) break;

          allActions.addAll(actions.map((a) => ZeosActionTrace.fromHyperionJson(a)));

          // If we got fewer than pageSize, we've reached the end
          if (actions.length < pageSize) break;

          currentSkip += actions.length;
        }

        if (allActions.isNotEmpty) return allActions;
      } catch (_) {
      }
    }

    return [];
  }

  /// Get only NEW merkle tree leaf entries (incremental fetch)
  /// [treeDepth] - depth of the merkle tree (leaf offset = 2^treeDepth - 1)
  /// [startLeafIdx] - first leaf index to fetch (0-based leaf index, not table key)
  Future<List<ZeosMerkleEntry>> getZeosMerkleLeaves({
    required int treeDepth,
    required int startLeafIdx,
  }) async {
    final leafOffset = (1 << treeDepth) - 1; // e.g. 1048575 for depth 20
    final startKey = leafOffset + startLeafIdx;
    final entries = <ZeosMerkleEntry>[];
    String nextKey = startKey.toString();

    while (true) {
      final result = await getTableRows(
        code: 'zeosprotocol',
        scope: 'zeosprotocol',
        table: 'merkletree',
        limit: 100,
        lowerBound: nextKey,
      );

      final rows = result['rows'] as List? ?? [];
      for (final row in rows) {
        final entry = ZeosMerkleEntry.fromJson(row);
        // Only include leaf entries (idx >= leafOffset)
        if (entry.idx >= leafOffset) entries.add(entry);
      }

      final more = result['more'] as bool? ?? false;
      if (!more) break;
      nextKey = result['next_key']?.toString() ?? '';
      if (nextKey.isEmpty) break;
    }

    return entries;
  }

  // ============== ZEOS Protocol Table Queries ==============

  /// Get ZEOS global state (leaf count, tree depth, etc.)
  Future<ZeosGlobal?> getZeosGlobal() async {
    final result = await getTableRows(
      code: 'zeosprotocol',
      scope: 'zeosprotocol',
      table: 'global',
      limit: 1,
    );
    final rows = result['rows'] as List?;
    if (rows == null || rows.isEmpty) return null;
    return ZeosGlobal.fromJson(rows.first);
  }

  /// Get all ZEOS merkle tree entries (note commitments)
  Future<List<ZeosMerkleEntry>> getZeosMerkleTree() async {
    final entries = <ZeosMerkleEntry>[];
    String nextKey = '';

    while (true) {
      final result = await getTableRows(
        code: 'zeosprotocol',
        scope: 'zeosprotocol',
        table: 'merkletree',
        limit: 100,
        lowerBound: nextKey,
      );

      final rows = result['rows'] as List? ?? [];
      for (final row in rows) {
        entries.add(ZeosMerkleEntry.fromJson(row));
      }

      final more = result['more'] as bool? ?? false;
      if (!more) break;
      nextKey = result['next_key']?.toString() ?? '';
      if (nextKey.isEmpty) break;
    }

    return entries;
  }

  /// Get all ZEOS nullifiers (spent notes)
  Future<List<ZeosNullifier>> getZeosNullifiers() async {
    final nullifiers = <ZeosNullifier>[];
    String nextKey = '';

    while (true) {
      final result = await getTableRows(
        code: 'zeosprotocol',
        scope: 'zeosprotocol',
        table: 'nullifiers',
        limit: 100,
        lowerBound: nextKey,
      );

      final rows = result['rows'] as List? ?? [];
      for (final row in rows) {
        nullifiers.add(ZeosNullifier.fromJson(row));
      }

      final more = result['more'] as bool? ?? false;
      if (!more) break;
      nextKey = result['next_key']?.toString() ?? '';
      if (nextKey.isEmpty) break;
    }

    return nullifiers;
  }
}

// ============== ZEOS Data Structures ==============

/// ZEOS 256-bit value represented as 4 64-bit words
class Zeos256 {
  final String w0;
  final String w1;
  final String w2;
  final String w3;

  Zeos256({required this.w0, required this.w1, required this.w2, required this.w3});

  factory Zeos256.fromJson(Map<String, dynamic> json) {
    return Zeos256(
      w0: json['w0']?.toString() ?? '0',
      w1: json['w1']?.toString() ?? '0',
      w2: json['w2']?.toString() ?? '0',
      w3: json['w3']?.toString() ?? '0',
    );
  }

  Map<String, dynamic> toJson() => {'w0': w0, 'w1': w1, 'w2': w2, 'w3': w3};
}

/// ZEOS global state
class ZeosGlobal {
  final int blockNum;
  final int leafCount;
  final int authCount;
  final int treeDepth;
  final List<Zeos256> recentRoots;

  ZeosGlobal({
    required this.blockNum,
    required this.leafCount,
    required this.authCount,
    required this.treeDepth,
    required this.recentRoots,
  });

  factory ZeosGlobal.fromJson(Map<String, dynamic> json) {
    final roots = (json['recent_roots'] as List? ?? [])
        .map((r) => Zeos256.fromJson(r))
        .toList();
    return ZeosGlobal(
      blockNum: json['block_num'] ?? 0,
      leafCount: json['leaf_count'] ?? 0,
      authCount: json['auth_count'] ?? 0,
      treeDepth: json['tree_depth'] ?? 0,
      recentRoots: roots,
    );
  }
}

/// ZEOS merkle tree entry (note commitment)
class ZeosMerkleEntry {
  final int idx;
  final Zeos256 val;

  ZeosMerkleEntry({required this.idx, required this.val});

  factory ZeosMerkleEntry.fromJson(Map<String, dynamic> json) {
    return ZeosMerkleEntry(
      idx: json['idx'] ?? 0,
      val: Zeos256.fromJson(json['val'] ?? {}),
    );
  }
}

/// ZEOS nullifier (spent note)
class ZeosNullifier {
  final Zeos256 val;

  ZeosNullifier({required this.val});

  factory ZeosNullifier.fromJson(Map<String, dynamic> json) {
    return ZeosNullifier(
      val: Zeos256.fromJson(json['val'] ?? {}),
    );
  }
}

class ChainInfo {
  final String chainId;
  final int headBlockNum;
  final String headBlockId;
  final DateTime headBlockTime;
  final int lastIrreversibleBlockNum;

  ChainInfo({
    required this.chainId,
    required this.headBlockNum,
    required this.headBlockId,
    required this.headBlockTime,
    required this.lastIrreversibleBlockNum,
  });

  factory ChainInfo.fromJson(Map<String, dynamic> json) {
    return ChainInfo(
      chainId: json['chain_id'] ?? '',
      headBlockNum: json['head_block_num'] ?? 0,
      headBlockId: json['head_block_id'] ?? '',
      headBlockTime: DateTime.tryParse(json['head_block_time'] ?? '') ?? DateTime.now(),
      lastIrreversibleBlockNum: json['last_irreversible_block_num'] ?? 0,
    );
  }
}

/// ZEOS action trace (from history API)
class ZeosActionTrace {
  final int blockNum;
  final String blockTime;
  final String actionName;
  final String trxId; // Transaction hash
  final List<String> noteCiphertexts; // Base64-encoded encrypted notes

  ZeosActionTrace({
    required this.blockNum,
    required this.blockTime,
    required this.actionName,
    required this.trxId,
    required this.noteCiphertexts,
  });

  /// Parse from v1/history/get_actions response
  factory ZeosActionTrace.fromJson(Map<String, dynamic> json) {
    final action = json['action_trace']?['act'] ?? {};
    final data = action['data'] ?? {};
    final noteCt = data['note_ct'] as List? ?? [];

    return ZeosActionTrace(
      blockNum: json['block_num'] ?? 0,
      blockTime: json['block_time'] ?? '',
      actionName: action['name'] ?? '',
      trxId: json['action_trace']?['trx_id'] ?? '',
      noteCiphertexts: noteCt.map((n) => n.toString()).toList(),
    );
  }

  /// Parse from Hyperion v2/history/get_actions response
  factory ZeosActionTrace.fromHyperionJson(Map<String, dynamic> json) {
    final act = json['act'] ?? {};
    final data = act['data'] ?? {};
    final noteCt = data['note_ct'] as List? ?? [];

    return ZeosActionTrace(
      blockNum: json['block_num'] ?? 0,
      blockTime: json['@timestamp'] ?? json['timestamp'] ?? '',
      actionName: act['name'] ?? '',
      trxId: json['trx_id'] ?? '',
      noteCiphertexts: noteCt.map((n) => n.toString()).toList(),
    );
  }
}

// ============== Static Hyperion API Methods ==============

/// Hyperion endpoints for token queries (multiple for reliability)
const List<String> _hyperionEndpoints = [
  'https://telos.eosusa.io',
  'https://mainnet.telos.caleos.io',
  'https://telos.caleos.io',
];

/// Fetch all token balances for an account using Hyperion API
/// Uses multiple endpoints and retry logic for reliability
///
/// Returns list of all tokens the account holds (any balance > 0)
Future<List<TokenBalance>> getAccountTokens(String accountName) async {
  const maxRetries = 2;

  for (final endpoint in _hyperionEndpoints) {
    for (int retry = 0; retry < maxRetries; retry++) {
      try {
        final url = Uri.parse('$endpoint/v2/state/get_tokens?account=$accountName');

        final response = await http.get(url).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Timeout'),
        );

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tokens = data['tokens'] as List? ?? [];

        final result = tokens
            .map((t) => TokenBalance.fromHyperion(t as Map<String, dynamic>))
            .where((t) => t.numericAmount > 0) // Only tokens with balance
            .toList();

        return result;
      } catch (e) {
        // Small delay before retry
        if (retry < maxRetries - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
  }

  return [];
}

/// Fetch balance for a specific token
Future<TokenBalance?> getTokenBalance(
  String accountName,
  String tokenContract,
  String symbol,
) async {
  final tokens = await getAccountTokens(accountName);
  return tokens.cast<TokenBalance?>().firstWhere(
    (t) => t != null && t.contract == tokenContract && t.symbol == symbol,
    orElse: () => null,
  );
}

/// Get account info (for validating account exists)
Future<Map<String, dynamic>?> getAccount(String accountName) async {
  // Try multiple endpoints for reliability
  final endpoints = [
    'https://telos.eosusa.io',
    'https://mainnet.telos.caleos.io',
    'https://api.telos.kitchen',
  ];

  for (final endpoint in endpoints) {
    try {
      final url = Uri.parse('$endpoint/v1/chain/get_account');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'account_name': accountName}),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      continue;
    }
  }
  return null;
}

/// Check if a token contract is supported for shielding by ZEOS
Future<bool> isTokenSupported(String tokenContract) async {
  // Query zeosprotocol's supported tokens table
  try {
    final client = EosioClient('https://telos.eosusa.io');
    final result = await client.getTableRows(
      code: 'zeosprotocol',
      scope: 'zeosprotocol',
      table: 'tokens',
      lowerBound: tokenContract,
      upperBound: tokenContract,
      limit: 1,
    );
    client.close();

    return (result['rows'] as List?)?.isNotEmpty ?? false;
  } catch (e) {
    print('[EosioClient] isTokenSupported error: $e');
    return false;
  }
}

/// Get protocol fees from blockchain
Future<Map<String, String>> getProtocolFees() async {
  try {
    final client = EosioClient('https://telos.eosusa.io');
    final result = await client.getTableRows(
      code: 'zeosprotocol',
      scope: 'zeosprotocol',
      table: 'fees',
      limit: 10,
    );
    client.close();

    final fees = <String, String>{};
    for (final row in result['rows'] as List? ?? []) {
      final action = row['first']?.toString() ?? '';
      final amount = row['second']?.toString() ?? '';
      if (action.isNotEmpty) {
        fees[action] = amount;
      }
    }

    return fees;
  } catch (e) {
    print('[EosioClient] getProtocolFees error: $e');
    return {};
  }
}

/// Transaction details fetched from Hyperion on-demand
class TransactionDetails {
  final String trxId;
  final int blockNum;
  final String blockTime;
  final String actionName;

  TransactionDetails({
    required this.trxId,
    required this.blockNum,
    required this.blockTime,
    required this.actionName,
  });
}

/// Fetch transaction details from Hyperion by timestamp
/// Queries the ZEOS actions around the given timestamp to find the matching transaction
Future<TransactionDetails?> fetchTransactionDetails(int timestampMs) async {
  final endpoints = [
    'https://telos.eosusa.io',
    'https://mainnet.telos.caleos.io',
  ];

  // Convert timestamp to ISO format with small window (±5 seconds)
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
  final before = dt.add(const Duration(seconds: 5));
  final after = dt.subtract(const Duration(seconds: 5));
  final afterStr = after.toIso8601String().split('.').first;
  final beforeStr = before.toIso8601String().split('.').first;

  for (final endpoint in endpoints) {
    try {
      // Query Hyperion for ZEOS actions in the time window
      final url = '$endpoint/v2/history/get_actions?account=thezeosalias'
          '&filter=*:mint,*:spend,*:publishnotes,*:authenticate'
          '&after=$afterStr&before=$beforeStr'
          '&sort=asc&limit=10';

      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final actions = json['actions'] as List? ?? [];

        if (actions.isNotEmpty) {
          // Find the closest match by timestamp
          TransactionDetails? best;
          int bestDiff = 999999999;

          for (final action in actions) {
            final actionTs = action['@timestamp'] ?? action['timestamp'] ?? '';
            if (actionTs.isEmpty) continue;

            String ts = actionTs;
            if (!ts.endsWith('Z') && !ts.contains('+')) ts += 'Z';
            final actionDt = DateTime.tryParse(ts);
            if (actionDt == null) continue;

            final diff = (actionDt.millisecondsSinceEpoch - timestampMs).abs();
            if (diff < bestDiff) {
              bestDiff = diff;
              best = TransactionDetails(
                trxId: action['trx_id'] ?? '',
                blockNum: action['block_num'] ?? 0,
                blockTime: actionTs,
                actionName: action['act']?['name'] ?? '',
              );
            }
          }

          if (best != null && best.trxId.isNotEmpty) {
            return best;
          }
        }
      }
    } catch (e) {
      // Try next endpoint
    }
  }

  return null;
}
