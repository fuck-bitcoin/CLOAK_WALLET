import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:cloak_wallet/update/update_coordinator.dart';

void main() {
  test('health token parsing requires one exact lowercase token', () {
    const token = '0123456789abcdef0123456789abcdef';
    expect(
      UpdateCoordinator.healthTokenFromArguments(
        const ['--cloak-update-health=$token'],
      ),
      token,
    );
    expect(
      UpdateCoordinator.healthTokenFromArguments(
        const ['--cloak-update-health=../../escape'],
      ),
      isNull,
    );
    expect(
      UpdateCoordinator.healthTokenFromArguments(
        const [
          '--cloak-update-health=$token',
          '--cloak-update-health=$token',
        ],
      ),
      isNull,
    );
  });

  test('health acknowledgement is confined to the system temp directory',
      () async {
    const token = 'fedcba9876543210fedcba9876543210';
    final marker = UpdateCoordinator.healthFileForToken(token);
    addTearDown(() async {
      if (await marker.exists()) await marker.delete();
    });
    if (await marker.exists()) await marker.delete();

    expect(p.equals(marker.parent.path, Directory.systemTemp.path), isTrue);
    expect(p.basename(marker.path), 'cloak-wallet-update-$token.ok');

    await UpdateCoordinator.acknowledgeHealthCheck(
      const ['--cloak-update-health=$token'],
    );
    expect(await marker.readAsString(), startsWith('ok '));
  });
}
