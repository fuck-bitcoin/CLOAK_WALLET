import 'dart:async';
import 'dart:io';

import 'package:cloak_wallet/cloak/send_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SendCancellationToken', () {
    test('throws only after cancellation', () {
      final token = SendCancellationToken();

      expect(token.throwIfCancelled, returnsNormally);
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(token.throwIfCancelled, throwsA(isA<SendCancelledException>()));
    });
  });

  group('classifyPostSubmitSendFailure', () {
    test('reconciles transport failures', () {
      expect(
        classifyPostSubmitSendFailure(const SocketException('reset')),
        SendFailureDisposition.reconcile,
      );
      expect(
        classifyPostSubmitSendFailure(TimeoutException('timed out')),
        SendFailureDisposition.reconcile,
      );
      expect(
        classifyPostSubmitSendFailure(const HttpException('closed')),
        SendFailureDisposition.reconcile,
      );
    });

    test('reconciles duplicate and unknown responses', () {
      expect(
        classifyPostSubmitSendFailure(
          Exception('duplicate_tx_exception: duplicate transaction'),
        ),
        SendFailureDisposition.reconcile,
      );
      expect(
        classifyPostSubmitSendFailure(Exception('unexpected API response')),
        SendFailureDisposition.reconcile,
      );
    });

    test('rolls back explicit deterministic chain rejections', () {
      for (final message in [
        'assertion failure with message: proof invalid',
        'missing required authority',
        'expired_tx_exception',
        'tx_cpu_usage_exceeded',
      ]) {
        expect(
          classifyPostSubmitSendFailure(Exception(message)),
          SendFailureDisposition.rollback,
          reason: message,
        );
      }
    });

    test('later rejection cannot downgrade an earlier ambiguous endpoint', () {
      final failures = BroadcastFailureTracker();
      failures.recordAmbiguousFailure(
        TimeoutException('first endpoint timed out after request write'),
      );
      failures.recordFailure(
        Exception('expired_tx_exception from later endpoint'),
      );

      final aggregate = failures.toException();
      expect(aggregate, isA<AmbiguousSubmissionException>());
      expect(
        classifyPostSubmitSendFailure(aggregate),
        SendFailureDisposition.reconcile,
      );
    });
  });

  group('classifyProofFailure', () {
    test('restores all confirmed pre-submit failures and cancellations', () {
      expect(
        classifyProofFailure(
          submissionStarted: false,
          error: TimeoutException('proof worker timed out'),
        ),
        SendFailureDisposition.rollback,
      );
      expect(
        classifyProofFailure(
          submissionStarted: true,
          error: const SendCancelledException(),
        ),
        SendFailureDisposition.rollback,
      );
    });

    test('restores explicit node rejection after submission', () {
      expect(
        classifyProofFailure(
          submissionStarted: true,
          error: Exception('assertion failure: proof invalid'),
        ),
        SendFailureDisposition.rollback,
      );
    });

    test('never restores timeout or unknown outcome after submission', () {
      expect(
        classifyProofFailure(
          submissionStarted: true,
          error: TimeoutException('push_transaction timed out'),
        ),
        SendFailureDisposition.reconcile,
      );
      expect(
        classifyProofFailure(
          submissionStarted: true,
          error: Exception('node disconnected after request body'),
        ),
        SendFailureDisposition.reconcile,
      );
    });
  });
}
