import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../security/ed25519_verifier.dart';

/// The pinned description of one proving-parameter file.
class ParamsFileV1 {
  final String name;
  final int sizeBytes;
  final String sha256;
  final String verifyingKeySha256;

  const ParamsFileV1({
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    required this.verifyingKeySha256,
  });

  factory ParamsFileV1.fromJson(Map<String, dynamic> json) {
    return ParamsFileV1(
      name: _requiredString(json, 'name'),
      sizeBytes: _requiredPositiveInt(json, 'size_bytes'),
      sha256: _requiredSha256(json, 'sha256'),
      verifyingKeySha256: _requiredSha256(json, 'verifying_key_sha256'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'verifying_key_sha256': verifyingKeySha256,
      };
}

/// Signed release contract for one complete, non-mixable parameter generation.
///
/// The detached Ed25519 signature covers the exact UTF-8 manifest bytes. The
/// release/update layer verifies that signature before calling [fromJson]. This
/// class then enforces the protocol generation and every pinned file value.
class ParamsManifestV1 {
  final int schema;
  final String generation;
  final int merkleTreeDepth;
  final String sourceBundle;
  final List<ParamsFileV1> files;

  const ParamsManifestV1({
    required this.schema,
    required this.generation,
    required this.merkleTreeDepth,
    required this.sourceBundle,
    required this.files,
  });

  factory ParamsManifestV1.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'];
    if (rawFiles is! List) {
      throw const FormatException('params manifest files must be a list');
    }
    return ParamsManifestV1(
      schema: _requiredPositiveInt(json, 'schema'),
      generation: _requiredString(json, 'generation'),
      merkleTreeDepth: _requiredPositiveInt(json, 'merkle_tree_depth'),
      sourceBundle: _requiredString(json, 'source_bundle'),
      files: rawFiles.map((dynamic value) {
        if (value is! Map) {
          throw const FormatException(
              'params manifest file entries must be objects');
        }
        return ParamsFileV1.fromJson(Map<String, dynamic>.from(value));
      }).toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'generation': generation,
        'merkle_tree_depth': merkleTreeDepth,
        'source_bundle': sourceBundle,
        'files': files.map((file) => file.toJson()).toList(growable: false),
      };
}

/// Manages the complete depth-12 proving-parameter generation.
///
/// Generations live in separate directories. A file is downloaded to `.part`,
/// size- and hash-verified there, and only then promoted to its final name. A
/// generation marker is written after all four files have passed verification,
/// so an interrupted or mixed set can never be reported as ready.
class ParamsManager {
  static const manifestSchema = 1;
  static const protocolGeneration = 'v1.1.0-12';
  static const merkleTreeDepth = 12;
  static const paramsReleaseTag = 'params-v1.1.0-12';
  static const sourceBundle =
      'https://downloads.cloak.today/cloak-gui-v1.26.06.2-windows.zip';
  static const _generationMarkerName = '.params-generation.json';
  static const _previousFileSuffix = '.previous';
  static const _baseUrl =
      'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/download/$paramsReleaseTag';
  static const _releaseManifestPublicKey = String.fromEnvironment(
    'CLOAK_RELEASE_MANIFEST_PUBLIC_KEY',
  );

  /// The production bytes whose derived verifying keys match the live Telos
  /// verifier. These values are a second pin in addition to the signed manifest.
  static const paramFiles = <String, ParamsFileV1>{
    'mint.params': ParamsFileV1(
      name: 'mint.params',
      sizeBytes: 15600764,
      sha256:
          '502c145d1329e83a72f52b0a3091237b54b238178d05d9e3e484c909a597107a',
      verifyingKeySha256:
          '64d3fd942cc195a3a274c07c4059dffb7b1cdccae04cdc09b9ee9e79bf3ac40e',
    ),
    'spend-output.params': ParamsFileV1(
      name: 'spend-output.params',
      sizeBytes: 116049020,
      sha256:
          'e187e4e0690fc1c053f171b14d9353405d554c07b2a6777d2fe93a4c4c4a50e2',
      verifyingKeySha256:
          '90a69e8bf2a40df9e29b79de51749623cc5fc70c2ec3dd96953c9d8130273c38',
    ),
    'spend.params': ParamsFileV1(
      name: 'spend.params',
      sizeBytes: 114333500,
      sha256:
          '0b37b4873684e3fefb459eabd59d1da2a8be2ffadf261401eaa4d843a280b33c',
      verifyingKeySha256:
          'af9dafc133cf2453904e04ae1b17bce885e2476eed5cf458cff61005c5369540',
    ),
    'output.params': ParamsFileV1(
      name: 'output.params',
      sizeBytes: 3070652,
      sha256:
          '7c6b056ed748e842739b2148496d6dbfc387463f98c3b4bddb08c1be60a9aa6b',
      verifyingKeySha256:
          '2963b173d0fa297441500ef075654063feff8979d5bc5464313c9eae70484e52',
    ),
  };

  /// Known depth-20 artifacts. They are retained until migration completes and
  /// are deleted only if both size and SHA-256 match this allow-list.
  static const _legacyParamFiles = <String, _LegacyParamFile>{
    'mint.params': _LegacyParamFile(
      sizeBytes: 15649884,
      sha256:
          '871e81e4f389dd726ce68a8bbdb6cbad211642a5ba4d1d83f49a50be72ec6f9f',
    ),
    'output.params': _LegacyParamFile(
      sizeBytes: 3089244,
      sha256:
          '73d485439dd35fd3abc1d53af12ad5414a63652fd2018c6ae32bb1dbd6925dcd',
    ),
    'spend.params': _LegacyParamFile(
      sizeBytes: 189939708,
      sha256:
          'c653ed65e40bbab3e5b78bed09f9e02fd1746bfd5a5192d9e5d5308baca3adc8',
    ),
    'spend-output.params': _LegacyParamFile(
      sizeBytes: 191716284,
      sha256:
          '17d15a5500ca0a29f7575b28b9ae2f328420374833940fd7c4c7cb2a7ee62d05',
    ),
  };

  static ParamsManifestV1 get pinnedManifest => ParamsManifestV1(
        schema: manifestSchema,
        generation: protocolGeneration,
        merkleTreeDepth: merkleTreeDepth,
        sourceBundle: sourceBundle,
        files: paramFiles.values.toList(growable: false),
      );

  /// Total size of all four depth-12 files (249,053,936 bytes).
  static int get totalSizeBytes =>
      paramFiles.values.fold(0, (sum, file) => sum + file.sizeBytes);

  /// Root containing all proving-parameter generations.
  static Future<String> getParamsRootDirectory() async {
    String base;
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final home = Platform.environment['HOME'] ?? '/tmp';
      base = xdg ?? p.join(home, '.local', 'share');
    } else if (Platform.isMacOS) {
      base = (await getApplicationSupportDirectory()).path;
    } else if (Platform.isWindows) {
      base = Platform.environment['LOCALAPPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? 'C:\\', 'AppData',
              'Local');
    } else {
      // Android (iOS is not a supported release target).
      return p.join((await getApplicationSupportDirectory()).path, 'params');
    }
    return p.join(base, 'cloak-wallet', 'params');
  }

  /// Directory containing only the current parameter generation.
  static Future<String> getParamsDirectory() async =>
      p.join(await getParamsRootDirectory(), protocolGeneration);

  /// Throws if a decoded manifest is not exactly the production generation
  /// compiled into this wallet. This rejects stale, future, partial, or mixed
  /// manifests even if a caller accidentally trusts the wrong release asset.
  static void validatePinnedManifest(ParamsManifestV1 manifest) {
    if (manifest.schema != manifestSchema ||
        manifest.generation != protocolGeneration ||
        manifest.merkleTreeDepth != merkleTreeDepth ||
        manifest.sourceBundle != sourceBundle ||
        manifest.files.length != paramFiles.length) {
      throw const FormatException('unsupported proving-parameter manifest');
    }

    final seen = <String>{};
    for (final actual in manifest.files) {
      if (!seen.add(actual.name)) {
        throw FormatException('duplicate parameter file: ${actual.name}');
      }
      final expected = paramFiles[actual.name];
      if (expected == null ||
          actual.sizeBytes != expected.sizeBytes ||
          actual.sha256 != expected.sha256 ||
          actual.verifyingKeySha256 != expected.verifyingKeySha256) {
        throw FormatException('unrecognized parameter file: ${actual.name}');
      }
    }
  }

  /// Verifies a detached Ed25519 signature before decoding any manifest data.
  /// The same long-lived release-manifest key signs update and parameter
  /// manifests; Sparkle and Android use separate permanent keys.
  static Future<ParamsManifestV1> verifySignedManifestExactBytes({
    required List<int> manifestBytes,
    required String signatureBase64,
    String publicKeyBase64 = _releaseManifestPublicKey,
  }) async {
    final verified = await verifyEd25519ExactBytes(
      message: manifestBytes,
      signatureBase64: signatureBase64,
      publicKeyBase64: publicKeyBase64,
    );
    if (!verified) {
      throw const FormatException(
          'invalid proving-parameter manifest signature');
    }

    final decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
    if (decoded is! Map) {
      throw const FormatException('params manifest must be an object');
    }
    final manifest =
        ParamsManifestV1.fromJson(Map<String, dynamic>.from(decoded));
    validatePinnedManifest(manifest);
    return manifest;
  }

  /// True only for a complete, marked, single-generation set with exact sizes.
  /// Full SHA-256 verification is performed by [verifyAll].
  static Future<bool> paramsExist(String dir) async {
    if (!await _hasCurrentGenerationMarker(dir)) return false;
    for (final expected in paramFiles.values) {
      final file = File(p.join(dir, expected.name));
      if (!await file.exists() || await file.length() != expected.sizeBytes) {
        return false;
      }
    }
    return true;
  }

  /// Hash-verifies every file and the generation marker.
  static Future<bool> verifyAll(String dir) async {
    if (!await _hasCurrentGenerationMarker(dir)) return false;
    for (final expected in paramFiles.values) {
      final path = p.join(dir, expected.name);
      final file = File(path);
      if (!await file.exists() || await file.length() != expected.sizeBytes) {
        return false;
      }
      if (!await verifyChecksum(path, expected.sha256)) return false;
    }
    return true;
  }

  static Future<bool> verifyChecksum(String path, String expectedHex) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return await _sha256File(file) == expectedHex.toLowerCase();
  }

