import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:ui' show FontFeature;
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';

import '../../appsettings.dart';
import '../../theme/zashi_tokens.dart';
import '../../store2.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../main.dart' as mainDart;
import '../../cloak/cloak_wallet_manager.dart';
import '../utils.dart';

class BalanceWidget extends StatefulWidget {
  final int mode;
  final void Function()? onMode;
  /// If set, overrides aa.poolBalances for the balance display.
  /// Used by vault deposit flow to show wallet balance instead of vault balance.
  final int? balanceOverride;
  BalanceWidget(this.mode, {this.onMode, this.balanceOverride, super.key});
  @override
  State<StatefulWidget> createState() => BalanceState();
}

class BalanceState extends State<BalanceWidget> {
  @override
  void initState() {
    super.initState();
    // Load any cached price immediately for instant USD display, then refresh
    Future(() async {
      await marketPrice.loadFromCache();
      await marketPrice.update();
    });
  }

  String _formatFiat(double x) =>
      formatFiatDynamic(x, symbol: appSettings.currency);

  /// Insert a space between currency symbol and digits, e.g. "USD0.0063" → "USD 0.0063"
  String _spaceFiat(String s) {
    final m = RegExp(r'^([A-Z]{3})(\d)').firstMatch(s);
    if (m != null) return '${m.group(1)} ${s.substring(3)}';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mode = widget.mode;

    final color = mode == 0
        ? t.colorScheme.secondary
        : mode == 1
            ? t.colorScheme.primaryContainer
            : t.colorScheme.primary;

    return Observer(builder: (context) {
      aaSequence.settingsSeqno;
      aa.height;
      aa.currency;
      aa.poolBalances; // Watch pool balances directly
      appStore.flat;
      appStore.hideBalances;
      // Watch for pending migration changes
      pendingMigrations.pending.length;

      // Only obey manual eyeball toggle; ignore tilt-to-hide (disabled)
      final hideBalance = false;
      if (hideBalance) return SizedBox();

      final c = coins[aa.coin];
      final isCloak = CloakWalletManager.isCloak(aa.coin);

      // Format balance based on coin precision
      // CLOAK: 4 decimals (10000 smallest units = 1.0000 CLOAK)
      // ZEC/YEC: 8 decimals (100000000 smallest units = 1.00000000 ZEC)
      final String balHi;
      final String balLo;
      final double balFiatValue;

      if (isCloak) {
        // CLOAK: X.XXXX format (4 decimals)
        final wholePart = balance ~/ 10000;
        final fracPart = balance % 10000;
        balHi = wholePart.toString();
        balLo = '.${fracPart.toString().padLeft(4, '0')}';
        balFiatValue = balance / mainDart.CLOAKUNIT;
      } else {
        // ZEC/YEC: XXX.XXX + XXXXX format (8 decimals)
        balHi = decimalFormat((balance ~/ 100000) / 1000.0, 3);
        balLo = (balance % 100000).toString().padLeft(5, '0');
        balFiatValue = balance / mainDart.ZECUNIT;
      }

      final fiat = marketPrice.price;
      final balFiat = fiat?.let((fx) => balFiatValue * fx);
      final txtFiat = fiat?.let(_formatFiat);
      final txtBalFiat = balFiat?.let(_formatFiat);

      final shouldHide = appStore.hideBalances;
      final balanceWidget = shouldHide
          ? RichText(
              textAlign: TextAlign.center,
              text: TextSpan(children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: Transform.translate(
                    offset: const Offset(0, -6),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: SvgPicture.asset(
                        isCloak ? 'assets/icons/cloak_glyph.svg' : 'assets/icons/zec_glyph.svg',
                        width: 28,
                        height: 28,
                        colorFilter: const ColorFilter.mode(Color(0xFFBDBDBD), BlendMode.srcIn),
                      ),
                    ),
                  ),
                ),
                const WidgetSpan(child: SizedBox(width: 6)),
                TextSpan(
                  text: '\u2013 \u2013',
                  style: t.textTheme.displaySmall?.copyWith(
                    color: const Color(0xFFBDBDBD),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                TextSpan(
                  text: '.\u2013 \u2013 \u2013 \u2013',
                  style: (isCloak ? t.textTheme.headlineSmall : t.textTheme.titleMedium)?.copyWith(
                    color: const Color(0xFFBDBDBD),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ], style: t.textTheme.bodyMedium),
            )
          : RichText(
        textAlign: TextAlign.center,
        text: TextSpan(children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: const Offset(0, -6),
              child: SizedBox(
                width: 28,
                height: 28,
                child: SvgPicture.asset(
                  isCloak ? 'assets/icons/cloak_glyph.svg' : 'assets/icons/zec_glyph.svg',
                  width: 28,
                  height: 28,
                  colorFilter: const ColorFilter.mode(Color(0xFFBDBDBD), BlendMode.srcIn),
                ),
              ),
            ),
          ),
          WidgetSpan(child: SizedBox(width: 6)),
          TextSpan(
            text: balHi,
            style: t.textTheme.displaySmall?.copyWith(
              color: const Color(0xFFBDBDBD),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(
            text: balLo,
            // CLOAK uses headlineSmall for decimals (bigger than titleMedium)
            // ZEC/YEC use titleMedium for the last 5 digits
            style: (isCloak ? t.textTheme.headlineSmall : t.textTheme.titleMedium)?.copyWith(
              color: const Color(0xFFBDBDBD),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ], style: t.textTheme.bodyMedium),
      );
      final ob = otherBalance;

      return GestureDetector(
        onTap: widget.onMode,
        child: Column(
          children: [
            ob > 0
                ? InputDecorator(
                    decoration: InputDecoration(
                        label: Text('+ ${amountToString2(ob)}'),
                        border: OutlineInputBorder(
                            borderSide: BorderSide(color: t.primaryColor),
                            borderRadius: BorderRadius.circular(8))),
                    child: balanceWidget)
                : balanceWidget,
            SizedBox(height: 12),
            // Show USD row even if price missing (indicate N/A)
            if (true)
              Builder(builder: (context) {
                final zashi = Theme.of(context).extension<ZashiThemeExt>();
                final balanceColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                final smallStyle = t.textTheme.bodyMedium?.copyWith(color: balanceColor);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      shouldHide
                          ? 'USD \u2013 \u2013 \u2013'
                          : _spaceFiat(txtBalFiat ?? 'USD N/A'),
                      style: smallStyle,
                    ),
                    const SizedBox(width: 12),
                    if (txtFiat != null)
                      Text('|', style: smallStyle),
                    if (txtFiat != null)
                      const SizedBox(width: 12),
                    Text(
                      txtFiat != null ? '1 ${c.ticker} = ${_spaceFiat(txtFiat)}' : '1 ${c.ticker} = N/A',
                      style: smallStyle,
                    ),
                  ],
                );
              }),
          ],
        ),
      );
    });
  }

  bool hide(bool flat) => false;

  int get balance {
    if (widget.balanceOverride != null) return widget.balanceOverride!;
    // Simple: total = transparent + sapling + orchard
    return aa.poolBalances.transparent + aa.poolBalances.sapling + aa.poolBalances.orchard;
  }

  int get totalBalance => balance;

  int get otherBalance => 0;
}
