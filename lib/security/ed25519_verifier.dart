import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Verifies [signatureBase64] over the exact bytes in [message].
///
/// Callers must verify before decoding or normalizing a manifest. Invalid,
/// missing, or non-canonical key/signature encodings fail closed.
Future<bool> verifyEd25519ExactBytes({
  required List<int> message,
  required String signatureBase64,
  required String publicKeyBase64,
}) async {
  if (message.isEmpty ||
      signatureBase64.trim().isEmpty ||
      publicKeyBase64.trim().isEmpty) {
    return false;
  }

  try {
    final signatureBytes = base64Decode(signatureBase64.trim());
    final publicKeyBytes = base64Decode(publicKeyBase64.trim());
    if (signatureBytes.length != 64 || publicKeyBytes.length != 32) {
      return false;
    }

    return Ed25519().verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          publicKeyBytes,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}
