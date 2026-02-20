import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// First-launch splash page shown when no wallet exists.
/// Displays CLOAK logo and Create / Restore buttons.
class CloakSplashPage extends StatelessWidget {
  const CloakSplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 3),
                Image.asset('assets/cloak_logo.png', height: 120),
                const SizedBox(height: 24),
                Text(
                  'CLOAK',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Private by default',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 14,
                  ),
                ),
                const Spacer(flex: 4),
                // Create New Wallet button (primary)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: Material(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => GoRouter.of(context).push('/splash/create'),
                      child: const Center(
                        child: Text(
                          'Create New Wallet',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Restore from Seed button (secondary)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: Material(
                    color: const Color(0xFF2E2C2C),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => GoRouter.of(context).push('/splash/restore'),
                      child: Center(
                        child: Text(
                          'Restore from Seed',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
