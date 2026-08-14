/// Summary of the required block set fetched by the block-direct sync path.
///
/// Completion is deliberately strict: every attempted required block must
/// succeed, and an empty response is accepted only for an actually empty tree.
class BlockDirectSyncResult {
  final int attempted;
  final int succeeded;
  final int failed;

  const BlockDirectSyncResult({
    required this.attempted,
    required this.succeeded,
    required this.failed,
  });

  const BlockDirectSyncResult.empty()
      : attempted = 0,
        succeeded = 0,
        failed = 0;

  bool isCompleteFor({required bool allowEmpty}) =>
      failed == 0 && attempted == succeeded && (allowEmpty || attempted > 0);
}

/// Full Hyperion recovery is complete only when it returned one ciphertext for
/// every commitment in the captured global leaf set.
class FullSyncCoverage {
  static bool hyperionCoversCapturedLeaves({
    required int capturedLeafCount,
    required int ciphertextCount,
  }) =>
      capturedLeafCount >= 0 && ciphertextCount == capturedLeafCount;
}
