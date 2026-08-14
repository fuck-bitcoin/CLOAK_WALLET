/// Persisted protocol state exposed by the native wallet extension block.
enum WalletProtocolGeneration {
  legacy('legacy'),
  migratingV11012('migrating-v1.1.0-12'),
  v11012('v1.1.0-12'),
  unknown('unknown');

  final String wireValue;
  const WalletProtocolGeneration(this.wireValue);

  static WalletProtocolGeneration parse(String? value) {
    for (final generation in WalletProtocolGeneration.values) {
      if (generation.wireValue == value) return generation;
    }
    return WalletProtocolGeneration.unknown;
  }
}

class ProtocolCompatibility {
  static const requiredGeneration = WalletProtocolGeneration.v11012;
  static const migratingGeneration = WalletProtocolGeneration.migratingV11012;
  static const compiledMerkleTreeDepth = 12;

  static bool canSync({
    required WalletProtocolGeneration generation,
    required int nativeDepth,
    required int chainDepth,
  }) {
    return nativeDepth == compiledMerkleTreeDepth &&
        chainDepth == compiledMerkleTreeDepth &&
        (generation == requiredGeneration || generation == migratingGeneration);
  }

  static bool canCreateProof({
    required WalletProtocolGeneration generation,
    required int nativeDepth,
    required int chainDepth,
  }) {
    return nativeDepth == compiledMerkleTreeDepth &&
        chainDepth == compiledMerkleTreeDepth &&
        generation == requiredGeneration;
  }

  static void requireSyncCompatible({
    required WalletProtocolGeneration generation,
    required int nativeDepth,
    required int chainDepth,
  }) {
    if (!canSync(
      generation: generation,
      nativeDepth: nativeDepth,
      chainDepth: chainDepth,
    )) {
      throw WalletUpdateRequiredException(
        generation: generation,
        nativeDepth: nativeDepth,
        chainDepth: chainDepth,
      );
    }
  }

  static void requireProofCompatible({
    required WalletProtocolGeneration generation,
    required int nativeDepth,
    required int chainDepth,
  }) {
    if (!canCreateProof(
      generation: generation,
      nativeDepth: nativeDepth,
      chainDepth: chainDepth,
    )) {
      throw WalletUpdateRequiredException(
        generation: generation,
        nativeDepth: nativeDepth,
        chainDepth: chainDepth,
      );
    }
  }
}

/// Deliberately user-facing: callers may display [message] verbatim.
class WalletUpdateRequiredException implements Exception {
  final WalletProtocolGeneration generation;
  final int nativeDepth;
  final int chainDepth;

  const WalletUpdateRequiredException({
    required this.generation,
    required this.nativeDepth,
    required this.chainDepth,
  });

  String get message {
    if (generation == WalletProtocolGeneration.legacy) {
      return 'Wallet update required: this wallet must finish its depth-12 migration before it can sync or sign.';
    }
    if (generation == WalletProtocolGeneration.migratingV11012) {
      return 'Wallet update required: wallet migration is still resyncing. Signing is disabled until it completes.';
    }
    return 'Wallet update required: wallet depth $nativeDepth does not match protocol depth $chainDepth.';
  }

  @override
  String toString() => message;
}
