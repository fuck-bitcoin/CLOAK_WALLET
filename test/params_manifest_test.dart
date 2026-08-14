import 'dart:convert';
import 'dart:io';

import 'package:cloak_wallet/cloak/params_manager.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pins the complete production depth-12 parameter generation', () {
    final manifest = ParamsManager.pinnedManifest;

    expect(manifest.schema, 1);
    expect(manifest.generation, 'v1.1.0-12');
    expect(manifest.merkleTreeDepth, 12);
    expect(manifest.files, hasLength(4));
    expect(ParamsManager.totalSizeBytes, 249053936);
    expect(
      manifest.files.map((file) => file.name),
      containsAll(<String>[
        'mint.params',
        'spend-output.params',
        'spend.params',
        'output.params',
      ]),
    );

    expect(
      () => ParamsManager.validatePinnedManifest(manifest),
      returnsNormally,
    );
  });

  test('rejects a mixed parameter generation', () {
    final json = ParamsManager.pinnedManifest.toJson();
    final files = (json['files']! as List<dynamic>)
        .map((dynamic file) => Map<String, dynamic>.from(file as Map))
        .toList();
    files[0]['sha256'] = '0' * 64;
    json['files'] = files;

    final mixed = ParamsManifestV1.fromJson(json);
    expect(
      () => ParamsManager.validatePinnedManifest(mixed),
      throwsFormatException,
    );
  });

  test('rejects duplicate files even when their values are pinned', () {
    final pinned = ParamsManager.pinnedManifest;
    final duplicate = ParamsManifestV1(
      schema: pinned.schema,
      generation: pinned.generation,
      merkleTreeDepth: pinned.merkleTreeDepth,
      sourceBundle: pinned.sourceBundle,
      files: <ParamsFileV1>[
        pinned.files[0],
        pinned.files[0],
        pinned.files[2],
        pinned.files[3],
      ],
    );

    expect(
      () => ParamsManager.validatePinnedManifest(duplicate),
      throwsFormatException,
    );
  });

  test('manifest parser rejects malformed hashes before pin validation', () {
    final json = ParamsManager.pinnedManifest.toJson();
    final files = (json['files']! as List<dynamic>)
        .map((dynamic file) => Map<String, dynamic>.from(file as Map))
        .toList();
    files[1]['verifying_key_sha256'] = 'not-a-hash';
    json['files'] = files;

    expect(
      () => ParamsManifestV1.fromJson(json),
      throwsFormatException,
    );
  });

  test('verifies exact manifest bytes before parsing', () async {
    final bytes =
        utf8.encode(jsonEncode(ParamsManager.pinnedManifest.toJson()));
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(bytes, keyPair: keyPair);

    final verified = await ParamsManager.verifySignedManifestExactBytes(
      manifestBytes: bytes,
      signatureBase64: base64Encode(signature.bytes),
      publicKeyBase64: base64Encode(publicKey.bytes),
    );

    expect(verified.generation, ParamsManager.protocolGeneration);
  });

  test('rejects a manifest changed after signing', () async {
    final bytes =
        utf8.encode(jsonEncode(ParamsManager.pinnedManifest.toJson()));
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(bytes, keyPair: keyPair);
    final changed = List<int>.from(bytes)..add(0x20);

    expect(
      () => ParamsManager.verifySignedManifestExactBytes(
        manifestBytes: changed,
        signatureBase64: base64Encode(signature.bytes),
        publicKeyBase64: base64Encode(publicKey.bytes),
      ),
      throwsFormatException,
    );
  });

  test('verifies the exact parameter byte array, size and digest', () {
    final bytes = utf8.encode('small deterministic parameter fixture');
    final expected = ParamsFileV1(
      name: 'fixture.params',
      sizeBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
      verifyingKeySha256: '0' * 64,
    );

    expect(ParamsManager.verifyParameterBytes(bytes, expected), isTrue);
    expect(
      ParamsManager.verifyParameterBytes(<int>[...bytes, 0], expected),
      isFalse,
    );
    expect(
      ParamsManager.verifyParameterBytes(
        <int>[bytes.first ^ 1, ...bytes.skip(1)],
        expected,
      ),
      isFalse,
    );
  });

  test('production parameter manifest has a valid committed signature',
      () async {
    final manifestBytes =
        await File('release/params/params-manifest-v1.json').readAsBytes();
    final signatureMetadata = jsonDecode(
      await File('release/params/params-manifest-v1.json.sig').readAsString(),
    ) as Map<String, dynamic>;
    final publicKey = (await File(
      'release/keys/release-manifest-public.base64',
    ).readAsString())
        .trim();

    expect(signatureMetadata['algorithm'], 'Ed25519');
    expect(signatureMetadata['keyId'], 'cloak-release-v1');
    final verified = await ParamsManager.verifySignedManifestExactBytes(
      manifestBytes: manifestBytes,
      signatureBase64: signatureMetadata['signature'] as String,
      publicKeyBase64: publicKey,
    );
    expect(verified.generation, ParamsManager.protocolGeneration);
  });
}
