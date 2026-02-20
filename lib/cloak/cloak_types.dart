/// Replacement types for warp_api/data_fb_generated.dart FlatBuffer types.
/// Created during CLOAK Wallet transformation (S30 Phase A).
///
/// These types maintain field-name compatibility with the original FlatBuffer
/// types to minimize find-and-replace scope. Fields will be renamed in S31.

/// Replacement for PoolBalanceT.
/// CLOAK has a single shielded pool (mapped to 'sapling' for compatibility).
class CloakBalance {
  int transparent; // always 0 for CLOAK
  int sapling; // CLOAK shielded balance
  int orchard; // always 0 for CLOAK

  CloakBalance({this.transparent = 0, this.sapling = 0, this.orchard = 0});

  int get total => sapling;
}

/// Replacement for AccountT from data_fb_generated.dart.
/// Fields: coin, id, name, keyType, balance, address, saved.
class CloakAccount {
  int coin;
  int id;
  String? name;
  int keyType;
  int balance;
  String? address;
  bool saved;

  CloakAccount({
    this.coin = 0,
    this.id = 0,
    this.name,
    this.keyType = 0,
    this.balance = 0,
    this.address,
    this.saved = false,
  });
}

/// Replacement for ContactT from data_fb_generated.dart.
class CloakContact {
  int id;
  String? name;
  String? address;

  CloakContact({this.id = 0, this.name, this.address});
}

/// Replacement for ProgressT from data_fb_generated.dart.
class SyncProgress {
  int height;
  int timestamp;
  int trialDecryptions;
  int downloaded;
  CloakBalance? balances;

  SyncProgress({
    this.height = 0,
    this.timestamp = 0,
    this.trialDecryptions = 0,
    this.downloaded = 0,
    this.balances,
  });
}

/// Replacement for HeightT from data_fb_generated.dart.
class SyncHeight {
  int height;
  int timestamp;

  SyncHeight({this.height = 0, this.timestamp = 0});
}

/// Replacement for FeeT from data_fb_generated.dart.
class CloakFee {
  int fee;
  int minFee;
  int maxFee;
  int scheme;

  CloakFee({this.fee = 0, this.minFee = 0, this.maxFee = 0, this.scheme = 0});
}
