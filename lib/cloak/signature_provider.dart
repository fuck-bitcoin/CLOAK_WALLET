// Signature Provider - WebSocket Secure (WSS) server for website authentication
// Part of Phase 16: WebSocket Signature Provider Implementation
//
// This allows websites like app.cloak.today to request login and transaction
// signing from this wallet, similar to the official CLOAK GUI.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eosdart/eosdart.dart' as eosdart;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../router.dart' show rootNavigatorKey;
import '../pages/cloak/auth_request_sheet.dart';
import '../pages/utils.dart';
import 'package:cloak_api/cloak_api.dart';
import 'cloak_db.dart';
import 'cloak_wallet_manager.dart';
import 'eosio_client.dart';
import 'esr_service.dart';
import 'signature_provider_state.dart';

/// WebSocket Signature Provider Server
///
/// Listens on wss://127.0.0.1:9367 (same port as official CLOAK GUI)
/// for authentication and signing requests from websites.
class SignatureProvider {
  static HttpServer? _server;
  static final Map<String, WebSocket> _clients = {};
  static final Map<String, String> _clientOrigins = {};  // Store origin per client
  static String? _sslCertPath;
  static String? _sslKeyPath;
  static int _clientCounter = 0;
  static Timer? _watchdog;

  /// Get SSL directory path
  static Future<String> _getSslDir() async {
    final dataDir = await getDbPath();
    final sslDir = p.join(dataDir, 'ssl');
    await Directory(sslDir).create(recursive: true);
    return sslDir;
  }

  /// Ensure SSL certificates exist, generate if needed
  static Future<bool> ensureCertificates() async {
    final sslDir = await _getSslDir();
    final certPath = p.join(sslDir, 'localhost+2.pem');
    _sslKeyPath = p.join(sslDir, 'localhost+2-key.pem');
    _sslCertPath = p.join(sslDir, 'localhost+2-chain.pem');  // Use chain file

    // Check if we already have valid certificates
    // Check for EITHER mkcert-generated (certPath) OR self-signed (chain.pem)
    final hasMkcertCerts = await File(certPath).exists() && await File(_sslKeyPath!).exists();
    final hasSelfSignedCerts = await File(_sslCertPath!).exists() && await File(_sslKeyPath!).exists();

    if (hasMkcertCerts) {
      // Ensure chain file exists (include CA cert for proper chain)
      if (!await File(_sslCertPath!).exists()) {
        await _createCertChain(sslDir, certPath);
      }
      return true;
    }

    if (hasSelfSignedCerts) {
      return true;
    }

    // Try to find mkcert
    final home = Platform.environment['HOME'] ?? '';
    final mkcertPaths = [
      '/opt/cloak-gui/mkcert-linux-amd64',  // From official CLOAK GUI
      'mkcert',  // In PATH
      '/usr/local/bin/mkcert',
      '/usr/bin/mkcert',
      if (home.isNotEmpty) '$home/mkcert',  // User's home directory
      if (home.isNotEmpty) '$home/.local/bin/mkcert',  // XDG local bin
    ];

    String? mkcertPath;
    for (final path in mkcertPaths) {
      try {
        final result = await Process.run(path, ['--version']);
        if (result.exitCode == 0) {
          mkcertPath = path;
          break;
        }
      } catch (_) {}
    }

    if (mkcertPath != null) {
      try {
        // Install CA to system trust store (may require user interaction)
        await Process.run(mkcertPath, ['-install']);

        // Generate certificates for localhost
        final result = await Process.run(mkcertPath, [
          '-cert-file', certPath,
          '-key-file', _sslKeyPath!,
          'localhost', '127.0.0.1', '::1',
        ], workingDirectory: sslDir);

        if (result.exitCode == 0) {
          // Create chain file with CA cert
          await _createCertChain(sslDir, certPath);
          return true;
        } else {
          print('[SignatureProvider] mkcert failed: ${result.stderr}');
        }
      } catch (e) {
        print('[SignatureProvider] Error running mkcert: $e');
      }
    }

    return await _generateSelfSignedCertificate(sslDir);
  }

