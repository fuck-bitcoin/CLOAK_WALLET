// Anchor Link Client - WebSocket-based communication with Anchor wallet
//
// This implements the Anchor Link protocol for sending signing requests
// to Anchor wallet via the cb.anchor.link relay server.
//
// Protocol spec: https://github.com/greymass/anchor-link/blob/master/protocol.md

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

/// Anchor Link relay server URL
const String ANCHOR_LINK_SERVICE = 'wss://cb.anchor.link';

/// Request types for Anchor Link
enum AnchorLinkRequestType {
  identity,
  transaction,
}

/// Status of an Anchor Link session
enum AnchorLinkStatus {
  disconnected,
  connecting,
  waitingForWallet,
  processing,
  completed,
  error,
}

/// Callback for status updates
typedef AnchorLinkStatusCallback = void Function(AnchorLinkStatus status, String? message);

/// Anchor Link client for WebSocket-based communication with Anchor
class AnchorLinkClient {
  final String chainId;
  final AnchorLinkStatusCallback? onStatusChange;

  WebSocketChannel? _channel;
  String? _channelId;
  Completer<Map<String, dynamic>?>? _responseCompleter;
  Timer? _pingTimer;
  AnchorLinkStatus _status = AnchorLinkStatus.disconnected;

  AnchorLinkClient({
    required this.chainId,
    this.onStatusChange,
  });

  /// Current status
  AnchorLinkStatus get status => _status;

  /// Current channel ID (available after connection starts)
  String? get channelId => _channelId;

  /// Connect to the Anchor Link relay and generate a channel ID.
  /// Call this first to get the channel ID for the QR code, then call
  /// waitForResponse() to listen for the signed transaction.
  Future<bool> connect() async {
    try {
      _setStatus(AnchorLinkStatus.connecting, 'Connecting to Anchor Link...');

      // Generate a unique channel ID
      _channelId = const Uuid().v4();
      final channelUrl = '$ANCHOR_LINK_SERVICE/$_channelId';

      // Connect to the relay
      _channel = WebSocketChannel.connect(Uri.parse(channelUrl));

      // Wait for connection to establish
      await _channel!.ready;

      _setStatus(AnchorLinkStatus.waitingForWallet, 'Waiting for Anchor wallet...');

      // Set up response completer
      _responseCompleter = Completer<Map<String, dynamic>?>();

      // Listen for messages
      _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          _setStatus(AnchorLinkStatus.error, 'Connection error: $error');
          if (!_responseCompleter!.isCompleted) {
            _responseCompleter?.complete(null);
          }
        },
        onDone: () {
          if (!_responseCompleter!.isCompleted) {
            _responseCompleter?.complete(null);
          }
        },
      );

      // Start ping timer to keep connection alive
      _startPingTimer();

