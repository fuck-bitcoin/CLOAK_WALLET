import 'dart:math';

class _PeerState {
  final String url;
  int consecutiveFails = 0;
  int coolDownUntilMs = 0;
  int lastOkMs = 0;

  _PeerState(this.url);
}

class PeerManager {
  static const List<String> _peerUrls = [
    'https://telos.eosusa.io',
    'https://telos.api.eosnation.io',
    'https://telos.eosphere.io',
    'https://telos.eu.eosamsterdam.net',
    'https://api.telosunlimited.com',
    'https://api.telosarabia.net',
    'https://telosgermany.genereos.io',
    // Removed: telos.caleos.io (expired SSL cert), telos.cryptolions.io (chronic timeouts)
  ];

  static const double _backoffBaseMs = 1500; // 1.5s
  static const double _backoffMultiplier = 2.0;
  static const int _backoffCapMs = 15000; // 15s
  static const int _maxDoublings = 6;

  final List<_PeerState> _peers;
  final Random _rng;

  PeerManager({Random? rng})
      : _peers = _peerUrls.map((u) => _PeerState(u)).toList(),
        _rng = rng ?? Random();

  String pickPeer() {
    final now = DateTime.now().millisecondsSinceEpoch;

    final healthy = <_PeerState>[];
    for (final p in _peers) {
      if (p.coolDownUntilMs <= now) {
        healthy.add(p);
      }
    }

    if (healthy.isNotEmpty) {
      return healthy[_rng.nextInt(healthy.length)].url;
    }

    // All peers are in cooldown — return the one whose cooldown expires first.
    _PeerState earliest = _peers[0];
    for (int i = 1; i < _peers.length; i++) {
      if (_peers[i].coolDownUntilMs < earliest.coolDownUntilMs) {
        earliest = _peers[i];
      }
    }
    return earliest.url;
  }

  void reportSuccess(String url) {
    final p = _find(url);
    if (p == null) return;
    p.consecutiveFails = 0;
    p.coolDownUntilMs = 0;
    p.lastOkMs = DateTime.now().millisecondsSinceEpoch;
  }

  void reportFailure(String url) {
    final p = _find(url);
    if (p == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    p.consecutiveFails++;
    final doublings = p.consecutiveFails.clamp(0, _maxDoublings);
    final delayMs =
        (_backoffBaseMs * pow(_backoffMultiplier, doublings - 1)).round();
    p.coolDownUntilMs = now + delayMs.clamp(0, _backoffCapMs);
  }

  _PeerState? _find(String url) {
    for (final p in _peers) {
      if (p.url == url) return p;
    }
    return null;
  }
}
