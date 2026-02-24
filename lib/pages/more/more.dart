import 'dart:async';

import 'package:cloak_wallet/appsettings.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

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
    final isDesktop = !(Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 20),
              child: Text(
                'Settings',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 0.5,
                ),
              ),
            ),

            // Account section (hidden for view-only wallets)
            if (CloakWalletManager.isCloak(aa.coin) && !CloakWalletManager.isViewOnly)
              _MenuCard(
                icon: Icons.shield_outlined,
                iconColor: const Color(0xFF4CAF50),
                title: 'Auth Requests',
                subtitle: 'Review pending signature requests',
                onTap: () => _onNav(MoreTile(url: '/cloak_requests', icon: const SizedBox.shrink(), text: '')),
              ),

            if (CloakWalletManager.isCloak(aa.coin) && !CloakWalletManager.isViewOnly)
              const SizedBox(height: 10),

            // Backup section (hidden for view-only wallets)
            if (!CloakWalletManager.isViewOnly || !CloakWalletManager.isCloak(aa.coin))
              _MenuCard(
                icon: Icons.spa_outlined,
                iconColor: const Color(0xFF4CAF50),
                title: s.seedKeys,
                subtitle: 'View recovery phrase, keys, and tokens',
                onTap: () => _onNav(MoreTile(url: '/more/backup', icon: const SizedBox.shrink(), text: '', secured: true)),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'SECURED',
                    style: TextStyle(
                      color: const Color(0xFF4CAF50).withOpacity(0.8),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            if (!CloakWalletManager.isViewOnly || !CloakWalletManager.isCloak(aa.coin))
              const SizedBox(height: 10),

            // Sync section
            _MenuCard(
              icon: Icons.sync,
              iconColor: Colors.white.withOpacity(0.7),
              title: 'Resync Wallet',
              subtitle: 'Re-download all chain data from scratch',
              onTap: () => _onNav(MoreTile(url: '/more/resync', icon: const SizedBox.shrink(), text: '')),
            ),

            // Display section (desktop only)
            if (isDesktop) ...[
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Text(
                  'DISPLAY',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
              ),
              _ToggleCard(
                icon: Icons.push_pin_outlined,
                iconColor: Colors.white.withOpacity(0.7),
                title: 'Always On Top',
                subtitle: 'Keep window above other apps',
                value: alwaysOnTop.value,
                onChanged: (val) async {
                  await toggleAlwaysOnTop();
                  setState(() {});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onNav(MoreTile tile) async {
    final onPressed = tile.onPressed;
    if (onPressed != null) {
      await onPressed();
      return;
    }
    if (tile.secured) {
      final s = S.of(context);
      final auth = await authenticate(context, s.secured);
      if (!auth) return;
    }
    if (tile.url.startsWith('/account/')) {
      Navigator.of(context).pop();
      router.go(tile.url);
    } else {
      try {
        final res = await router.push(tile.url);
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

/// A single menu card with icon, title, subtitle, and optional trailing widget.
class _MenuCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _MenuCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF242424),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Icon(icon, color: iconColor, size: 20),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withOpacity(0.25),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A toggle card with switch (for display settings).
class _ToggleCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF242424),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Icon(icon, color: iconColor, size: 20),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeColor: const Color(0xFF4CAF50),
                  activeTrackColor: const Color(0xFF4CAF50).withOpacity(0.3),
                  inactiveThumbColor: Colors.white.withOpacity(0.5),
                  inactiveTrackColor: Colors.white.withOpacity(0.1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