      return true;
    } catch (e) {
      _setStatus(AnchorLinkStatus.error, 'Error: $e');
      return false;
    }
  }

  /// Wait for the signed transaction response after connect() was called.
  /// The user should scan the QR code (which includes the channel ID)
  /// with Anchor wallet, and the response will come back via WebSocket.
  Future<Map<String, dynamic>?> waitForResponse({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_responseCompleter == null) {
      return null;
    }

    try {
      // Wait for response with timeout
      final response = await _responseCompleter!.future.timeout(
        timeout,
        onTimeout: () {
          _setStatus(AnchorLinkStatus.error, 'Request timed out');
          return null;
        },
      );

      if (response != null) {
        _setStatus(AnchorLinkStatus.completed, 'Transaction signed!');
      }

      return response;
    } catch (e) {
      _setStatus(AnchorLinkStatus.error, 'Error: $e');
      return null;
    } finally {
      await close();
    }
  }

  /// Send a signing request to Anchor via the relay
  ///
  /// [esrUrl] - The ESR URL to sign
  /// [timeout] - How long to wait for response (default 5 minutes)
  ///
  /// Returns the signed transaction response, or null if cancelled/timeout
  Future<Map<String, dynamic>?> sendSigningRequest(
    String esrUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    try {
      // Connect first
      final connected = await connect();
      if (!connected) {
        return null;
      }

      // Send the signing request
      final request = _buildSigningRequest(esrUrl);
      _channel!.sink.add(request);

      // Wait for response
      return await waitForResponse(timeout: timeout);
    } catch (e) {
      _setStatus(AnchorLinkStatus.error, 'Error: $e');
      return null;
    }
  }

  /// Close the connection
  Future<void> close() async {
    _pingTimer?.cancel();
    _pingTimer = null;

    await _channel?.sink.close();
    _channel = null;
    _channelId = null;

    _setStatus(AnchorLinkStatus.disconnected, null);
  }

  /// Cancel the current request
  void cancel() {
    if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
      _responseCompleter?.complete(null);
    }
    close();
  }

  void _setStatus(AnchorLinkStatus status, String? message) {
    _status = status;
    onStatusChange?.call(status, message);
  }

  void _handleMessage(dynamic data) {
    try {
      if (data is String) {
        final json = jsonDecode(data) as Map<String, dynamic>;

        // Check for error
        if (json.containsKey('error')) {
          _setStatus(AnchorLinkStatus.error, json['error'].toString());
          _responseCompleter?.complete(null);
          return;
        }

        // Check for signed transaction response
        if (json.containsKey('signatures') || json.containsKey('transaction')) {
          _setStatus(AnchorLinkStatus.processing, 'Processing response...');
          _responseCompleter?.complete(json);
          return;
        }

        // Check for identity response
        if (json.containsKey('identity') || json.containsKey('signer')) {
          _setStatus(AnchorLinkStatus.processing, 'Wallet connected!');
          _responseCompleter?.complete(json);
          return;
        }

        // Acknowledgment or other message
      }
    } catch (_) {
    }
  }

  void _startPingTimer() {
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_channel != null) {
        // Send ping to keep connection alive
        _channel!.sink.add('ping');
      }
    });
  }

  /// Build the signing request payload
  String _buildSigningRequest(String esrUrl) {
    // The request format for Anchor Link relay
    // The ESR URL is sent as-is to the relay, which forwards it to Anchor
    final request = {
      'type': 'signing_request',
      'request': esrUrl,
      'chain_id': chainId,
    };
    return jsonEncode(request);
  }

  /// Generate a QR code data URL for scanning with Anchor mobile
  ///
  /// The ESR URL is a base64url-encoded payload (esr://...). Appending
  /// "&channel=..." directly to it corrupts the base64 payload since '&'
  /// is not a valid base64url character and the decoder would fail.
  ///
  /// Instead, the channel information is communicated via the WebSocket
  /// relay protocol (the client connects to wss://cb.anchor.link/{channelId}
  /// and Anchor responds on that same channel). The QR code should contain
  /// only the pure ESR URL.
  static String generateQrData(String esrUrl, String channelId) {
    // Return the ESR URL as-is - channel communication happens via WebSocket relay
    // The channelId parameter is kept for API compatibility but not appended
    return esrUrl;
  }
}

/// Result of an Anchor Link signing request
class AnchorLinkResult {
  final bool success;
  final Map<String, dynamic>? transaction;
  final List<String>? signatures;
  final String? error;

  AnchorLinkResult({
    required this.success,
    this.transaction,
    this.signatures,
    this.error,
  });

  factory AnchorLinkResult.fromResponse(Map<String, dynamic>? response) {
    if (response == null) {
      return AnchorLinkResult(success: false, error: 'No response');
    }

    if (response.containsKey('error')) {
      return AnchorLinkResult(success: false, error: response['error'].toString());
    }

    return AnchorLinkResult(
      success: true,
      transaction: response['transaction'] as Map<String, dynamic>?,
      signatures: (response['signatures'] as List?)?.cast<String>(),
    );
  }
}
