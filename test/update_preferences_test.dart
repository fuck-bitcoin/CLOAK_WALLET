import 'package:cloak_wallet/update/update_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('automatic update checks default on and persist user opt-out', () async {
    SharedPreferences.setMockInitialValues({});
    final coordinator = UpdateCoordinator.instance;

    await coordinator.loadPreferences();
    expect(coordinator.automaticChecksEnabled.value, isTrue);

    await coordinator.setAutomaticChecksEnabled(false);
    expect(coordinator.automaticChecksEnabled.value, isFalse);
    expect(
      (await SharedPreferences.getInstance())
          .getBool('cloak_update_automatic_checks_v1'),
      isFalse,
    );
  });

  test('automatic check interval is reserved before the network attempt',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final firstAttempt = DateTime.utc(2026, 8, 13, 12);

    expect(
      await UpdateCoordinator.reserveAutomaticCheckAttempt(
        prefs,
        now: firstAttempt,
      ),
      isTrue,
    );
    expect(
      prefs.getInt('cloak_update_last_check_v1'),
      firstAttempt.millisecondsSinceEpoch,
    );
    expect(
      await UpdateCoordinator.reserveAutomaticCheckAttempt(
        prefs,
        now: firstAttempt.add(const Duration(hours: 23)),
      ),
      isFalse,
    );
    expect(
      await UpdateCoordinator.reserveAutomaticCheckAttempt(
        prefs,
        now: firstAttempt.add(const Duration(hours: 24)),
      ),
      isTrue,
    );
  });
}