  /// Verifies the exact bytes that will be handed to the native prover.
  static bool verifyParameterBytes(
    List<int> bytes,
    ParamsFileV1 expected,
  ) {
    return bytes.length == expected.sizeBytes &&
        crypto.sha256.convert(bytes).toString() == expected.sha256;
  }

  /// Reads and verifies one immutable generation in a single operation. The
  /// caller may run this method in an isolate; hashes are calculated from the
  /// returned byte arrays themselves, closing the verify-then-reread gap.
  static Future<List<Uint8List>> readVerifiedParameterFiles(String dir) async {
    if (!await _hasCurrentGenerationMarker(dir)) {
      throw const FormatException('parameter generation marker is invalid');
    }

    final result = <Uint8List>[];
    for (final expected in paramFiles.values) {
      final bytes = await File(p.join(dir, expected.name)).readAsBytes();
      if (!verifyParameterBytes(bytes, expected)) {
        throw FormatException(
            'parameter bytes failed verification: ${expected.name}');
      }
      result.add(bytes);
    }

    if (!await _hasCurrentGenerationMarker(dir)) {
      throw const FormatException(
          'parameter generation marker changed while loading');
    }
    return List<Uint8List>.unmodifiable(result);
  }

  /// Downloads and atomically promotes the pinned parameter generation.
  static Future<void> downloadParams({
    required String targetDir,
    required void Function(String file, int bytesDownloaded, int totalBytes)
        onFileProgress,
    required void Function(String message) onStatus,
  }) async {
    await Directory(targetDir).create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    try {
      final manifest = await _fetchAndVerifyManifest(client);
      for (final expected in manifest.files) {
        await _downloadOne(
          client: client,
          targetDir: targetDir,
          expected: expected,
          onFileProgress: onFileProgress,
          onStatus: onStatus,
        );
      }

      // A marker is the commit point for the set. Never write it until every
      // exact file hash has passed in this generation directory.
      for (final expected in paramFiles.values) {
        final path = p.join(targetDir, expected.name);
        if (!await verifyChecksum(path, expected.sha256)) {
          throw StateError('parameter set changed before commit');
        }
      }
      await _writeGenerationMarker(targetDir);
    } finally {
      client.close(force: true);
    }
  }

