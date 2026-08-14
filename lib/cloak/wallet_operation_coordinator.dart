import 'dart:async';

/// Coalesces concurrent calls into one asynchronous operation and clears the
/// shared future after either success or failure so a failed load is retryable.
class AsyncSingleFlight<T> {
  Future<T>? _inFlight;

  bool get isActive => _inFlight != null;

  Future<T> run(Future<T> Function() operation) {
    final existing = _inFlight;
    if (existing != null) return existing;

    late final Future<T> tracked;
    tracked = Future<T>.sync(operation).then(
      (value) {
        if (identical(_inFlight, tracked)) _inFlight = null;
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_inFlight, tracked)) _inFlight = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _inFlight = tracked;
    return tracked;
  }
}

bool walletOperationMayRunWhilePending(String label) =>
    !label.toLowerCase().contains('sync');

/// FIFO, zone-reentrant mutex used for all access to the native Rust wallet.
///
/// The wallet is a raw pointer shared with worker isolates. A boolean "locked"
/// flag does not serialize callers: two async callers can both observe it as
/// unlocked before either begins an FFI call. This coordinator queues callers
/// and keeps ownership across `await`s. Calls made by an operation already
/// holding the mutex are reentrant, which lets a proof operation safely call
/// the normal save/restore helpers without deadlocking itself.
class WalletOperationCoordinator {
  final Object _zoneKey = Object();
  Future<void> _tail = Future<void>.value();
  int _activeDepth = 0;
  int _queued = 0;
  String? _activeLabel;
  Object? _activeOwner;

  bool get isActive => _activeDepth != 0;
  bool get isHeldByCurrentZone =>
      _activeOwner != null && identical(Zone.current[_zoneKey], _activeOwner);
  int get queuedOperationCount => _queued;
  String? get activeLabel => _activeLabel;

  Future<T> runExclusive<T>(
    String label,
    FutureOr<T> Function() action,
  ) async {
    if (_activeOwner != null &&
        identical(Zone.current[_zoneKey], _activeOwner)) {
      _activeDepth++;
      try {
        return await action();
      } finally {
        _activeDepth--;
      }
    }

    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    _queued++;
    await predecessor;
    _queued--;

    _activeDepth = 1;
    _activeLabel = label;
    final owner = Object();
    _activeOwner = owner;
    try {
      return await runZoned<Future<T>>(
        () async => await action(),
        zoneValues: {_zoneKey: owner},
      );
    } finally {
      _activeDepth = 0;
      _activeLabel = null;
      _activeOwner = null;
      release.complete();
    }
  }
}
