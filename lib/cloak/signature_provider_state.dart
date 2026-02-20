// Signature Provider State - MobX Store for pending WebSocket signature requests
// Part of Phase 16: WebSocket Signature Provider Implementation

import 'package:mobx/mobx.dart';

part 'signature_provider_state.g.dart';

/// Global instance of the signature provider store
final signatureProviderStore = SignatureProviderStore();

/// Types of signature requests from websites
enum SignatureRequestType {
  login,    // Website wants to authenticate user identity
  sign,     // Website wants to sign a transaction
  balance,  // Website wants to check balance (auto-approve option)
}

/// Status of a signature request
enum SignatureRequestStatus {
  pending,    // Waiting for user approval
  approved,   // User approved, processing response
  rejected,   // User rejected
  completed,  // Successfully sent response
  error,      // Failed to process
}

/// A single signature request from a website
class SignatureRequest {
  final String id;                       // Unique ID: "{clientId}:{jsonRpcId}"
  final SignatureRequestType type;       // login/sign/balance
  final String origin;                   // Website origin (https://app.cloak.today)
  final Map<String, dynamic> params;     // Request parameters from website
  final DateTime timestamp;              // When request received
  SignatureRequestStatus status;         // Current status
  String? response;                      // Response JSON to send back
  String? error;                         // Error message if failed

  SignatureRequest({
    required this.id,
    required this.type,
    required this.origin,
    required this.params,
    required this.timestamp,
    required this.status,
    this.response,
    this.error,
  });

  /// For login requests: get alias authority
  String? get aliasAuthority => params['alias_authority'] as String?;

  /// For login requests: get alias authority public key
  String? get aliasAuthorityPk => params['alias_authority_pk'] as String?;

  /// For login requests: get API nodes
  List<String>? get apiNodes => (params['apiNodes'] as List?)?.cast<String>();

  /// For sign requests: get transaction data
  Map<String, dynamic>? get transaction => params['transaction'] as Map<String, dynamic>?;

  /// Get a human-readable description of the request type
  String get typeDescription {
    switch (type) {
      case SignatureRequestType.login:
        return 'Login Request';
      case SignatureRequestType.sign:
        return 'Sign Transaction';
      case SignatureRequestType.balance:
        return 'Balance Check';
    }
  }
}

/// MobX store for managing signature provider state
class SignatureProviderStore = _SignatureProviderStore with _$SignatureProviderStore;

abstract class _SignatureProviderStore with Store {
  /// All requests (newest first)
  @observable
  ObservableList<SignatureRequest> requests = ObservableList<SignatureRequest>();

  /// Whether the WSS server is running
  @observable
  bool serverRunning = false;

  /// Port the server is listening on
  @observable
  int serverPort = 9367;

  /// Count of pending requests (for badge display)
  @computed
  int get pendingCount => requests.where((r) =>
    r.status == SignatureRequestStatus.pending).length;

  /// Get only pending requests
  @computed
  List<SignatureRequest> get pendingRequests => requests.where((r) =>
    r.status == SignatureRequestStatus.pending).toList();

  /// Add a new request to the store
  @action
  void addRequest(SignatureRequest request) {
    requests.insert(0, request);  // Newest first
  }

  /// Update the status of a request
  @action
  void updateRequestStatus(String id, SignatureRequestStatus status, {String? response, String? error}) {
    final idx = requests.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      requests[idx].status = status;
      requests[idx].response = response;
      requests[idx].error = error;
      // Force MobX to notice the change by replacing the item
      final updated = requests[idx];
      requests.removeAt(idx);
      requests.insert(idx, updated);
    }
  }

  /// Remove a request from the store
  @action
  void removeRequest(String id) {
    requests.removeWhere((r) => r.id == id);
  }

  /// Clear completed and rejected requests
  @action
  void clearCompleted() {
    requests.removeWhere((r) =>
      r.status == SignatureRequestStatus.completed ||
      r.status == SignatureRequestStatus.rejected);
  }

  /// Get a request by ID
  SignatureRequest? getRequest(String id) {
    try {
      return requests.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Mark server as running
  @action
  void setServerRunning(bool running, {int? port}) {
    serverRunning = running;
    if (port != null) serverPort = port;
  }
}
