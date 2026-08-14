import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_manifest.dart';
import 'update_manifest_client.dart';

typedef UpdateDownloadProgress = void Function(int received, int total);

class UpdateDownloader {
  final http.Client client;
  final Directory? rootDirectory;

  const UpdateDownloader(this.client, {this.rootDirectory});

  Future<File> downloadVerified(
    UpdateAsset asset,
    String version, {
    UpdateDownloadProgress? onProgress,
  }) async {
    final temporaryDirectory = rootDirectory ?? await getTemporaryDirectory();
    final updateDirectory = Directory(
      p.join(temporaryDirectory.path, 'cloak-wallet-updates', version),
    );
    await updateDirectory.create(recursive: true);
    final partial = File(p.join(updateDirectory.path, '${asset.name}.part'));
    final completed = File(p.join(updateDirectory.path, asset.name));
    var existing = await partial.exists() ? await partial.length() : 0;
    if (existing > asset.size) {
      await partial.delete();
      existing = 0;
    }

    final request = http.Request('GET', asset.url);
    if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
    final response = await client.send(request);

    if (response.statusCode == 416 && existing == asset.size) {
      final existingHash = await _sha256File(partial);
      if (existingHash == asset.sha256) {
        if (await completed.exists()) await completed.delete();
        return partial.rename(completed.path);
      }
      await partial.delete();
      throw const UpdateException('Partial update failed signed verification');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw UpdateException(
        'Update download returned HTTP ${response.statusCode}',
      );
    }

    if (existing > 0 && response.statusCode == 206) {
      final contentRange = response.headers['content-range'];
      if (contentRange == null ||
          !contentRange.startsWith('bytes $existing-')) {
        throw const UpdateException('Server returned an invalid resume range');
      }
    } else if (existing > 0) {
      // Server ignored Range. Safely restart instead of appending duplicate data.
      await partial.writeAsBytes(const [], flush: true);
      existing = 0;
    }

    var received = existing;
    final digestOutput = AccumulatorSink<Digest>();
    final digestSink = sha256.startChunkedConversion(digestOutput);
    if (existing > 0) {
      await for (final chunk in partial.openRead()) {
        digestSink.add(chunk);
      }
    }
    final output = partial.openWrite(
      mode: existing > 0 ? FileMode.append : FileMode.write,
    );
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > asset.size) {
          throw const UpdateException('Update is larger than its signed size');
        }
        output.add(chunk);
        digestSink.add(chunk);
        onProgress?.call(received, asset.size);
      }
      await output.flush();
      await output.close();
      digestSink.close();
    } catch (_) {
      await output.close();
      digestSink.close();
      rethrow;
    }

    final digest = digestOutput.events.single;
    if (received != asset.size || digest.toString() != asset.sha256) {
      await partial.delete();
      throw const UpdateException('Update size or SHA-256 verification failed');
    }
    if (await completed.exists()) await completed.delete();
    return partial.rename(completed.path);
  }

  Future<String> _sha256File(File file) async {
    final digestOutput = AccumulatorSink<Digest>();
    final digestSink = sha256.startChunkedConversion(digestOutput);
    await for (final chunk in file.openRead()) {
      digestSink.add(chunk);
    }
    digestSink.close();
    return digestOutput.events.single.toString();
  }
}
