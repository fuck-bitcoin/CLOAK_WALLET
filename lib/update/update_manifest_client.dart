import 'dart:convert';

import 'package:http/http.dart' as http;

import '../security/ed25519_verifier.dart';
import 'update_manifest.dart';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

class UpdateManifestClient {
  static const int _maximumManifestBytes = 1024 * 1024;

  final http.Client client;
  final Uri manifestUri;
  final Uri signatureUri;
  final String publicKeyBase64;

  const UpdateManifestClient({
    required this.client,
    required this.manifestUri,
    required this.signatureUri,
    required this.publicKeyBase64,
  });

  Future<UpdateManifestV1> fetchVerified() async {
    if (publicKeyBase64.trim().isEmpty) {
      throw const UpdateException('Release update key is not configured');
    }
    final responses = await Future.wait([
      client.get(manifestUri),
      client.get(signatureUri),
    ]);
    final manifestResponse = responses[0];
    final signatureResponse = responses[1];
    if (manifestResponse.statusCode != 200 ||
        signatureResponse.statusCode != 200) {
      throw UpdateException(
        'Update service returned ${manifestResponse.statusCode}/'
        '${signatureResponse.statusCode}',
      );
    }
    final manifestBytes = manifestResponse.bodyBytes;
    if (manifestBytes.isEmpty ||
        manifestBytes.length > _maximumManifestBytes ||
        signatureResponse.bodyBytes.length > 4096) {
      throw const UpdateException('Update metadata has an invalid size');
    }

    Object? signatureJson;
    try {
      signatureJson = jsonDecode(utf8.decode(signatureResponse.bodyBytes));
    } catch (_) {
      throw const UpdateException('Update signature is malformed');
    }
    if (signatureJson is! Map<String, dynamic> ||
        signatureJson['algorithm'] != 'Ed25519' ||
        signatureJson['keyId'] != 'cloak-release-v1' ||
        signatureJson['signature'] is! String) {
      throw const UpdateException('Update signature metadata is invalid');
    }

    final verified = await verifyEd25519ExactBytes(
      message: manifestBytes,
      signatureBase64: signatureJson['signature'] as String,
      publicKeyBase64: publicKeyBase64,
    );
    if (!verified) {
      throw const UpdateException('Update manifest signature is invalid');
    }

    try {
      return UpdateManifestV1.fromJson(
        jsonDecode(utf8.decode(manifestBytes)),
      );
    } on FormatException catch (error) {
      throw UpdateException(error.message.toString());
    } catch (_) {
      throw const UpdateException('Update manifest is malformed');
    }
  }
}
