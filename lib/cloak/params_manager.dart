import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages ZK proving parameter files: platform-aware directory resolution,
/// download with progress, resume support, and SHA256 verification.
class ParamsManager {
  static const _paramsVersion = 'params-v1';
  static const _baseUrl =
      'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/download/$_paramsVersion';

  /// The 4 required param files and their SHA256 checksums.
  static const paramFiles = <String, _ParamFile>{
    'mint.params': _ParamFile(
      name: 'mint.params',
      sizeBytes: 15649884,
      sha256: '871e81e4f389dd726ce68a8bbdb6cbad211642a5ba4d1d83f49a50be72ec6f9f',
    ),
    'output.params': _ParamFile(
      name: 'output.params',
      sizeBytes: 3089244,
      sha256: '73d485439dd35fd3abc1d53af12ad5414a63652fd2018c6ae32bb1dbd6925dcd',
    ),
    'spend.params': _ParamFile(
      name: 'spend.params',
      sizeBytes: 189939708,
      sha256: 'c653ed65e40bbab3e5b78bed09f9e02fd1746bfd5a5192d9e5d5308baca3adc8',
    ),
    'spend-output.params': _ParamFile(
      name: 'spend-output.params',
      sizeBytes: 191716284,
      sha256: '17d15a5500ca0a29f7575b28b9ae2f328420374833940fd7c4c7cb2a7ee62d05',
    ),
  };

  /// Total size of all param files in bytes (~383 MB).
  static int get totalSizeBytes =>
      paramFiles.values.fold(0, (sum, f) => sum + f.sizeBytes);

  /// Platform-specific directory for ZK params.
  ///
  /// - Linux: `~/.local/share/cloak-wallet/params/`
  /// - macOS: `~/Library/Application Support/cloak-wallet/params/`
  /// - Windows: `%LOCALAPPDATA%/cloak-wallet/params/`
  /// - Android/iOS: `getApplicationSupportDirectory()/params/`
  static Future<String> getParamsDirectory() async {
    String base;
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final home = Platform.environment['HOME'] ?? '/tmp';
      base = xdg ?? p.join(home, '.local', 'share');
    } else if (Platform.isMacOS) {
      final dir = await getApplicationSupportDirectory();
      base = dir.path;
      // Already 'Application Support'; append app name below.
    } else if (Platform.isWindows) {
      base = Platform.environment['LOCALAPPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? 'C:\\', 'AppData', 'Local');
    } else {
      // Android / iOS / fallback
      final dir = await getApplicationSupportDirectory();
      return p.join(dir.path, 'params');
    }

    return p.join(base, 'cloak-wallet', 'params');
  }

  /// Check whether all 4 param files exist locally with correct sizes.
  /// Does NOT verify checksums (that would read ~383 MB).
  static Future<bool> paramsExist(String dir) async {
    for (final pf in paramFiles.values) {
      final file = File(p.join(dir, pf.name));
      if (!file.existsSync()) return false;
      if (file.lengthSync() != pf.sizeBytes) return false;
    }
    return true;
  }

  /// Full verification: check SHA256 of every param file.
  static Future<bool> verifyAll(String dir) async {
    for (final pf in paramFiles.values) {
      if (!await verifyChecksum(p.join(dir, pf.name), pf.sha256)) return false;
    }
    return true;
  }

  /// Verify SHA256 checksum of a single file.
  static Future<bool> verifyChecksum(String path, String expectedHex) async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final digest = await _sha256File(file);
    return digest == expectedHex;
  }

  /// Download all missing/corrupt param files with progress.
  ///
  /// [onFileProgress] is called with (fileName, bytesDownloaded, totalBytes)
  /// for each file as it downloads.
  /// [onStatus] is called with a human-readable status string.
  ///
  /// Supports resume: if a partial file exists and the server supports Range
  /// requests, the download continues from where it left off.
  static Future<void> downloadParams({
    required String targetDir,
    required void Function(String file, int bytesDownloaded, int totalBytes)
        onFileProgress,
    required void Function(String message) onStatus,
  }) async {
    await Directory(targetDir).create(recursive: true);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    try {
      for (final pf in paramFiles.values) {
        final filePath = p.join(targetDir, pf.name);
        final file = File(filePath);

        // Skip files that already exist and have correct size.
        if (file.existsSync() && file.lengthSync() == pf.sizeBytes) {
          onStatus('${pf.name} already exists, verifying...');
          if (await verifyChecksum(filePath, pf.sha256)) {
            onFileProgress(pf.name, pf.sizeBytes, pf.sizeBytes);
            continue;
          }
          // Checksum mismatch — re-download from scratch.
          await file.delete();
        }

        final url = '$_baseUrl/${pf.name}';
        onStatus('Downloading ${pf.name}...');

        // Check for partial download to resume.
        final partialPath = '$filePath.part';
        final partialFile = File(partialPath);
        int resumeOffset = 0;
        if (partialFile.existsSync()) {
          resumeOffset = partialFile.lengthSync();
          if (resumeOffset >= pf.sizeBytes) {
            // Partial is already full-size; rename and verify.
            await partialFile.rename(filePath);
            if (await verifyChecksum(filePath, pf.sha256)) {
              onFileProgress(pf.name, pf.sizeBytes, pf.sizeBytes);
              continue;
            }
            // Bad file; delete and re-download.
            await File(filePath).delete();
            resumeOffset = 0;
          }
        }

        // Open HTTP request with optional Range header for resume.
        final request = await client.getUrl(Uri.parse(url));
        if (resumeOffset > 0) {
          request.headers.set('Range', 'bytes=$resumeOffset-');
        }

        final response = await request.close();

        // If server doesn't support range, start over.
        if (resumeOffset > 0 && response.statusCode != 206) {
          resumeOffset = 0;
          if (partialFile.existsSync()) await partialFile.delete();
        }

        if (response.statusCode != 200 && response.statusCode != 206) {
          throw Exception(
              'Failed to download ${pf.name}: HTTP ${response.statusCode}');
        }

        // Stream to disk.
        final sink = partialFile.openWrite(
          mode: resumeOffset > 0 ? FileMode.append : FileMode.write,
        );
        int received = resumeOffset;
        try {
          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            onFileProgress(pf.name, received, pf.sizeBytes);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        // Rename partial to final.
        if (partialFile.existsSync()) {
          await partialFile.rename(filePath);
        }

        // Verify checksum.
        onStatus('Verifying ${pf.name}...');
        if (!await verifyChecksum(filePath, pf.sha256)) {
          await File(filePath).delete();
          throw Exception(
              'Checksum verification failed for ${pf.name}. '
              'The file may be corrupt. Please try again.');
        }
      }
    } finally {
      client.close();
    }
  }

  /// Compute SHA256 hex digest of a file using streaming (low memory).
  static Future<String> _sha256File(File file) async {
    final output = AccumulatorSink();
    final input = crypto.sha256.startChunkedConversion(output);
    final stream = file.openRead();
    await for (final chunk in stream) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString();
  }
}

/// Accumulates digest events from chunked hash conversion.
class AccumulatorSink implements Sink<crypto.Digest> {
  final events = <crypto.Digest>[];

  @override
  void add(crypto.Digest event) => events.add(event);

  @override
  void close() {}
}

/// Metadata for a single param file.
class _ParamFile {
  final String name;
  final int sizeBytes;
  final String sha256;

  const _ParamFile({
    required this.name,
    required this.sizeBytes,
    required this.sha256,
  });
}
