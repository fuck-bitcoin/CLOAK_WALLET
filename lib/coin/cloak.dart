import 'package:flutter/material.dart';

import 'coin.dart';

class CloakCoin extends CoinBase {
  int coin = 2;  // 0=Zcash, 1=Ycash, 2=Cloak
  String name = "Cloak";
  String app = "CloakWallet";
  String symbol = "🥷";  // Ninja emoji for privacy
  String currency = "cloak";
  int coinIndex = 888;  // Unofficial - ZEOS doesn't have registered coin type
  String ticker = "CLOAK";
  String dbName = "cloak.wallet";  // Binary wallet file, not SQLite
  String? marketTicker = null;  // No market ticker yet
  AssetImage image = AssetImage('assets/cloak_logo.png');
  
  // EOSIO endpoints (Telos network) - NOT lightwalletd!
  List<LWInstance> lwd = [
    LWInstance("Telos Mainnet (EOSUSA)", "https://telos.eosusa.io"),
    LWInstance("Telos Mainnet (Caleos)", "https://telos.caleos.io"),
    LWInstance("Telos Mainnet (EOSNation)", "https://telos.api.eosnation.io"),
    LWInstance("Telos Testnet", "https://testnet.telos.caleos.io"),
  ];
  
  int defaultAddrMode = 0;
  int defaultUAType = 0;  // ZEOS doesn't use Zcash unified addresses
  bool supportsUA = false;
  bool supportsMultisig = false;
  bool supportsLedger = false;
  List<double> weights = [0.05, 0.25, 2.50];  // Fee weights
  List<String> blockExplorers = [
    "https://explorer.telos.net/transaction",
  ];
}

// EOSIO/Telos specific constants
const String TELOS_CHAIN_ID = '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11';
const String ZEOS_PROTOCOL_CONTRACT = 'zeosprotocol';
const String ZEOS_VAULT_CONTRACT = 'thezeosvault';
