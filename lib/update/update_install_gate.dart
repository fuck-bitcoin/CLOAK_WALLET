/// Single-isolate gate that closes the check-to-apply race for wallet updates.
///
/// Sensitive-operation entry points must reject new work while this gate is
/// held. Acquisition sets the gate before performing the final safety check,
/// so no Dart event can begin between those two operations.
class UpdateInstallGate {
  static bool _applying = false;

  static bool get isApplyingUpdate => _applying;

  static bool tryAcquire(bool Function() finalSafetyCheck) {
    if (_applying) return false;
    _applying = true;
    if (finalSafetyCheck()) return true;
    _applying = false;
    return false;
  }

  static void release() {
    _applying = false;
  }
}
