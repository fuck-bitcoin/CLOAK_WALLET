import 'dart:async';

import 'package:YWallet/appsettings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../accounts.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../router.dart' show router;
import '../../store2.dart';
import '../utils.dart';
import '../widgets.dart';

class MorePage extends StatefulWidget {
  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = coins[aa.coin];
    final moreSections = [
      MoreSection(title: Text(s.account), tiles: [
        MoreTile(
            url: '/messages',
            icon: FaIcon(FontAwesomeIcons.message),
            text: s.messages),
        MoreTile(
            url: '/contacts_overlay',
            icon: FaIcon(FontAwesomeIcons.addressBook),
            text: s.contacts),
        MoreTile(
            url: '/more/account_manager',
            icon: FaIcon(FontAwesomeIcons.users),
            text: s.accounts),
        MoreTile(
            url: '/more/coins',
            icon: FaIcon(FontAwesomeIcons.moneyBill),
            text: s.notes),
        MoreTile(
            url: '/more/transfer',
            icon: FaIcon(FontAwesomeIcons.personSwimming),
            text: s.pools),
        MoreTile(
            url: '/account/multi_pay',
            icon: FaIcon(FontAwesomeIcons.peopleArrows),
            text: s.multiPay,
            secured: appSettings.protectSend),
        if (c.supportsUA)
          MoreTile(
              url: '/account/swap',
              icon: FaIcon(FontAwesomeIcons.arrowRightArrowLeft),
              text: s.swap,
              secured: appSettings.protectSend),
        MoreTile(
            url: '/more/vote',
            icon: FaIcon(FontAwesomeIcons.personBooth),
            text: s.vote),
        // CLOAK auth requests (signature provider)
        if (CloakWalletManager.isCloak(aa.coin))
          MoreTile(
              url: '/cloak_requests',
              icon: FaIcon(FontAwesomeIcons.shieldHalved),
              text: 'Auth Requests'),
        // CLOAK shield assets from Telos
        if (CloakWalletManager.isCloak(aa.coin))
          MoreTile(
              url: '/shield',
              icon: FaIcon(FontAwesomeIcons.arrowRightToBracket),
              text: 'Shield Assets'),
      ]),
      MoreSection(title: Text(s.backup), tiles: [
        MoreTile(
            url: '/more/backup',
            icon: FaIcon(FontAwesomeIcons.seedling),
            text: s.seedKeys,
            secured: true),
        MoreTile(
            url: '/more/batch_backup',
            icon: FaIcon(FontAwesomeIcons.database),
            text: s.appData,
            secured: true),
      ]),
      MoreSection(title: Text(s.market), tiles: [
        MoreTile(
            url: '/more/budget',
            icon: FaIcon(FontAwesomeIcons.scaleBalanced),
            text: s.budget),
        MoreTile(
            url: '/more/market',
            icon: FaIcon(FontAwesomeIcons.arrowTrendUp),
            text: s.marketPrice),
      ]),
      MoreSection(title: Text(s.sync), tiles: [
        MoreTile(
            url: '/more/rescan',
            icon: FaIcon(FontAwesomeIcons.arrowRightLong),
            text: s.rescan),
        MoreTile(
            url: '/more/rewind',
            icon: FaIcon(FontAwesomeIcons.arrowRotateLeft),
            text: s.rewind),
        MoreTile(
            url: '/more/resync',
            icon: FaIcon(FontAwesomeIcons.arrowsRotate),
            text: 'Resync Wallet'),
      ]),
      MoreSection(title: Text(s.coldStorage), tiles: [
        MoreTile(
            url: '/more/cold/sign',
            icon: FaIcon(FontAwesomeIcons.signature),
            text: s.signOffline),
        MoreTile(
            url: '/more/cold/broadcast',
            icon: FaIcon(FontAwesomeIcons.towerBroadcast),
            text: s.broadcast),
      ]),
      MoreSection(
        title: Text(s.tools),
        tiles: [
          if (CloakWalletManager.isCloak(aa.coin))
            MoreTile(
                url: '/more/import_gui_wallet',
                icon: FaIcon(FontAwesomeIcons.fileImport),
                text: 'Import GUI Wallet'),
          if (aa.seed != null)
            MoreTile(
                url: '/more/keytool',
                icon: FaIcon(FontAwesomeIcons.key),
                text: s.keyTool,
                secured: true),
          MoreTile(
              url: '/more/sweep',
              icon: FaIcon(FontAwesomeIcons.broom),
              text: s.sweep),
          MoreTile(
              url: '/more/about',
              icon: FaIcon(FontAwesomeIcons.circleInfo),
              text: s.about,
              onPressed: () async {
                final contentTemplate =
                    await rootBundle.loadString('assets/about.md');
                router.push('/more/about', extra: contentTemplate);
              }),
        ],
      )
    ];

    final sections = moreSections
        .map((s) => SettingsSection(
            title: s.title,
            tiles: s.tiles
                .map((t) => SettingsTile.navigation(
                    leading: SizedBox(width: 32, child: t.icon),
                    onPressed: (context) => onNav(context, t),
                    title: Text(t.text)))
                .toList()))
        .toList();

    // Display toggles
    if (!(Theme.of(context).platform == TargetPlatform.android ||
          Theme.of(context).platform == TargetPlatform.iOS))
      sections.add(SettingsSection(
        title: Text('Display'),
        tiles: [
          SettingsTile.switchTile(
            leading: SizedBox(width: 32, child: FaIcon(FontAwesomeIcons.thumbtack)),
            title: Text('Always On Top'),
            initialValue: alwaysOnTop.value,
            onToggle: (val) async {
              await toggleAlwaysOnTop();
              setState(() {});
            },
          ),
        ],
      ));

    return SettingsList(sections: sections);
  }

  onNav(BuildContext _, MoreTile tile) async {
    print('[MorePage] onNav START: url=${tile.url}');
    final onPressed = tile.onPressed;
    if (onPressed != null) {
      print('[MorePage] has custom onPressed, calling it');
      await onPressed();
      return;
    }
    if (tile.secured) {
      print('[MorePage] tile is secured, authenticating');
      final s = S.of(context);
      final auth = await authenticate(context, s.secured);
      if (!auth) return;
    }
    if (tile.url.startsWith('/account/')) {
      print('[MorePage] account route, pop + go');
      Navigator.of(context).pop();
      router.go(tile.url);
    } else {
      print('[MorePage] pushing ${tile.url}');
      try {
        final res = await router.push(tile.url);
        print('[MorePage] push returned: $res');
        if (tile.url == '/more/account_manager' && res != null)
          Timer(Durations.short1, () {
            router.go('/account');
          });
      } catch (e, st) {
        print('[MorePage] ERROR pushing ${tile.url}: $e\n$st');
      }
    }
  }
}
