import 'dart:convert';

/// A positive shielded fungible-token balance returned by the Rust wallet.
class ShieldedFtBalance {
  final String symbol;
  final String contract;
  final String amount;
  final int precision;
  final int units;

  const ShieldedFtBalance({
    required this.symbol,
    required this.contract,
    required this.amount,
    required this.precision,
    required this.units,
  });
}

/// Parse a non-negative fixed-point amount without using floating point.
///
/// Returns `(units, precision)` for syntactically valid amounts, including
/// zero. A null result means the amount is malformed or outside Dart's `int`
/// range on the current platform.
({int units, int precision})? parseFixedAssetAmount(String rawAmount) {
  final amount = rawAmount.trim();
  final match = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(amount);
  if (match == null) return null;

  final fraction = match.group(2) ?? '';
  final digits = '${match.group(1)!}$fraction';
  final units = int.tryParse(digits);
  if (units == null) return null;

  return (units: units, precision: fraction.length);
}

/// Parse a user-entered decimal into exact smallest units at [precision].
/// Fewer fractional digits are right-padded; values with excess precision are
/// rejected instead of rounded.
int? parseAssetUnitsAtPrecision(String rawAmount, int precision) {
  if (precision < 0 || precision > 18) return null;
  final amount = rawAmount.trim();
  final match = RegExp(r'^(\d+)(?:\.(\d*))?$').firstMatch(amount);
  if (match == null) return null;
  final fraction = match.group(2) ?? '';
  if (fraction.length > precision) return null;
  final digits = '${match.group(1)!}${fraction.padRight(precision, '0')}';
  return int.tryParse(digits);
}

/// Return the integer number of smallest units per whole token.
int assetUnitScale(int precision) {
  if (precision < 0 || precision > 18) {
    throw RangeError.range(precision, 0, 18, 'precision');
  }
  var scale = 1;
  for (var i = 0; i < precision; i++) {
    scale *= 10;
  }
  return scale;
}

/// Format exact smallest units without converting through floating point.
String formatAssetUnits(int units, int precision) {
  final scale = assetUnitScale(precision);
  final negative = units < 0;
  final magnitude = units.abs();
  final whole = magnitude ~/ scale;
  final sign = negative ? '-' : '';
  if (precision == 0) return '$sign$whole';
  final fraction = (magnitude % scale).toString().padLeft(precision, '0');
  return '$sign$whole.$fraction';
}

/// Parse Rust `wallet_balances_json` output and retain owned FT balances only.
///
/// Token identity is the pair `(symbol, contract)`. Exact zero balances are
/// omitted while one-smallest-unit dust remains visible.
List<ShieldedFtBalance> parsePositiveShieldedFtBalances(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return const [];

  final balances = <ShieldedFtBalance>[];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];

    for (final entry in decoded) {
      if (entry is! String) continue;

      final atIndex = entry.lastIndexOf('@');
      if (atIndex <= 0 || atIndex == entry.length - 1) continue;

      final quantity = entry.substring(0, atIndex).trim();
      final contract = entry.substring(atIndex + 1).trim();
      final spaceIndex = quantity.lastIndexOf(' ');
      if (spaceIndex <= 0 || spaceIndex == quantity.length - 1) continue;

      final amount = quantity.substring(0, spaceIndex).trim();
      final symbol = quantity.substring(spaceIndex + 1).trim();
      if (symbol.isEmpty || contract.isEmpty) continue;

      final parsedAmount = parseFixedAssetAmount(amount);
      if (parsedAmount == null || parsedAmount.units <= 0) continue;

      balances.add(ShieldedFtBalance(
        symbol: symbol,
        contract: contract,
        amount: amount,
        precision: parsedAmount.precision,
        units: parsedAmount.units,
      ));
    }
  } catch (_) {
    return const [];
  }

  return balances;
}
