import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

enum PendingWalletOperationState {
  prepared,
  proofCreated,
  handedOff,
  submitting,
  ambiguous,
}

enum PendingReconciliationResult {
  none,
  accepted,
  rejectedAfterExpiry,
  pending,
  unavailable,
}

/// Whether an operation may have crossed the process boundary and therefore
/// needs an authoritative chain outcome before its inputs can be reused.
///
/// Both [prepared] and [proofCreated] are written before any caller may hand
/// transaction bytes to a signer or node. They are consequently safe to roll
/// back after their identity-bound snapshots have been verified on restart.
bool pendingOperationRequiresAuthoritativeReconciliation(
  PendingWalletOperationState state,
) =>
    state == PendingWalletOperationState.handedOff ||
    state == PendingWalletOperationState.submitting ||
    state == PendingWalletOperationState.ambiguous;

/// Durable description of a proof operation whose eager native-wallet state
/// must not be discarded until its chain outcome is authoritative.
class PendingWalletOperation {
  static const schema = 2;

  final String operationId;
  final String kind;
  final PendingWalletOperationState state;
  final String walletIdentitySha256;
  final String preSnapshotSha256;
  final String? eagerSnapshotSha256;
  final String? transactionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;

  const PendingWalletOperation({
    required this.operationId,
    required this.kind,
    required this.state,
    required this.walletIdentitySha256,
    required this.preSnapshotSha256,
    required this.createdAt,
    required this.updatedAt,
    this.eagerSnapshotSha256,
    this.transactionId,
    this.expiresAt,
  });

  PendingWalletOperation copyWith({
    PendingWalletOperationState? state,
    String? eagerSnapshotSha256,
    String? transactionId,
    bool clearTransactionId = false,
    DateTime? updatedAt,
    DateTime? expiresAt,
  }) {
    return PendingWalletOperation(
      operationId: operationId,
      kind: kind,
      state: state ?? this.state,
      walletIdentitySha256: walletIdentitySha256,
      preSnapshotSha256: preSnapshotSha256,
      eagerSnapshotSha256: eagerSnapshotSha256 ?? this.eagerSnapshotSha256,
      transactionId:
          clearTransactionId ? null : transactionId ?? this.transactionId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'operation_id': operationId,
        'kind': kind,
        'state': state.name,
        'wallet_identity_sha256': walletIdentitySha256,
        'pre_snapshot_sha256': preSnapshotSha256,
        if (eagerSnapshotSha256 != null)
          'eager_snapshot_sha256': eagerSnapshotSha256,
        if (transactionId != null) 'transaction_id': transactionId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        if (expiresAt != null)
          'expires_at': expiresAt!.toUtc().toIso8601String(),
      };

  String encode() => jsonEncode(toJson());

  factory PendingWalletOperation.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema) {
      throw const FormatException(
          'Unsupported pending wallet operation schema');
    }
    final operationId = json['operation_id'];
    final kind = json['kind'];
    final stateName = json['state'];
    final walletIdentitySha256 = json['wallet_identity_sha256'];
    final preSnapshotSha256 = json['pre_snapshot_sha256'];
    final createdAt = json['created_at'];
    final updatedAt = json['updated_at'];
    if (operationId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(operationId) ||
        kind is! String ||
        !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(kind) ||
        stateName is! String ||
        walletIdentitySha256 is! String ||
        !_isSha256(walletIdentitySha256) ||
        preSnapshotSha256 is! String ||
        !_isSha256(preSnapshotSha256) ||
        createdAt is! String ||
        updatedAt is! String) {
      throw const FormatException('Malformed pending wallet operation');
    }
    final state = PendingWalletOperationState.values
        .where((candidate) => candidate.name == stateName)
        .firstOrNull;
    if (state == null) {
      throw const FormatException('Unknown pending wallet operation state');
    }
    final transactionId = json['transaction_id'];
    if (transactionId != null &&
        (transactionId is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId))) {
      throw const FormatException('Invalid pending transaction id');
    }
    final eagerSnapshotSha256 = json['eager_snapshot_sha256'];
    if (eagerSnapshotSha256 != null &&
        (eagerSnapshotSha256 is! String || !_isSha256(eagerSnapshotSha256))) {
      throw const FormatException('Invalid eager wallet snapshot hash');
    }
    if (state != PendingWalletOperationState.prepared &&
        eagerSnapshotSha256 == null) {
      throw const FormatException(
          'Pending proof state is not bound to an eager snapshot');
    }
    if (state == PendingWalletOperationState.prepared &&
        eagerSnapshotSha256 != null) {
      throw const FormatException(
          'Prepared pending state must not bind an eager snapshot');
    }
    final expiresAt = json['expires_at'];
    if (expiresAt != null && expiresAt is! String) {
      throw const FormatException(
          'Invalid pending wallet operation expires_at');
    }
    DateTime parseRequiredDate(String value, String field) {
      try {
        if (!value.endsWith('Z')) throw const FormatException();
        return DateTime.parse(value).toUtc();
      } catch (_) {
        throw FormatException('Invalid pending wallet operation $field');
      }
    }

    final parsedCreatedAt = parseRequiredDate(createdAt, 'created_at');
    final parsedUpdatedAt = parseRequiredDate(updatedAt, 'updated_at');
    final parsedExpiresAt =
        expiresAt is String ? parseRequiredDate(expiresAt, 'expires_at') : null;
    if (parsedUpdatedAt.isBefore(parsedCreatedAt) ||
        (parsedExpiresAt != null &&
            parsedExpiresAt.isBefore(parsedCreatedAt))) {
      throw const FormatException(
          'Invalid pending wallet operation chronology');
    }
    final requiresSubmissionIdentity =
        state == PendingWalletOperationState.handedOff ||
            state == PendingWalletOperationState.submitting ||
            state == PendingWalletOperationState.ambiguous;
    if (requiresSubmissionIdentity &&
        (transactionId == null || parsedExpiresAt == null)) {
      throw const FormatException(
          'Pending submitted transaction is missing its id or expiry');
    }
    return PendingWalletOperation(
      operationId: operationId,
      kind: kind,
      state: state,
      walletIdentitySha256: walletIdentitySha256,
      preSnapshotSha256: preSnapshotSha256,
      eagerSnapshotSha256: eagerSnapshotSha256 as String?,
      transactionId: transactionId as String?,
      createdAt: parsedCreatedAt,
      updatedAt: parsedUpdatedAt,
      expiresAt: parsedExpiresAt,
    );
  }

  factory PendingWalletOperation.decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Pending wallet operation must be an object');
    }
    return PendingWalletOperation.fromJson(value);
  }
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

String eosioTransactionId(Uint8List packedTransaction) =>
    crypto.sha256.convert(packedTransaction).toString();

void requireMatchingTransactionId(
  PendingWalletOperation operation,
  String? nodeTransactionId,
) {
  final expected = operation.transactionId;
  if (expected == null || nodeTransactionId != expected) {
    throw StateError('Node returned a mismatched transaction id');
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
