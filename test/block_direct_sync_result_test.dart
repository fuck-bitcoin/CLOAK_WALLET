import 'package:cloak_wallet/cloak/block_direct_sync_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requires every attempted block to succeed', () {
    expect(
      const BlockDirectSyncResult(
        attempted: 3,
        succeeded: 3,
        failed: 0,
      ).isCompleteFor(allowEmpty: false),
      isTrue,
    );
    expect(
      const BlockDirectSyncResult(
        attempted: 3,
        succeeded: 2,
        failed: 1,
      ).isCompleteFor(allowEmpty: false),
      isFalse,
    );
  });

  test('empty required-block response is accepted only for an empty tree', () {
    expect(
      const BlockDirectSyncResult.empty().isCompleteFor(allowEmpty: false),
      isFalse,
    );
    expect(
      const BlockDirectSyncResult.empty().isCompleteFor(allowEmpty: true),
      isTrue,
    );
  });

  test('inconsistent success counters fail closed', () {
    expect(
      const BlockDirectSyncResult(
        attempted: 2,
        succeeded: 1,
        failed: 0,
      ).isCompleteFor(allowEmpty: false),
      isFalse,
    );
  });

  test('full sync rejects leaves present with missing ciphertext actions', () {
    const capturedLeaves = 3;
    const returnedCiphertexts = 2;

    expect(
      FullSyncCoverage.hyperionCoversCapturedLeaves(
        capturedLeafCount: capturedLeaves,
        ciphertextCount: returnedCiphertexts,
      ),
      isFalse,
    );
    expect(
      FullSyncCoverage.hyperionCoversCapturedLeaves(
        capturedLeafCount: capturedLeaves,
        ciphertextCount: capturedLeaves,
      ),
      isTrue,
    );
  });
}
