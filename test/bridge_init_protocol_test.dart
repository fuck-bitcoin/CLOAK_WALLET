import 'package:flutter_test/flutter_test.dart';
import 'package:cloak_wallet/cloak/bridge_init_protocol.dart';

void main() {
  test('login response advertises bridge init capability when enabled', () {
    final response = BridgeInitProtocol.buildLoginResponse(supportsBridgeInitV1: true);

    expect(response['status'], 'success');
    expect(response['result'], 'anonymous');
    expect(response['capabilities'], {'bridge_init_v1': true});
  });

  test('extractBridgeInitRequest strips extension metadata before ztx encoding', () {
    final params = {
      'chain_id': 'abc',
      'bridge_init': {'version': 1, 'derive_receive_address': true},
      'zactions': [],
    };

    final extracted = BridgeInitProtocol.extractBridgeInitRequest(params);

    expect(extracted.enabled, isTrue);
    expect(extracted.cleanedParams.containsKey('bridge_init'), isFalse);
    expect(extracted.cleanedParams['chain_id'], 'abc');
  });

  test('optimized transact success response includes tx id and receive address', () {
    final response = BridgeInitProtocol.buildTransactSuccessResponse(
      txId: '0xabc',
      z01Address: 'za1testaddress',
    );

    expect(response['status'], 'success');
    expect(response['result'], '0xabc');
    expect(response['z01_address'], 'za1testaddress');
  });
}
