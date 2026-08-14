import 'dart:convert';

import 'package:cloak_wallet/update/update_manifest.dart';
import 'package:cloak_wallet/update/update_manifest_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('semantic versions use stable and prerelease ordering', () {
    expect(
      SemanticVersion.parse('2.1.1').compareTo(SemanticVersion.parse('2.1.0')),
      greaterThan(0),
    );
    expect(
      SemanticVersion.parse('2.1.0')
          .compareTo(SemanticVersion.parse('2.1.0-rc.1')),
      greaterThan(0),
    );
    expect(
      () => SemanticVersion.parse('02.1.0'),
      throwsFormatException,
    );
  });

  test('client verifies exact bytes before parsing manifest', () async {
    final manifestBytes = utf8.encode(jsonEncode(_validManifest()));
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
    final signatureBytes = utf8.encode(jsonEncode({
      'algorithm': 'Ed25519',
      'keyId': 'cloak-release-v1',
      'signature': base64Encode(signature.bytes),
    }));
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sig')) {
        return http.Response.bytes(signatureBytes, 200);
      }
      return http.Response.bytes(manifestBytes, 200);
    });
    final result = await UpdateManifestClient(
      client: client,
      manifestUri: Uri.parse('https://example.invalid/update-v1.json'),
      signatureUri: Uri.parse('https://example.invalid/update-v1.sig'),
      publicKeyBase64: base64Encode(publicKey.bytes),
    ).fetchVerified();

    expect(result.version.toString(), '2.1.1');
    expect(result.assetFor('windows-x64')?.size, 42);
  });

  test('signed but non-immutable asset URL is rejected', () {
    final manifest = _validManifest();
    final assets = manifest['assets'] as Map<String, Object?>;
    final windows = assets['windows-x64'] as Map<String, Object?>;
    windows['url'] =
        'https://github.com/attacker/repo/releases/download/v2.1.1/a.zip';
    expect(
      () => UpdateManifestV1.fromJson(manifest),
      throwsFormatException,
    );
  });

  test('asset URL must name the exact signed target file', () {
    final manifest = _validManifest();
    final assets = manifest['assets'] as Map<String, Object?>;
    final windows = assets['windows-x64'] as Map<String, Object?>;
    windows['url'] = '${windows['url'] as String}.unexpected-suffix';
    expect(
      () => UpdateManifestV1.fromJson(manifest),
      throwsFormatException,
    );
  });

  test('build number is canonically derived from the stable version', () {
    final manifest = _validManifest()..['build'] = 2001002;
    expect(
      () => UpdateManifestV1.fromJson(manifest),
      throwsFormatException,
    );
  });

  test('required parameter generation is an exact compatibility gate', () {
    final manifest = UpdateManifestV1.fromJson(_validManifest());

    expect(manifest.supportsParameterGeneration('v1.1.0-12'), isTrue);
    expect(manifest.supportsParameterGeneration('v1.1.0-20'), isFalse);
  });
}

Map<String, Object?> _validManifest() => {
      'schema': 1,
      'version': '2.1.1',
      'build': 2001001,
      'tag': 'v2.1.1',
      'commit': '0123456789abcdef0123456789abcdef01234567',
      'issuedAt': '2026-08-13T20:00:00Z',
      'minimumUpdaterVersion': '2.1.0',
      'requiredParameterGeneration': 'v1.1.0-12',
      'notes': 'Recovery updater test',
      'assets': <String, Object?>{
        'windows-x64': <String, Object?>{
          'name': 'CLOAK_Wallet-windows-x64.zip',
          'platform': 'windows',
          'architecture': 'x64',
          'url':
              'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/download/v2.1.1/CLOAK_Wallet-windows-x64.zip',
          'size': 42,
          'sha256': List<String>.filled(64, 'a').join(),
        },
      },
    };
