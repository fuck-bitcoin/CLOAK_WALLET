import 'dart:async';
import 'dart:io';

/// Whether a failed normal send can restore its pre-proof wallet snapshot.
enum SendFailureDisposition {
  rollback,
  reconcile,
}

/// Cooperative cancellation for proof generation.
///
/// Native proof generation cannot be interrupted safely. Cancellation is
/// observed immediately before submission, at which point the caller restores
/// the pre-proof wallet snapshot.
class SendCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;

  void throwIfCancelled() {
    if (_isCancelled) throw const SendCancelledException();
  }
}

class SendCancelledException implements Exception {
  const SendCancelledException();

  @override
  String toString() => 'Transaction cancelled before submission';
}

/// Reported when submission may have reached a chain API but no authoritative
/// result was received. The wallet is kept quarantined until chain resync.
class SendReconciliationException implements Exception {
  final Object cause;
  final bool reconciliationSucceeded;

  const SendReconciliationException({
    required this.cause,
    required this.reconciliationSucceeded,
  });

  @override
  String toString() {
    final status = reconciliationSucceeded
        ? 'Wallet state was rebuilt from the chain.'
        : 'Wallet inputs remain quarantined; retry wallet sync before sending again.';
    return 'Transaction submission could not be confirmed. $status Cause: $cause';
  }
}

/// Marks an aggregate broadcast failure where at least one endpoint may have
/// accepted the transaction before its response was lost.
class AmbiguousSubmissionException implements Exception {
  final Object firstAmbiguousFailure;
  final Object? laterFailure;

  const AmbiguousSubmissionException({
    required this.firstAmbiguousFailure,
    this.laterFailure,
  });

  @override
  String toString() =>
      'Ambiguous transaction submission: $firstAmbiguousFailure'
      '${laterFailure == null ? '' : '; later endpoint: $laterFailure'}';
}

/// Accumulates failures across endpoint retries without allowing a later
/// deterministic rejection to downgrade an earlier ambiguous submission.
class BroadcastFailureTracker {
  Object? _firstAmbiguousFailure;
  Object? _lastFailure;

  void recordFailure(Object error) => _lastFailure = error;

  void recordAmbiguousFailure(Object error) {
    _firstAmbiguousFailure ??= error;
    _lastFailure = error;
  }

  Exception toException([String fallback = 'Broadcast failed']) {
    final ambiguous = _firstAmbiguousFailure;
    if (ambiguous != null) {
      return AmbiguousSubmissionException(
        firstAmbiguousFailure: ambiguous,
        laterFailure: identical(_lastFailure, ambiguous) ? null : _lastFailure,
      );
    }
    final failure = _lastFailure;
    return failure is Exception ? failure : Exception(failure ?? fallback);
  }
}

/// Classify an error received after bytes may have been submitted.
///
/// Only an explicit deterministic chain rejection is safe to roll back. All
/// transport failures, duplicate-transaction responses, and unknown errors are
/// ambiguous because the first API node may have accepted the transaction.
SendFailureDisposition classifyPostSubmitSendFailure(Object error) {
  if (error is AmbiguousSubmissionException) {
    return SendFailureDisposition.reconcile;
  }
  if (error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return SendFailureDisposition.reconcile;
  }

  final message = error.toString().toLowerCase();
  const explicitRejectionMarkers = <String>[
    'assertion failure',
    'proof invalid',
    'invalid proof',
    'missing required authority',
    'transaction declares authority',
    'expired_tx_exception',
    'expired transaction',
    'tx_cpu_usage_exceeded',
    'tx_net_usage_exceeded',
    'unsatisfied_authorization',
    'overdrawn balance',
    'insufficient balance',
    'transaction validation exception',
    'action validate exception',
    'rejected by user',
    'cancelled by user',
    'transaction was rejected',
    'transaction was cancelled',
  ];

  if (explicitRejectionMarkers.any(message.contains)) {
    return SendFailureDisposition.rollback;
  }

  return SendFailureDisposition.reconcile;
}

/// Decide whether the pre-proof snapshot may be restored.
///
/// Before any submission attempt every failure is safe to restore. Once a
/// handoff may have occurred, only an explicit deterministic rejection may
/// restore; timeouts and unknown responses retain the durable quarantine.
SendFailureDisposition classifyProofFailure({
  required bool submissionStarted,
  required Object error,
}) {
  if (!submissionStarted || error is SendCancelledException) {
    return SendFailureDisposition.rollback;
  }
  return classifyPostSubmitSendFailure(error);
}