  /// Create certificate chain file by appending CA cert
  static Future<void> _createCertChain(String sslDir, String certPath) async {
    try {
      // Get mkcert CA root location
      final caRootResult = await Process.run('mkcert', ['-CAROOT']);
      String? caRoot;
      if (caRootResult.exitCode == 0) {
        caRoot = caRootResult.stdout.toString().trim();
      } else {
        // Try alternate mkcert path
        final altResult = await Process.run('/opt/cloak-gui/mkcert-linux-amd64', ['-CAROOT']);
        if (altResult.exitCode == 0) {
          caRoot = altResult.stdout.toString().trim();
        }
      }

      if (caRoot != null && caRoot.isNotEmpty) {
        final caPath = p.join(caRoot, 'rootCA.pem');
        if (await File(caPath).exists()) {
          final cert = await File(certPath).readAsString();
          final ca = await File(caPath).readAsString();
          await File(_sslCertPath!).writeAsString('$cert$ca');
          return;
        }
      }

      // If we can't find CA, just copy the cert as the chain
      await File(certPath).copy(_sslCertPath!);
    } catch (e) {
      print('[SignatureProvider] Error creating cert chain: $e');
      // Fallback: just copy the cert
      try {
        await File(certPath).copy(_sslCertPath!);
      } catch (_) {}
    }
  }

  /// Generate a self-signed certificate using openssl
  static Future<bool> _generateSelfSignedCertificate(String sslDir) async {
    try {
      // Generate private key
      final keyResult = await Process.run('openssl', [
        'genrsa', '-out', _sslKeyPath!, '2048',
      ]);
      if (keyResult.exitCode != 0) {
        print('[SignatureProvider] Failed to generate key: ${keyResult.stderr}');
        return false;
      }

      // Try modern openssl first (with -addext for SAN)
      var certResult = await Process.run('openssl', [
        'req', '-new', '-x509',
        '-key', _sslKeyPath!,
        '-out', _sslCertPath!,
        '-days', '365',
        '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1',
      ]);

      // If -addext not supported, try simpler version
      if (certResult.exitCode != 0) {
        certResult = await Process.run('openssl', [
          'req', '-new', '-x509',
          '-key', _sslKeyPath!,
          '-out', _sslCertPath!,
          '-days', '365',
          '-subj', '/CN=localhost',
        ]);
      }

      if (certResult.exitCode != 0) {
        print('[SignatureProvider] Failed to generate cert: ${certResult.stderr}');
        return false;
      }

      return true;
    } catch (e) {
      print('[SignatureProvider] Error generating self-signed cert: $e');
      return false;
    }
  }

