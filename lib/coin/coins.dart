import 'coin.dart';
import 'cloak.dart';
import 'ycash.dart';
import 'zcash.dart';
import 'zcashtest.dart';

CoinBase cloak = CloakCoin();
CoinBase ycash = YcashCoin();
CoinBase zcash = ZcashCoin();
CoinBase zcashtest = ZcashTestCoin();

final coins = [zcash, ycash, cloak];

final activationDate = DateTime(2018, 10, 29);
