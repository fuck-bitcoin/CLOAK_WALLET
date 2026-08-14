import 'package:cloak_wallet/update/update_install_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(UpdateInstallGate.release);

  test('gate is held before the final safety check runs', () {
    var observedHeldGate = false;

    final acquired = UpdateInstallGate.tryAcquire(() {
      observedHeldGate = UpdateInstallGate.isApplyingUpdate;
      return true;
    });

    expect(acquired, isTrue);
    expect(observedHeldGate, isTrue);
    expect(UpdateInstallGate.tryAcquire(() => true), isFalse);
  });

  test('failed final safety check releases the gate', () {
    expect(UpdateInstallGate.tryAcquire(() => false), isFalse);
    expect(UpdateInstallGate.isApplyingUpdate, isFalse);
  });
}