  /// Start the WSS server with automatic watchdog restart
  static Future<bool> start({int port = 9367}) async {
    if (_server != null) {
      _startWatchdog(port);
      return true;  // Already running
    }

    // Ensure certificates exist
    if (!await ensureCertificates()) {
      print('[SignatureProvider] Cannot start - no SSL certificates');
      return false;
    }

    try {
      final context = SecurityContext()
        ..useCertificateChain(_sslCertPath!)
        ..usePrivateKey(_sslKeyPath!);

      _server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        port,
        context,
      );

      _server!.listen(_handleHttpRequest, onError: (e) {
        _server = null;
        signatureProviderStore.setServerRunning(false);
      }, onDone: () {
        _server = null;
        signatureProviderStore.setServerRunning(false);
      });

      signatureProviderStore.setServerRunning(true, port: port);
      _startWatchdog(port);

      print('[SignatureProvider] WSS listening on wss://127.0.0.1:$port');
      return true;
    } on SocketException catch (e) {
      if (e.osError?.errorCode == 98 || e.message.contains('Address already in use')) {
        print('[SignatureProvider] Port $port is already in use!');
        print('[SignatureProvider] Is the official CLOAK GUI running? Close it first.');
      } else {
        print('[SignatureProvider] Socket error: $e');
      }
      _startWatchdog(port);
      return false;
    } catch (e) {
      print('[SignatureProvider] Failed to start: $e');
      if (e.toString().contains('HandshakeException') ||
          e.toString().contains('CERTIFICATE') ||
          e.toString().contains('certificate')) {
        print('[SignatureProvider] SSL certificate error - try deleting data/ssl/ and restarting');
      }
      _startWatchdog(port);
      return false;
    }
  }

  /// Start the watchdog timer that ensures the server stays running
  static void _startWatchdog(int port) {
    if (_watchdog != null) return; // Already watching
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_server == null) {
        print('[SignatureProvider] Watchdog: server is down, restarting...');
        _watchdog?.cancel();
        _watchdog = null;
        await start(port: port);
      }
    });
  }

  /// Stop the server and watchdog
  static Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;

    for (final socket in _clients.values) {
      try {
        await socket.close();
      } catch (_) {}
    }
    _clients.clear();

    await _server?.close();
    _server = null;

    signatureProviderStore.setServerRunning(false);
  }

  /// Check if server is running
  static bool get isRunning => _server != null;

  /// Handle incoming HTTP requests (upgrade to WebSocket)
  static void _handleHttpRequest(HttpRequest request) async {
    // Set CORS headers for WebSocket upgrade
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET');
    request.response.headers.add('Access-Control-Allow-Headers', 'content-type');

    if (WebSocketTransformer.isUpgradeRequest(request)) {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        final clientId = _generateClientId();
        _clients[clientId] = socket;

        // Capture origin from HTTP headers for display in auth dialogs
        final origin = request.headers.value('origin') ?? request.headers.value('Origin');
        if (origin != null && origin.isNotEmpty) {
          _clientOrigins[clientId] = _formatOrigin(origin);
        }

        socket.listen(
          (data) => _handleMessage(clientId, data),
          onDone: () {
            _clients.remove(clientId);
            _clientOrigins.remove(clientId);
          },
          onError: (e) {
            _clients.remove(clientId);
            _clientOrigins.remove(clientId);
            print('[SignatureProvider] Client error: $e');
          },
        );
      } catch (e) {
        print('[SignatureProvider] WebSocket upgrade failed: $e');
      }
    } else {
      // Return basic info for HTTP requests
      request.response.write('CLOAK Wallet Signature Provider\nWSS on port ${signatureProviderStore.serverPort}');
      await request.response.close();
    }
  }

  /// Generate a unique client ID
  static String _generateClientId() {
    _clientCounter++;
    return '${DateTime.now().millisecondsSinceEpoch}_$_clientCounter';
  }

  /// Format origin URL for display (extract domain, clean up)
  static String _formatOrigin(String origin) {
    try {
      final uri = Uri.parse(origin);
      // Return just the host, or host:port if non-standard port
      final host = uri.host;
      if (host.isEmpty) return origin;
      if (uri.port != 80 && uri.port != 443 && uri.port != 0) {
        return '$host:${uri.port}';
      }
      return host;
    } catch (_) {
      return origin;
    }
  }

  /// Get origin for a client (from stored header or params)
  static String _getOrigin(String clientId, Map<String, dynamic> params) {
    // Prefer origin from params if provided
    final paramOrigin = params['origin'] as String?;
    if (paramOrigin != null && paramOrigin.isNotEmpty && paramOrigin != 'Unknown') {
      return _formatOrigin(paramOrigin);
    }
    // Fall back to stored origin from WebSocket connection
    return _clientOrigins[clientId] ?? 'localhost';
  }

  /// Handle incoming WebSocket message
  static void _handleMessage(String clientId, dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      // Website uses "request" field, not "method"
      final method = json['request'] as String? ?? json['method'] as String?;
      final id = json['id'];
      final params = json['params'] as Map<String, dynamic>? ?? {};

      switch (method) {
        case 'login':
          _handleLoginRequest(clientId, id, params);
          break;
        case 'sign':
          _handleSignRequest(clientId, id, params);
          break;
        case 'all_balances':
          _handleAllBalancesRequest(clientId, id, params);
          break;
        case 'balances':
          _handleFilteredBalancesRequest(clientId, id, params);
          break;
        case 'transact':
          _handleTransactRequest(clientId, id, params);
          break;
        case 'getBalance':
        case 'get_balance':
          _handleBalanceRequest(clientId, id, params);
          break;
        case 'getVaults':
        case 'get_vaults':
        case 'listVaults':
        case 'list_vaults':
          _handleGetVaultsRequest(clientId, id, params);
          break;
        case 'getAuthTokens':
        case 'get_auth_tokens':
          _handleGetAuthTokensRequest(clientId, id, params);
          break;
        case 'getUnpublishedNotes':
        case 'get_unpublished_notes':
          _handleGetUnpublishedNotesRequest(clientId, id, params);
          break;
        default:
          _sendError(clientId, id, -32601, 'Method not found: $method');
      }
    } catch (e) {
      print('[SignatureProvider] Error parsing message: $e');
    }
  }

  /// Handle login request
  static void _handleLoginRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    final requestId = '$clientId:$id';

    final request = SignatureRequest(
      id: requestId,
      type: SignatureRequestType.login,
      origin: _getOrigin(clientId, params),
      params: params,
      timestamp: DateTime.now(),
      status: SignatureRequestStatus.pending,
    );

    signatureProviderStore.addRequest(request);
    _notifyNewRequest(request);
  }

  /// Handle sign request
  static void _handleSignRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    final requestId = '$clientId:$id';

    final request = SignatureRequest(
      id: requestId,
      type: SignatureRequestType.sign,
      origin: _getOrigin(clientId, params),
      params: params,
      timestamp: DateTime.now(),
      status: SignatureRequestStatus.pending,
    );

    signatureProviderStore.addRequest(request);
    _notifyNewRequest(request);
  }

  /// Handle balance request (auto-approve - read only)
  static void _handleBalanceRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    // Balance requests can be auto-approved (read-only, no user interaction needed)
    final balanceJson = CloakWalletManager.getBalancesJson();
    if (balanceJson != null) {
      try {
        final balance = jsonDecode(balanceJson);
        _sendResponse(clientId, id, {'balance': balance});
      } catch (e) {
        _sendError(clientId, id, -32000, 'Failed to get balance: $e');
      }
    } else {
      _sendError(clientId, id, -32000, 'Wallet not loaded');
    }
  }

  /// Handle get vaults request (auto-approve - read only)
  static void _handleGetVaultsRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    final vaultsJson = CloakWalletManager.getAuthenticationTokensJson();
    if (vaultsJson != null) {
      try {
        final vaults = jsonDecode(vaultsJson);
        _sendResponse(clientId, id, {'status': 'success', 'vaults': vaults});
      } catch (e) {
        _sendError(clientId, id, -32000, 'Failed to get vaults: $e');
      }
    } else {
      // Return empty array instead of error - wallet may just have no vaults yet
      _sendResponse(clientId, id, {'status': 'success', 'vaults': []});
    }
  }

  /// Handle get auth tokens request (auto-approve - read only)
  static void _handleGetAuthTokensRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    final contract = params['contract'] as int? ?? 0;
    final spent = params['spent'] as bool? ?? false;
    final tokensJson = CloakWalletManager.getAuthenticationTokensJson(contract: contract, spent: spent);
    if (tokensJson != null) {
      try {
        final tokens = jsonDecode(tokensJson);
        _sendResponse(clientId, id, {'status': 'success', 'tokens': tokens});
      } catch (e) {
        _sendError(clientId, id, -32000, 'Failed to get auth tokens: $e');
      }
    } else {
      _sendResponse(clientId, id, {'status': 'success', 'tokens': []});
    }
  }

  /// Handle get unpublished notes request (auto-approve - read only)
  static void _handleGetUnpublishedNotesRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    final notesJson = CloakWalletManager.getUnpublishedNotesJson();
    if (notesJson != null) {
      try {
        final notes = jsonDecode(notesJson);
        _sendResponse(clientId, id, {'status': 'success', 'notes': notes});
      } catch (e) {
        _sendError(clientId, id, -32000, 'Failed to get unpublished notes: $e');
      }
    } else {
      _sendResponse(clientId, id, {'status': 'success', 'notes': {}});
    }
  }

  /// Handle all_balances request from app.cloak.today
  /// Returns {fts: ["1.0000 CLOAK@thezeostoken", ...], nfts: [...], ats: [...]}
  static void _handleAllBalancesRequest(String clientId, dynamic id, Map<String, dynamic> params) async {
    final includeFt = params['ft'] as bool? ?? true;
    final includeNft = params['nft'] as bool? ?? true;
    final includeAt = params['at'] as bool? ?? true;

    try {
      final result = await _buildBalancesResult(
        includeFt: includeFt,
        includeNft: includeNft,
        includeAt: includeAt,
      );
      _sendResponse(clientId, id, {'status': 'success', 'result': result});
    } catch (e) {
      print('[SignatureProvider] all_balances error: $e');
      _sendError(clientId, id, -32000, 'Failed to get balances: $e');
    }
  }

  /// Handle filtered balances request from app.cloak.today
  static void _handleFilteredBalancesRequest(String clientId, dynamic id, Map<String, dynamic> params) async {
    try {
      final result = await _buildBalancesResult(
        includeFt: params.containsKey('ft_symbols'),
        includeNft: params.containsKey('nft_contract'),
        includeAt: params.containsKey('at_contract'),
      );
      _sendResponse(clientId, id, {'status': 'success', 'result': result});
    } catch (e) {
      print('[SignatureProvider] balances error: $e');
      _sendError(clientId, id, -32000, 'Failed to get balances: $e');
    }
  }

  /// Build the balances result object: {fts: [...], nfts: [...], ats: [...]}
  /// Format: fts = ["1.0000 CLOAK@thezeostoken"], ats = ["<hash>@<contract>"]
  ///
  /// Sends all unspent auth tokens to the web app. The web app queries
  /// thezeosvault on-chain to check for deposits and handles unfunded
  /// vaults gracefully (shows 0 balance).
  ///
  /// Only auth tokens whose commitment hash exists in the SQLite vaults table
  /// are sent to the web app. This filters out orphaned auth tokens (e.g.,
  /// imported from CLOAK GUI but never associated with a vault deposit).
  static Future<Map<String, dynamic>> _buildBalancesResult({
    bool includeFt = true,
    bool includeNft = true,
    bool includeAt = true,
  }) async {
    final fts = <String>[];
    final nfts = <String>[];
    final ats = <String>[];
    final spentAts = <String>[];

    if (includeFt) {
      final balancesJson = CloakWalletManager.getBalancesJson();
      if (balancesJson != null) {
        try {
          final balances = jsonDecode(balancesJson);
          if (balances is List) {
            // Format: ["1.0000 CLOAK@thezeostoken"]
            for (final b in balances) {
              if (b is String) {
                // Already in "amount SYMBOL@contract" format if from Rust
                fts.add(b);
              } else if (b is Map) {
                // If Rust returns structured data, format it
                final amount = b['amount']?.toString() ?? '0';
                final symbol = b['symbol']?.toString() ?? 'CLOAK';
                final contract = b['contract']?.toString() ?? 'thezeostoken';
                fts.add('$amount $symbol@$contract');
              }
            }
          }
        } catch (e) {
          print('[SignatureProvider] Error parsing FT balances: $e');
        }
      }
    }

    if (includeAt) {
      final tokensJson = CloakWalletManager.getAuthenticationTokensJson();
      // Also check spent auth tokens
      final spentJson = CloakWalletManager.getAuthenticationTokensJson(spent: true);

      // DB is the authoritative source for which vaults the user has.
      // Rust wallet auth tokens may lag behind (timing, wallet recreation, etc.)
      final dbVaults = await CloakDb.getAllVaults();
      final knownHashes = dbVaults.map((v) => (v['commitment_hash'] as String).toLowerCase()).toSet();

      // Track which DB vaults we find in the Rust wallet
      final foundHashes = <String>{};

      if (tokensJson != null) {
        try {
          final tokens = jsonDecode(tokensJson);
          if (tokens is List) {
            for (final t in tokens) {
              String hash = '';
              if (t is Map) {
                hash = t['hash']?.toString() ?? t['commitment']?.toString() ?? '';
              } else if (t is String) {
                hash = t.contains('@') ? t.split('@')[0] : t;
              }
              if (hash.isEmpty) continue;
              // Only include auth tokens that exist in the vaults DB table.
              // This filters out orphaned tokens (e.g., imported from CLOAK GUI
              // but never associated with a user-managed vault).
              if (!knownHashes.contains(hash.toLowerCase())) {
                continue;
              }
              ats.add('$hash@thezeosvault');
              foundHashes.add(hash.toLowerCase());
            }
          }
        } catch (e) {
          print('[SignatureProvider] Error parsing auth tokens: $e');
        }
      }

      // Build spent auth tokens list (same filtering against DB)
      if (spentJson != null) {
        try {
          final spentTokens = jsonDecode(spentJson);
          if (spentTokens is List) {
            for (final t in spentTokens) {
              String hash = '';
              if (t is Map) {
                hash = t['hash']?.toString() ?? t['commitment']?.toString() ?? '';
              } else if (t is String) {
                hash = t.contains('@') ? t.split('@')[0] : t;
              }
              if (hash.isEmpty) continue;
              if (!knownHashes.contains(hash.toLowerCase())) continue;
              spentAts.add('$hash@thezeosvault');
            }
          }
        } catch (e) {
          print('[SignatureProvider] Error parsing spent auth tokens: $e');
        }
      }

      // Track spent hashes so DB fallback doesn't duplicate them
      final spentHashSet = spentAts.map((s) => s.split('@')[0].toLowerCase()).toSet();

      // Add any DB vaults not found in the Rust wallet (unspent or spent).
      // This handles timing issues (reimport hasn't run yet) and
      // cases where authenticate consumed the auth token.
      for (final dbHash in knownHashes) {
        if (!foundHashes.contains(dbHash) && !spentHashSet.contains(dbHash)) {
          ats.add('$dbHash@thezeosvault');
        }
      }
    }

    return {'fts': fts, 'nfts': nfts, 'ats': {'unspent': ats, 'spent': spentAts}};
  }

  /// Handle transact request from app.cloak.today
  /// Receives zactions, generates ZK proofs, signs with alias key, broadcasts
  static void _handleTransactRequest(String clientId, dynamic id, Map<String, dynamic> params) {
    // Show approval dialog for transactions (they move funds)
    final requestId = '$clientId:$id';
    final request = SignatureRequest(
      id: requestId,
      type: SignatureRequestType.sign,
      origin: 'app.cloak.today',
      params: params,
      timestamp: DateTime.now(),
      status: SignatureRequestStatus.pending,
    );

    // Store the transact params so the approval handler can execute them
    _pendingTransacts[requestId] = params;

    signatureProviderStore.addRequest(request);
    _notifyNewRequest(request);
  }

  /// Pending transact requests awaiting user approval
  static final Map<String, Map<String, dynamic>> _pendingTransacts = {};

  /// Get pending transact params for a request (and remove from pending)
  static Map<String, dynamic>? getPendingTransact(String requestId) {
    return _pendingTransacts.remove(requestId);
  }

  /// Execute a transact request after user approval
  /// Called from auth_request_sheet when user approves a transact/sign request
  static Future<Map<String, dynamic>> executeTransact(Map<String, dynamic> params) async {
    // Ensure ZK params are loaded
    if (!await CloakWalletManager.loadZkParams()) {
      throw Exception('Failed to load ZK params');
    }

    // Pre-process: ABI-serialize action data in authenticate zactions.
    // The web app sends action data as JSON objects, but Rust's PackedActionDesc
    // expects data as a hex string (ABI-serialized binary).
    await _abiSerializeAuthenticateActions(params);

    // Build ZTransaction JSON from the web app's params
    final ztxJson = jsonEncode(params);

    // Get fees
    final feesJson = await CloakWalletManager.getFeesJsonPublic();

    // Sync auth_count from on-chain BEFORE proof generation
    // This is CRITICAL: auth_hash = Blake2s(auth_count || packed_actions)
    // If wallet's auth_count doesn't match chain, authenticate proofs fail
    final wallet = CloakWalletManager.wallet;
    if (wallet != null) {
      try {
        final endpoint = 'https://telos.eosusa.io';
        final eosClient = EosioClient(endpoint);
        final global = await eosClient.getZeosGlobal();
        eosClient.close();
        if (global != null) {
          final walletAC = CloakApi.getAuthCount(wallet) ?? 0;
          if (walletAC != global.authCount) {
            CloakApi.setAuthCount(wallet, global.authCount);
          }
        }
      } catch (e) {
        print('[SignatureProvider] Warning: could not sync auth_count: $e');
      }
    }

    // Generate ZK proof + unsigned transaction via Rust FFI
    final txJson = CloakWalletManager.transactPackedPublic(
      ztxJson: ztxJson,
      feesJson: feesJson,
    );

    if (txJson == null) {
      final rustError = CloakWalletManager.getLastErrorPublic();
      print('[SignatureProvider] ZK proof generation failed: $rustError');
      throw Exception('ZK proof generation failed: $rustError');
    }

    // Parse the transaction
    final decoded = jsonDecode(txJson);
    final Map<String, dynamic> tx;
    if (decoded is List && decoded.isNotEmpty) {
      tx = Map<String, dynamic>.from(decoded[0] as Map);
    } else if (decoded is Map) {
      tx = Map<String, dynamic>.from(decoded as Map);
    } else {
      throw Exception('Unexpected transactPacked response format');
    }

    // Set transaction headers
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200) throw Exception('get_info failed');
      final chainInfo = jsonDecode(await response.transform(const Utf8Decoder()).join()) as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4, (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 | prefixBytes[2] << 16 | prefixBytes[1] << 8 | prefixBytes[0];

      final expiration = DateTime.now().toUtc().add(const Duration(minutes: 10));
      tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
      tx['ref_block_num'] = refBlockNum;
      tx['ref_block_prefix'] = refBlockPrefix;
      tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
      tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
      tx['delay_sec'] = tx['delay_sec'] ?? 0;
      tx['context_free_actions'] = tx['context_free_actions'] ?? [];
      tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];
    } finally {
      client.close();
    }

    // Use hex_data for action serialization
    final actions = tx['actions'] as List? ?? [];
    for (final action in actions) {
      if (action is Map && action['hex_data'] != null) {
        action['data'] = action['hex_data'] as String;
      }
    }

    // Sign with thezeosalias@public key
    final signatures = await EsrTransactionHelper.signWithAliasKey(
      transaction: tx,
      existingSignatures: [],
    );

    // Broadcast
    final result = await EsrTransactionHelper.broadcastTransaction(
      transaction: tx,
      signatures: signatures,
    );

    final txId = result['transaction_id'] as String? ?? 'unknown';

    // Save wallet state
    await CloakWalletManager.saveWallet();

    return {'status': 'success', 'result': txId};
  }

  /// ABI-serialize action data in authenticate zactions.
  /// The web app sends action data as JSON objects (maps), but Rust's
  /// PackedActionDesc expects data as a hex string (ABI-serialized binary).
  /// Since abi_json_to_bin is deprecated on Telos nodes, we serialize manually.
  static Future<void> _abiSerializeAuthenticateActions(Map<String, dynamic> params) async {
    final zactions = params['zactions'] as List?;
    if (zactions == null) return;

    for (final zaction in zactions) {
      if (zaction is! Map) continue;
      if (zaction['name'] != 'authenticate') continue;

      final data = zaction['data'];
      if (data is! Map) continue;

      // Remove 'contract' field — AuthenticateDesc doesn't have it.
      data.remove('contract');

      final actions = data['actions'] as List?;
      if (actions == null) continue;

      for (int i = 0; i < actions.length; i++) {
        final action = actions[i];
        if (action is! Map) continue;

        final actionData = action['data'];
        if (actionData is! Map) continue; // Already a string = already serialized

        final account = action['account']?.toString() ?? '';
        final actionName = action['name']?.toString() ?? '';
        final hexData = _serializeActionDataToHex(account, actionName, actionData);
        action['data'] = hexData;
      }
    }
  }

  /// Manually serialize EOSIO action data to hex.
  /// Handles known action types for vault operations.
  static String _serializeActionDataToHex(String account, String actionName, Map actionData) {
    final sb = eosdart.SerialBuffer(Uint8List(0));

    if (actionName == 'withdrawp') {
      // withdrawp { transfers: pair<name, variant<fungible_transfer_params, ...>>[] }
      final transfers = actionData['transfers'] as List? ?? [];
      sb.pushVaruint32(transfers.length);

      for (final transfer in transfers) {
        if (transfer is! List || transfer.length != 2) continue;

        // First element: contract name (e.g., "thezeostoken")
        final contractName = transfer[0].toString();
        sb.pushName(contractName);

        // Second element: variant [type_name, data]
        final variant = transfer[1] as List;
        final variantType = variant[0].toString();
        final variantData = variant[1] as Map;

        // Variant index: fungible=0, atomic=1, uniq=2
        int variantIdx = 0;
        if (variantType == 'atomic_transfer_params') variantIdx = 1;
        if (variantType == 'uniq_transfer_params') variantIdx = 2;
        sb.pushVaruint32(variantIdx);

        if (variantType == 'fungible_transfer_params') {
          sb.pushName(variantData['from']?.toString() ?? '');
          sb.pushName(variantData['to']?.toString() ?? '');
          sb.pushAsset(variantData['quantity']?.toString() ?? '0.0000 CLOAK');
          sb.pushString(variantData['memo']?.toString() ?? '');
        } else if (variantType == 'atomic_transfer_params') {
          sb.pushName(variantData['from']?.toString() ?? '');
          sb.pushName(variantData['to']?.toString() ?? '');
          final assetIds = variantData['asset_ids'] as List? ?? [];
          sb.pushVaruint32(assetIds.length);
          for (final id in assetIds) {
            sb.pushNumberAsUint64(int.parse(id.toString()));
          }
          sb.pushString(variantData['memo']?.toString() ?? '');
        }
      }
    } else {
      // Fallback: try JSON encoding (will likely fail in Rust but provides debug info)
      print('[SignatureProvider] WARNING: Unknown action $account::$actionName — cannot serialize');
      final jsonStr = jsonEncode(actionData);
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonStr));
      sb.pushArray(jsonBytes);
    }

    return bytesToHex(sb.asUint8List());
  }

  /// Send success response
  /// Include request id so website can correlate response with request
  static void _sendResponse(String clientId, dynamic id, Map<String, dynamic> result) {
    final socket = _clients[clientId];
    if (socket == null) return;

    try {
      // Include id for request correlation, plus the result fields
      final response = jsonEncode({
        'id': id,
        ...result,
      });
      socket.add(response);
    } catch (e) {
      print('[SignatureProvider] Error sending response: $e');
    }
  }

  /// Send error response
  /// Include request id so website can correlate response with request
  static void _sendError(String clientId, dynamic id, int code, String message) {
    final socket = _clients[clientId];
    if (socket == null) return;

    try {
      // Include id for request correlation
      final response = jsonEncode({
        'id': id,
        'status': 'error',
        'error': message,
      });
      socket.add(response);
    } catch (e) {
      print('[SignatureProvider] Error sending error response: $e');
    }
  }

  /// Send response for a stored request (called after user approves)
  static void sendRequestResponse(String requestId, Map<String, dynamic> result) {
    final parts = requestId.split(':');
    if (parts.length < 2) return;

    final clientId = parts[0];
    // The ID could be a number or string - try to parse as int first
    final idPart = parts.sublist(1).join(':');
    final id = int.tryParse(idPart) ?? idPart;

    _sendResponse(clientId, id, result);
    signatureProviderStore.updateRequestStatus(
      requestId,
      SignatureRequestStatus.completed,
      response: jsonEncode(result),
    );
  }

  /// Send rejection for a stored request (called when user declines)
  static void sendRequestRejection(String requestId, String reason) {
    final parts = requestId.split(':');
    if (parts.length < 2) return;

    final clientId = parts[0];
    final idPart = parts.sublist(1).join(':');
    final id = int.tryParse(idPart) ?? idPart;

    _sendError(clientId, id, -32000, reason);
    signatureProviderStore.updateRequestStatus(
      requestId,
      SignatureRequestStatus.rejected,
      error: reason,
    );
  }

  /// Notify about a new request - show bottom sheet
  static void _notifyNewRequest(SignatureRequest request) {
    if (CloakWalletManager.isViewOnly) {
      print('[SignatureProvider] Auth request suppressed for view-only wallet');
      sendRequestRejection(request.id, 'View-only wallet cannot sign');
      return;
    }

    // Schedule on main UI thread
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        try {
          showAuthRequestSheet(context, request);
        } catch (e) {
          print('[SignatureProvider] Failed to show auth sheet: $e');
        }
      }
    });
  }
}
