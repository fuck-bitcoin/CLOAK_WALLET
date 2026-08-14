import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'update_manifest_client.dart';
import 'update_shutdown.dart';

class DesktopUpdateInstaller {
  static final RegExp _tokenPattern = RegExp(r'^[0-9a-f]{32}$');
  static const int _maximumWindowsArchiveFiles = 10000;
  static const int _maximumWindowsUncompressedBytes = 1024 * 1024 * 1024;

  Future<Never> installWindows(File archiveFile) async {
    final currentDirectory = File(Platform.resolvedExecutable).parent;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw const UpdateException(
        'Could not validate the managed Windows installation',
      );
    }
    final expectedDirectory = p.normalize(
      p.absolute(p.join(localAppData, 'cloak-wallet', 'app')),
    );
    if (!p.equals(
        p.normalize(currentDirectory.absolute.path), expectedDirectory)) {
      throw const UpdateException(
        'This Windows layout cannot be auto-swapped safely. Use the verified '
        'installer from the CLOAK GitHub release.',
      );
    }
    final token = _newToken();
    final unpackRoot = Directory(
      p.join(currentDirectory.parent.path, '.cloak-unpack-$token'),
    );
    final finalStagedDirectory = Directory(
      p.join(currentDirectory.parent.path, '.cloak-update-$token'),
    );
    await unpackRoot.create(recursive: true);
    await _extractWindowsZip(archiveFile, unpackRoot);

