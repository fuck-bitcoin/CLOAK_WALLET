import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cloak_wallet/update/desktop_update_installer.dart';
import 'package:cloak_wallet/update/update_manifest_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('cloak-archive-test-');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<File> writeZip(Archive archive) async {
    final file = File(p.join(temporaryDirectory.path, 'update.zip'));
    await file.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
    return file;
  }

  test('streams a valid Windows archive into its staging directory', () async {
    final archive = Archive()
      ..add(ArchiveFile.string('CLOAK_Wallet/cloak-wallet.exe', 'binary'))
      ..add(ArchiveFile.string('CLOAK_Wallet/data/readme.txt', 'readme'));
    final zip = await writeZip(archive);
    final destination = Directory(p.join(temporaryDirectory.path, 'staging'));
    await destination.create();

    await DesktopUpdateInstaller()
        .extractWindowsZipForTesting(zip, destination);

    expect(
      await File(p.join(
        destination.path,
        'CLOAK_Wallet',
        'cloak-wallet.exe',
      )).readAsString(),
      'binary',
    );
    expect(
      await File(p.join(
        destination.path,
        'CLOAK_Wallet',
        'data',
        'readme.txt',
      )).readAsString(),
      'readme',
    );
  });

  test('rejects traversal before writing any archive entry', () async {
    final archive = Archive()
      ..add(ArchiveFile.string('CLOAK_Wallet/cloak-wallet.exe', 'binary'))
      ..add(ArchiveFile.string('../escaped.txt', 'escape'));
    final zip = await writeZip(archive);
    final destination = Directory(p.join(temporaryDirectory.path, 'staging'));
    await destination.create();

    await expectLater(
      DesktopUpdateInstaller().extractWindowsZipForTesting(zip, destination),
      throwsA(isA<UpdateException>()),
    );

    expect(
      File(p.join(destination.path, 'CLOAK_Wallet', 'cloak-wallet.exe'))
          .existsSync(),
      isFalse,
    );
    expect(
      File(p.join(temporaryDirectory.path, 'escaped.txt')).existsSync(),
      isFalse,
    );
  });

  test('rejects excessive declared expanded size and file count', () {
    expect(
      () => DesktopUpdateInstaller.validateWindowsArchiveLimits(
        entryCount: 2,
        uncompressedSizes: const [
          512 * 1024 * 1024,
          512 * 1024 * 1024 + 1,
        ],
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(
      () => DesktopUpdateInstaller.validateWindowsArchiveLimits(
        entryCount: 10001,
        uncompressedSizes: const [],
      ),
      throwsA(isA<UpdateException>()),
    );
  });
}
