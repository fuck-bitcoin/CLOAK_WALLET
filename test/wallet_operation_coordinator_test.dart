import 'dart:async';
import 'dart:typed_data';

import 'package:cloak_wallet/cloak/pending_wallet_operation.dart';
import 'package:cloak_wallet/cloak/wallet_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wallet operations are FIFO and never overlap', () async {
    final coordinator = WalletOperationCoordinator();
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = coordinator.runExclusive('first', () async {
      events.add('first-start');
      firstEntered.complete();
      await releaseFirst.future;
      events.add('first-end');
    });
    await firstEntered.future;
    final second = coordinator.runExclusive('second', () async {
      events.add('second');
    });

    expect(coordinator.isActive, isTrue);
    expect(coordinator.queuedOperationCount, 1);
    expect(events, ['first-start']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second']);
    expect(coordinator.isActive, isFalse);
  });

  test('nested operations are reentrant', () async {
    final coordinator = WalletOperationCoordinator();
    final value = await coordinator.runExclusive('outer', () async {
      return coordinator.runExclusive('save', () async => 42);
    });
    expect(value, 42);
  });

  test('all sync labels are blocked while a transaction is pending', () {
    expect(walletOperationMayRunWhilePending('wallet-sync'), isFalse);
    expect(walletOperationMayRunWhilePending('sync-from-tables'), isFalse);
    expect(walletOperationMayRunWhilePending('read-balances'), isTrue);
  });

  test('a failing operation releases the next waiter', () async {
    final coordinator = WalletOperationCoordinator();
    await expectLater(
      coordinator.runExclusive<void>('failure', () => throw StateError('no')),
      throwsStateError,
    );
    expect(await coordinator.runExclusive('next', () => 'ok'), 'ok');
  });

  test('an async task escaping the owner zone cannot bypass a later owner',
      () async {
    final coordinator = WalletOperationCoordinator();
    final letEscapedContinue = Completer<void>();
    final secondEntered = Completer<void>();
    final releaseSecond = Completer<void>();
    final events = <String>[];
    late Future<void> escaped;

    await coordinator.runExclusive('first', () async {
      escaped = Future<void>(() async {
        await letEscapedContinue.future;
        await coordinator.runExclusive('escaped', () async {
          events.add('escaped');
        });
      });
    });

    final second = coordinator.runExclusive('second', () async {
      events.add('second-start');
      secondEntered.complete();
      await releaseSecond.future;
      events.add('second-end');
    });
    await secondEntered.future;
    letEscapedContinue.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['second-start']);
    releaseSecond.complete();
    await Future.wait([second, escaped]);
    expect(events, ['second-start', 'second-end', 'escaped']);
  });

  test('single-flight coalesces callers and retries after failure', () async {
    final flight = AsyncSingleFlight<int>();
    final release = Completer<int>();
    var calls = 0;
    Future<int> load() {
      calls++;
      return release.future;
    }

    final first = flight.run(load);
    final second = flight.run(load);
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    expect(flight.isActive, isTrue);
    release.complete(42);
    expect(await Future.wait([first, second]), [42, 42]);
    expect(flight.isActive, isFalse);

    await expectLater(
      flight.run(() async => throw StateError('load failed')),
      throwsStateError,
    );
    expect(flight.isActive, isFalse);
    expect(await flight.run(() async => 7), 7);
  });

  test('pending record round trips and transaction id is deterministic', () {
    final now = DateTime.utc(2026, 8, 13, 12);
    final record = PendingWalletOperation(
      operationId: 'a' * 64,
      kind: 'send',
      state: PendingWalletOperationState.handedOff,
      walletIdentitySha256: 'c' * 64,
      preSnapshotSha256: 'd' * 64,
      eagerSnapshotSha256: 'e' * 64,
      transactionId: eosioTransactionId(Uint8List.fromList([1, 2, 3])),
      createdAt: now,
      updatedAt: now,
      expiresAt: now.add(const Duration(minutes: 10)),
    );

    final decoded = PendingWalletOperation.decode(record.encode());
    expect(decoded.operationId, record.operationId);
    expect(decoded.state, PendingWalletOperationState.handedOff);
    expect(decoded.transactionId,
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81');
    expect(decoded.expiresAt, record.expiresAt);
    expect(
      () => requireMatchingTransactionId(decoded, decoded.transactionId),
      returnsNormally,
    );
    expect(
      () => requireMatchingTransactionId(decoded, '0' * 64),
      throwsStateError,
    );
  });

  test('pending record rejects malformed ids and chronology', () {
    final valid = PendingWalletOperation(
      operationId: 'a' * 64,
      kind: 'send',
      state: PendingWalletOperationState.ambiguous,
      walletIdentitySha256: 'c' * 64,
      preSnapshotSha256: 'd' * 64,
      eagerSnapshotSha256: 'e' * 64,
      transactionId: 'b' * 64,
      createdAt: DateTime.utc(2026, 8, 13, 12),
      updatedAt: DateTime.utc(2026, 8, 13, 12, 1),
      expiresAt: DateTime.utc(2026, 8, 13, 12, 10),
    ).toJson();

    expect(
      () => PendingWalletOperation.fromJson({...valid, 'operation_id': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid, 'transaction_id': 'B' * 64},
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid, 'updated_at': '2026-08-13T11:59:00Z'},
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid, 'created_at': 'not-a-date'},
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid, 'pre_snapshot_sha256': '0' * 63},
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid}..remove('eager_snapshot_sha256'),
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson(
        {...valid, 'expires_at': 1234},
      ),
      throwsFormatException,
    );
    expect(
      () => PendingWalletOperation.fromJson({...valid}..remove('expires_at')),
      throwsFormatException,
    );
  });

  test('prepared record is pre-snapshot-only and restart recoverable', () {
    final now = DateTime.utc(2026, 8, 13, 12);
    final prepared = PendingWalletOperation(
      operationId: 'a' * 64,
      kind: 'shield-proof',
      state: PendingWalletOperationState.prepared,
      walletIdentitySha256: 'b' * 64,
      preSnapshotSha256: 'c' * 64,
      createdAt: now,
      updatedAt: now,
    );
    expect(
      PendingWalletOperation.decode(prepared.encode()).state,
      PendingWalletOperationState.prepared,
    );
    expect(
      () => PendingWalletOperation.fromJson({
        ...prepared.toJson(),
        'eager_snapshot_sha256': 'd' * 64,
      }),
      throwsFormatException,
    );
  });

  test('only externally handed-off states require chain reconciliation', () {
    expect(
      pendingOperationRequiresAuthoritativeReconciliation(
        PendingWalletOperationState.prepared,
      ),
      isFalse,
    );
    expect(
      pendingOperationRequiresAuthoritativeReconciliation(
        PendingWalletOperationState.proofCreated,
      ),
      isFalse,
    );
    for (final state in [
      PendingWalletOperationState.handedOff,
      PendingWalletOperationState.submitting,
      PendingWalletOperationState.ambiguous,
    ]) {
      expect(
        pendingOperationRequiresAuthoritativeReconciliation(state),
        isTrue,
        reason: state.name,
      );
    }
  });
}
