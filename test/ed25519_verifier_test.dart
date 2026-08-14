import 'dart:convert';

import 'package:cloak_wallet/security/ed25519_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verifies only the exact signed bytes', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final message = utf8.encode('{"schema":1}\n');
    final signature = await algorithm.sign(message, keyPair: keyPair);

    expect(
      await verifyEd25519ExactBytes(
        message: message,
        signatureBase64: base64Encode(signature.bytes),
        publicKeyBase64: base64Encode(publicKey.bytes),
      ),
      isTrue,
    );
    expect(
      await verifyEd25519ExactBytes(
        message: utf8.encode('{"schema":1}'),
        signatureBase64: base64Encode(signature.bytes),
        publicKeyBase64: base64Encode(publicKey.bytes),
      ),
      isFalse,
    );
  });

  test('malformed inputs fail closed', () async {
    expect(
      await verifyEd25519ExactBytes(
        message: const [1],
        signatureBase64: 'not base64',
        publicKeyBase64: 'also not base64',
      ),
      isFalse,
    );
  });
}
