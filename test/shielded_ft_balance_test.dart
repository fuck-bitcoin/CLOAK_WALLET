import 'dart:convert';

import 'package:cloak_wallet/cloak/shielded_ft_balance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFixedAssetAmount', () {
    test('uses exact fixed-point units', () {
      expect(parseFixedAssetAmount('12.3400'), (units: 123400, precision: 4));
      expect(parseFixedAssetAmount('0.0001'), (units: 1, precision: 4));
      expect(parseFixedAssetAmount('0'), (units: 0, precision: 0));
    });

    test('rejects signed and malformed amounts', () {
      expect(parseFixedAssetAmount('-0.0001'), isNull);
      expect(parseFixedAssetAmount('1.'), isNull);
      expect(parseFixedAssetAmount('.1'), isNull);
      expect(parseFixedAssetAmount('not-a-number'), isNull);
    });
  });

  group('exact unit conversion', () {
    test('formats high-precision values above the double integer limit', () {
      expect(
        formatAssetUnits(9007199254740993123, 8),
        '90071992547.40993123',
      );
      expect(formatAssetUnits(1, 8), '0.00000001');
      expect(formatAssetUnits(42, 0), '42');
    });

    test('parses at declared precision without rounding', () {
      expect(parseAssetUnitsAtPrecision('12.34', 4), 123400);
      expect(parseAssetUnitsAtPrecision('1.', 4), 10000);
      expect(parseAssetUnitsAtPrecision('0.0001', 4), 1);
      expect(parseAssetUnitsAtPrecision('0.00001', 4), isNull);
    });
  });

  group('parsePositiveShieldedFtBalances', () {
    test('omits exact zero while retaining dust', () {
      final raw = jsonEncode([
        '0.0000 ZERO@zero.token',
        '0 ZERO0@zero0.token',
        '0.0001 DUST@dust.token',
      ]);

      final balances = parsePositiveShieldedFtBalances(raw);

      expect(balances, hasLength(1));
      expect(balances.single.symbol, 'DUST');
      expect(balances.single.contract, 'dust.token');
      expect(balances.single.units, 1);
      expect(balances.single.precision, 4);
    });

    test('preserves symbol and contract identity', () {
      final raw = jsonEncode([
        '1.0000 SAME@token.one',
        '2.0000 SAME@token.two',
      ]);

      final balances = parsePositiveShieldedFtBalances(raw);

      expect(
        balances.map((balance) => '${balance.symbol}@${balance.contract}'),
        ['SAME@token.one', 'SAME@token.two'],
      );
      expect(balances.map((balance) => balance.units), [10000, 20000]);
    });

    test('skips malformed entries without losing valid balances', () {
      final raw = jsonEncode([
        'missing-contract',
        '1.0000 @token.one',
        '1.0000 GOOD@good.token',
        42,
      ]);

      final balances = parsePositiveShieldedFtBalances(raw);

      expect(balances, hasLength(1));
      expect(balances.single.symbol, 'GOOD');
    });

    test('returns an empty list for invalid JSON shape', () {
      expect(parsePositiveShieldedFtBalances('{"balance": 1}'), isEmpty);
      expect(parsePositiveShieldedFtBalances('not json'), isEmpty);
      expect(parsePositiveShieldedFtBalances(null), isEmpty);
    });
  });
}