  static Future<ParamsManifestV1> _fetchAndVerifyManifest(
      HttpClient client) async {
    const manifestName = 'params-manifest-v1.json';
    final manifestBytes = await _downloadSmallFile(
      client,
      Uri.parse('$_baseUrl/$manifestName'),
      maximumBytes: 64 * 1024,
    );
    final signatureBytes = await _downloadSmallFile(
      client,
      Uri.parse('$_baseUrl/$manifestName.sig'),
      maximumBytes: 1024,
    );
    final signatureMetadata = jsonDecode(
      utf8.decode(signatureBytes, allowMalformed: false),
    );
    if (signatureMetadata is! Map<String, dynamic> ||
        signatureMetadata['algorithm'] != 'Ed25519' ||
        signatureMetadata['keyId'] != 'cloak-release-v1' ||
        signatureMetadata['signature'] is! String) {
      throw const FormatException(
          'invalid proving-parameter signature metadata');
    }
    return verifySignedManifestExactBytes(
      manifestBytes: manifestBytes,
      signatureBase64: signatureMetadata['signature'] as String,
    );
  }

  static Future<Uint8List> _downloadSmallFile(
    HttpClient client,
    Uri uri, {
    required int maximumBytes,
  }) async {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
          'failed to download signed manifest: HTTP ${response.statusCode}');
    }

    final output = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response) {
      received += chunk.length;
      if (received > maximumBytes) {
        throw const FormatException('signed manifest asset is unexpectedly large');
      }
      output.add(chunk);
    }
    if (received == 0) {
      throw const FormatException('signed manifest asset is empty');
    }
    return output.takeBytes();
  }

  static Future<void> _downloadOne({
    required HttpClient client,
    required String targetDir,
    required ParamsFileV1 expected,
    required void Function(String file, int bytesDownloaded, int totalBytes)
        onFileProgress,
    required void Function(String message) onStatus,
  }) async {
    final finalFile = File(p.join(targetDir, expected.name));
    final partialFile = File('${finalFile.path}.part');
    await _recoverInterruptedPromotion(finalFile);

    if (await finalFile.exists()) {
      final correctSize = await finalFile.length() == expected.sizeBytes;
      if (correctSize &&
          await verifyChecksum(finalFile.path, expected.sha256)) {
        onFileProgress(expected.name, expected.sizeBytes, expected.sizeBytes);
        return;
      }
    }

    var resumeOffset =
        await partialFile.exists() ? await partialFile.length() : 0;
    if (resumeOffset > expected.sizeBytes) {
      await partialFile.delete();
      resumeOffset = 0;
    } else if (resumeOffset == expected.sizeBytes) {
      onStatus('Verifying ${expected.name}...');
      if (await verifyChecksum(partialFile.path, expected.sha256)) {
        await _promote(partialFile, finalFile);
        onFileProgress(expected.name, expected.sizeBytes, expected.sizeBytes);
        return;
      }
      await partialFile.delete();
      resumeOffset = 0;
    }

    final request = await client
        .getUrl(Uri.parse('$_baseUrl/${Uri.encodeComponent(expected.name)}'));
    if (resumeOffset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeOffset-');
    }
    final response = await request.close();

    if (resumeOffset > 0 && response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      if (await partialFile.exists()) await partialFile.delete();
      return _downloadOne(
        client: client,
        targetDir: targetDir,
        expected: expected,
        onFileProgress: onFileProgress,
        onStatus: onStatus,
      );
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException(
          'failed to download ${expected.name}: HTTP ${response.statusCode}');
    }
    if (response.statusCode == HttpStatus.partialContent) {
      final contentRange =
          response.headers.value(HttpHeaders.contentRangeHeader);
      final match = contentRange == null
          ? null
          : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
      final rangeStart = int.tryParse(match?.group(1) ?? '');
      final rangeEnd = int.tryParse(match?.group(2) ?? '');
      final rangeTotal = int.tryParse(match?.group(3) ?? '');
      if (rangeStart != resumeOffset ||
          rangeEnd == null ||
          rangeEnd < resumeOffset ||
          rangeTotal != expected.sizeBytes) {
        await response.drain<void>();
        if (await partialFile.exists()) await partialFile.delete();
        throw HttpException(
            'invalid Content-Range for ${expected.name}: $contentRange');
      }
    }
    if (response.contentLength >= 0 &&
        resumeOffset + response.contentLength > expected.sizeBytes) {
      await response.drain<void>();
      throw FormatException(
          'parameter response exceeds signed size for ${expected.name}');
    }

    onStatus('Downloading ${expected.name}...');
    final sink = partialFile.openWrite(
      mode: resumeOffset > 0 ? FileMode.append : FileMode.write,
    );
    var received = resumeOffset;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        if (received > expected.sizeBytes) {
          throw const FormatException('parameter download exceeds signed size');
        }
        sink.add(chunk);
        onFileProgress(expected.name, received, expected.sizeBytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (received != expected.sizeBytes) {
      throw FormatException(
          'incomplete ${expected.name}: $received of ${expected.sizeBytes} bytes');
    }
    onStatus('Verifying ${expected.name}...');
    if (!await verifyChecksum(partialFile.path, expected.sha256)) {
      await partialFile.delete();
      throw FormatException(
          'checksum verification failed for ${expected.name}');
    }
    await _promote(partialFile, finalFile);
  }

  static Future<void> _promote(File partialFile, File finalFile) async {
    await _recoverInterruptedPromotion(finalFile);
    final previous = File('${finalFile.path}$_previousFileSuffix');
    if (await previous.exists()) await previous.delete();
    if (await finalFile.exists()) {
      await finalFile.rename(previous.path);
    }
    try {
      await partialFile.rename(finalFile.path);
    } catch (_) {
      if (!await finalFile.exists() && await previous.exists()) {
        await previous.rename(finalFile.path);
      }
      rethrow;
    }
    if (await previous.exists()) await previous.delete();
  }

  static Future<void> _recoverInterruptedPromotion(File finalFile) async {
    final previous = File('${finalFile.path}$_previousFileSuffix');
    if (await finalFile.exists()) {
      if (await previous.exists()) await previous.delete();
      return;
    }
    if (await previous.exists()) await previous.rename(finalFile.path);
  }

  static Future<void> _writeGenerationMarker(String targetDir) async {
    final marker = File(p.join(targetDir, _generationMarkerName));
    final partial = File('${marker.path}.part');
    final canonical =
        const JsonEncoder.withIndent('  ').convert(pinnedManifest.toJson());
    await partial.writeAsString('$canonical\n', flush: true);
    await _promote(partial, marker);
  }

  static Future<bool> _hasCurrentGenerationMarker(String dir) async {
    final marker = File(p.join(dir, _generationMarkerName));
    await _recoverInterruptedPromotion(marker);
    if (!await marker.exists()) return false;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) return false;
      final manifest =
          ParamsManifestV1.fromJson(Map<String, dynamic>.from(decoded));
      validatePinnedManifest(manifest);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Removes only byte-for-byte known depth-20 files after wallet migration.
  /// Unknown files and all current-generation files are always retained.
  static Future<List<String>> removeKnownLegacyParamsAfterMigration() async {
    final root = await getParamsRootDirectory();
    final removed = <String>[];
    for (final entry in _legacyParamFiles.entries) {
      final file = File(p.join(root, entry.key));
      if (!await file.exists() ||
          await file.length() != entry.value.sizeBytes ||
          !await verifyChecksum(file.path, entry.value.sha256)) {
        continue;
      }
      await file.delete();
      removed.add(entry.key);
    }
    return removed;
  }

  static Future<String> _sha256File(File file) async {
    final output = AccumulatorSink();
    final input = crypto.sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString();
  }
}

class AccumulatorSink implements Sink<crypto.Digest> {
  final events = <crypto.Digest>[];

  @override
  void add(crypto.Digest event) => events.add(event);

  @override
  void close() {}
}

class _LegacyParamFile {
  final int sizeBytes;
  final String sha256;

  const _LegacyParamFile({required this.sizeBytes, required this.sha256});
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredPositiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) {
    throw FormatException('$key must be a positive integer');
  }
  return value;
}

String _requiredSha256(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$key must be a lowercase SHA-256 digest');
  }
  return value;
}
