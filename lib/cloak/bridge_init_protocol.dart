class BridgeInitExtraction {
  final bool enabled;
  final Map<String, dynamic> cleanedParams;

  const BridgeInitExtraction({
    required this.enabled,
    required this.cleanedParams,
  });
}

class BridgeInitProtocol {
  static Map<String, dynamic> buildLoginResponse({
    bool supportsBridgeInitV1 = false,
  }) {
    return {
      'status': 'success',
      'result': 'anonymous',
      if (supportsBridgeInitV1) 'capabilities': {'bridge_init_v1': true},
    };
  }

  static BridgeInitExtraction extractBridgeInitRequest(
    Map<String, dynamic> params,
  ) {
    final cleanedParams = Map<String, dynamic>.from(params);
    final bridgeInit = cleanedParams.remove('bridge_init');
    final enabled = bridgeInit is Map &&
        bridgeInit['version'] == 1 &&
        bridgeInit['derive_receive_address'] == true;

    return BridgeInitExtraction(enabled: enabled, cleanedParams: cleanedParams);
  }

  static Map<String, dynamic> buildTransactSuccessResponse({
    required String txId,
    String? z01Address,
  }) {
    return {
      'status': 'success',
      'result': txId,
      if (z01Address != null && z01Address.isNotEmpty)
        'z01_address': z01Address,
    };
  }
}
