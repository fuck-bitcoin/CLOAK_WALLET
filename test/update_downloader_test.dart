import 'dart:async';
import 'dart:io';

import 'package:cloak_wallet/update/update_downloader.dart';
import 'package:cloak_wallet/update/update_manifest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('cloak-update-test-');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('resumes an interrupted download with an exact Range request', () async {
    final bytes = List<int>.generate(10, (index) => index);
    final asset = _asset(bytes);
    final interruptedClient = _StreamingClient((request) async {
      expect(request.headers['Range'], isNull);
      return http.StreamedResponse(_interrupted(bytes.sublist(0, 4)), 200);
    });

    await expectLater(
      UpdateDownloader(
        interruptedClient,
        rootDirectory: temporaryDirectory,
      ).downloadVerified(asset, '2.1.1'),
      throwsA(isA<IOException>()),
    );

    final resumedClient = _StreamingClient((request) async {
      expect(request.headers['Range'], 'bytes=4-');
      return http.StreamedResponse(
        Stream.value(bytes.sublist(4)),
        206,
        headers: {'content-range': 'bytes 4-9/10'},
      );
    });
    final completed = await UpdateDownloader(
      resumedClient,
      rootDirectory: temporaryDirectory,
    ).downloadVerified(asset, '2.1.1');

    expect(await completed.readAsBytes(), bytes);
  });

  test('restarts safely when a server ignores Range', () async {
    final bytes = List<int>.generate(10, (index) => 20 + index);
    final asset = _asset(bytes);
    final partial = File(
      '${temporaryDirectory.path}/cloak-wallet-updates/2.1.1/${asset.name}.part',
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(bytes.sublist(0, 5));

    final client = _StreamingClient((request) async {
      expect(request.headers['Range'], 'bytes=5-');
      return http.StreamedResponse(Stream.value(bytes), 200);
    });
    final completed = await UpdateDownloader(
      client,
      rootDirectory: temporaryDirectory,
    ).downloadVerified(asset, '2.1.1');

    expect(await completed.readAsBytes(), bytes);
  });

  test('accepts a complete verified part after HTTP 416', () async {
    final bytes = List<int>.generate(10, (index) => 40 + index);
    final asset = _asset(bytes);
    final partial = File(
      '${temporaryDirectory.path}/cloak-wallet-updates/2.1.1/${asset.name}.part',
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(bytes);

    final client = _StreamingClient((request) async {
      expect(request.headers['Range'], 'bytes=10-');
      return http.StreamedResponse(const Stream.empty(), 416);
    });
    final completed = await UpdateDownloader(
      client,
      rootDirectory: temporaryDirectory,
    ).downloadVerified(asset, '2.1.1');

    expect(await completed.readAsBytes(), bytes);
    expect(await partial.exists(), isFalse);
  });
}

UpdateAsset _asset(List<int> bytes) => UpdateAsset(
      name: 'wallet.bin',
      platform: 'windows',
      architecture: 'x64',
      url: Uri.parse('https://github.com/example/wallet.bin'),
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );

Stream<List<int>> _interrupted(List<int> bytes) async* {
  yield bytes;
  throw const FileSystemException('connection interrupted');
}

class _StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  _StreamingClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }
}