    final executables = unpackRoot
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where(
            (file) => p.basename(file.path).toLowerCase() == 'cloak-wallet.exe')
        .toList();
    if (executables.length != 1) {
      throw const UpdateException('Staged Windows update is malformed');
    }
    final extractedDirectory = executables.single.parent;
    await extractedDirectory.rename(finalStagedDirectory.path);
    if (await unpackRoot.exists()) {
      await unpackRoot.delete(recursive: true);
    }
    final previousDirectory = Directory('${currentDirectory.path}.previous');
    final script = await _materializeHelper('windows-update.ps1', token);
    final readyFile = await _clearHelperReadyFile(token);
    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-ParentPid',
          '$pid',
          '-CurrentDir',
          currentDirectory.path,
          '-StagedDir',
          finalStagedDirectory.path,
          '-PreviousDir',
          previousDirectory.path,
          '-HealthToken',
          token,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (error) {
      throw UpdateException(
          'Could not start the Windows update helper: $error');
    }
    await _waitForHelperReady(readyFile, token, 'Windows');
    // The helper validates its paths, then waits for this process to exit. If
    // wallet preparation fails, this process stays alive and no swap occurs.
    await UpdateShutdown.prepareForUpdate();
    UpdateShutdown.exitPrepared();
  }

  Future<Never> installLinuxAppImage(File downloadedAppImage) async {
    final appImagePath = Platform.environment['APPIMAGE'];
    if (appImagePath == null || appImagePath.isEmpty) {
      throw const UpdateException(
        'Automatic Linux updates require the AppImage installation',
      );
    }
    final current = File(p.normalize(p.absolute(appImagePath)));
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const UpdateException(
          'Could not validate the Linux install layout');
    }
    final dataHome = Platform.environment['XDG_DATA_HOME'];
    final expected = p.normalize(p.join(
      dataHome == null || dataHome.isEmpty
          ? p.join(home, '.local', 'share')
          : dataHome,
      'cloak-wallet',
      'CLOAK_Wallet-x86_64.AppImage',
    ));
    if (current.path != expected) {
      throw const UpdateException(
        'This Linux layout cannot be auto-swapped safely. Use the verified '
        'installer from the CLOAK GitHub release.',
      );
    }
    if (!await current.exists()) {
      throw const UpdateException('Running AppImage could not be located');
    }
    final writeProbe =
        File(p.join(current.parent.path, '.cloak-update-write-test'));
    try {
      await writeProbe.writeAsString('ok', flush: true);
      await writeProbe.delete();
    } catch (_) {
      throw const UpdateException(
        'The official CLOAK AppImage directory is not writable',
      );
    }
    final token = _newToken();
    final staged = File('${current.path}.update-$token');
    final previous = File('${current.path}.previous');
    await downloadedAppImage.copy(staged.path);
    final chmod = await Process.run('chmod', ['700', staged.path]);
    if (chmod.exitCode != 0) {
      throw const UpdateException(
          'Could not make the staged AppImage executable');
    }
    final script = await _materializeHelper('linux-update.sh', token);
    final readyFile = await _clearHelperReadyFile(token);
    try {
      await Process.start(
        '/bin/bash',
        [
          script.path,
          '$pid',
          current.path,
          staged.path,
          previous.path,
          token,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (error) {
      throw UpdateException('Could not start the Linux update helper: $error');
    }
    await _waitForHelperReady(readyFile, token, 'Linux');
    // The helper cannot move the AppImage while this process remains alive.
    await UpdateShutdown.prepareForUpdate();
    UpdateShutdown.exitPrepared();
  }

  Future<void> _extractWindowsZip(File zip, Directory destination) async {
    InputFileStream? input;
    Archive? archive;
    try {
      input = InputFileStream(zip.path);
      final decoder = ZipDecoder();
      archive = decoder.decodeStream(input, verify: true);
      validateWindowsArchiveLimits(
        entryCount: decoder.directory.fileHeaders.length,
        uncompressedSizes: decoder.directory.fileHeaders.map(
          (header) => header.file?.uncompressedSize ?? -1,
        ),
      );

      // Validate the entire central directory before writing the first byte.
      final outputs = <(ArchiveFile, String)>[];
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        final components = p.posix.split(name);
        if (name.startsWith('/') ||
            RegExp(r'^[A-Za-z]:').hasMatch(name) ||
            components.contains('..') ||
            entry.isSymbolicLink) {
          throw const UpdateException('Unsafe path in update archive');
        }
        final outputPath = p.normalize(
          p.joinAll([destination.path, ...components]),
        );
        if (!p.isWithin(destination.path, outputPath)) {
          throw const UpdateException(
            'Update archive escapes staging directory',
          );
        }
        outputs.add((entry, outputPath));
      }

      for (final (entry, outputPath) in outputs) {
        if (entry.isFile) {
          await Directory(p.dirname(outputPath)).create(recursive: true);
          final output = _LimitedOutputFileStream(outputPath, entry.size);
          try {
            entry.writeContent(output);
            if (output.length != entry.size) {
              throw const UpdateException(
                'Update archive entry has an invalid expanded size',
              );
            }
          } finally {
            await output.close();
          }
        } else {
          await Directory(outputPath).create(recursive: true);
        }
      }
    } on ArchiveException catch (error) {
      throw UpdateException('Could not decode the Windows update: $error');
    } finally {
      try {
        await archive?.clear();
      } finally {
        await input?.close();
      }
    }
  }

  @visibleForTesting
  static void validateWindowsArchiveLimits({
    required int entryCount,
    required Iterable<int> uncompressedSizes,
  }) {
    if (entryCount <= 0 || entryCount > _maximumWindowsArchiveFiles) {
      throw const UpdateException('Update archive has an invalid file count');
    }
    var total = 0;
    var sizesSeen = 0;
    for (final size in uncompressedSizes) {
      sizesSeen++;
      if (size < 0 || size > _maximumWindowsUncompressedBytes - total) {
        throw const UpdateException(
          'Update archive exceeds its expanded-size limit',
        );
      }
      total += size;
    }
    if (sizesSeen != entryCount) {
      throw const UpdateException('Update archive directory is inconsistent');
    }
  }

  @visibleForTesting
  Future<void> extractWindowsZipForTesting(
    File zip,
    Directory destination,
  ) =>
      _extractWindowsZip(zip, destination);

  Future<File> _materializeHelper(String name, String token) async {
    if (!_tokenPattern.hasMatch(token)) {
      throw const UpdateException('Invalid update health token');
    }
    final contents = await rootBundle.loadString('assets/updater/$name');
    final file = File(p.join(
      Directory.systemTemp.path,
      'cloak-wallet-$token-$name',
    ));
    await file.writeAsString(contents, flush: true);
    return file;
  }

  Future<File> _clearHelperReadyFile(String token) async {
    final file = File(p.join(
      Directory.systemTemp.path,
      'cloak-wallet-update-$token.ready',
    ));
    if (await file.exists()) await file.delete();
    return file;
  }

  Future<void> _waitForHelperReady(
    File file,
    String token,
    String platform,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        final contents = await file.readAsString();
        await file.delete();
        if (contents == token) return;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw UpdateException(
      '$platform update helper did not validate its staging paths',
    );
  }

  String _newToken() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Streams one expanded ZIP entry to disk while refusing to exceed the size
/// declared in the signed archive directory. This prevents a malformed
/// deflate stream from consuming unbounded disk before the post-write size
/// check can run.
class _LimitedOutputFileStream extends OutputFileStream {
  final int maximumBytes;

  _LimitedOutputFileStream(String path, this.maximumBytes)
      : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  void _requireCapacity(int additionalBytes) {
    if (additionalBytes < 0 || length > maximumBytes - additionalBytes) {
      throw const UpdateException(
        'Update archive entry exceeds its declared expanded size',
      );
    }
  }

  @override
  void writeByte(int value) {
    _requireCapacity(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final writeLength = length ?? bytes.length;
    _requireCapacity(writeLength);
    super.writeBytes(bytes, length: writeLength);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final length = min(stream.length, chunkSize);
      if (length <= 0) break;
      writeBytes(stream.readBytes(length).toUint8List());
    }
  }
}
