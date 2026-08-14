import 'package:cloak_wallet/cloak/protocol_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current depth-12 wallets may sync and create proofs', () {
    expect(
      ProtocolCompatibility.canSync(
        generation: WalletProtocolGeneration.v11012,
        nativeDepth: 12,
        chainDepth: 12,
      ),
      isTrue,
    );
    expect(
      ProtocolCompatibility.canCreateProof(
        generation: WalletProtocolGeneration.v11012,
        nativeDepth: 12,
        chainDepth: 12,
      ),
      isTrue,
    );
  });

  test('migrating wallets may resync but may not create proofs', () {
    expect(
      ProtocolCompatibility.canSync(
        generation: WalletProtocolGeneration.migratingV11012,
        nativeDepth: 12,
        chainDepth: 12,
      ),
      isTrue,
    );
    expect(
      ProtocolCompatibility.canCreateProof(
        generation: WalletProtocolGeneration.migratingV11012,
        nativeDepth: 12,
        chainDepth: 12,
      ),
      isFalse,
    );
  });

  test('future chain depth fails closed with update-required message', () {
    expect(
      () => ProtocolCompatibility.requireSyncCompatible(
        generation: WalletProtocolGeneration.v11012,
        nativeDepth: 12,
        chainDepth: 13,
      ),
      throwsA(
        isA<WalletUpdateRequiredException>().having(
          (error) => error.message,
          'message',
          contains('Wallet update required'),
        ),
      ),
    );
  });

  test('new-account initialization rejects depth before committing height', () {
    var initialHeightCommitted = false;

    expect(
      () {
        ProtocolCompatibility.requireSyncCompatible(
          generation: WalletProtocolGeneration.v11012,
          nativeDepth: 12,
          chainDepth: 13,
        );
        initialHeightCommitted = true;
      },
      throwsA(isA<WalletUpdateRequiredException>()),
    );
    expect(initialHeightCommitted, isFalse);
  });

  test('unknown serialization generation fails closed', () {
    expect(
        WalletProtocolGeneration.parse('v9'), WalletProtocolGeneration.unknown);
    expect(
      ProtocolCompatibility.canSync(
        generation: WalletProtocolGeneration.unknown,
        nativeDepth: 12,
        chainDepth: 12,
      ),
      isFalse,
    );
  });
}
