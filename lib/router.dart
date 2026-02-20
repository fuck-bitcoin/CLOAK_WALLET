import 'dart:convert';
import 'dart:io';

import 'package:showcaseview/showcaseview.dart';
import 'settings.pb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'accounts.dart';
import 'cloak/cloak_types.dart';
import 'cloak/cloak_wallet_manager.dart';
import 'cloak/cloak_db.dart';
import 'coin/coins.dart';
import 'generated/intl/messages.dart';
import 'pages/accounts/manager.dart';
import 'pages/accounts/new_import.dart';
import 'pages/accounts/send.dart';
import 'pages/more/resync_wallet.dart';
import 'pages/accounts/submit.dart';
import 'pages/accounts/cloak_confirm.dart';
import 'pages/accounts/cloak_submit.dart';
import 'pages/dblogin.dart';
import 'pages/encrypt.dart';
import 'pages/main/home.dart';
import 'pages/more/about.dart';
import 'pages/more/backup.dart';
import 'pages/more/coin.dart';
import 'pages/more/contacts.dart';
import 'pages/more/import_gui_wallet.dart';
import 'pages/more/more.dart';
import 'pages/tx.dart';
import 'pages/scan.dart';
import 'pages/blank.dart';
import 'pages/showqr.dart';
import 'pages/splash.dart';
import 'pages/welcome.dart';
import 'pages/settings.dart';
import 'pages/messages.dart';
import 'pages/messages_compose.dart';
import 'pages/utils.dart';
import 'pages/request.dart';
import 'store2.dart';
import 'theme/zashi_tokens.dart';
import 'pages/main/receive_qr.dart';
import 'appsettings.dart';
import 'pages/cloak/pending_requests.dart';
import 'pages/cloak/request_approval.dart';
import 'pages/cloak/shield_page.dart';
import 'cloak/signature_provider_state.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final _accountNavigatorKey = GlobalKey<NavigatorState>();

// Allow overriding the initial route (e.g., for design reviews) via env var.
// Example: YW_INITIAL_ROUTE="/debug/sending"
final _initialLocation = Platform.environment['YW_INITIAL_ROUTE'] ?? '/account';

final helpRouteMap = {
  "/account": "/accounts",
  "/messages": "/messages",
  "/history": "/history",
  "contacts": "/contacts",
};

final router = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: _initialLocation,
  debugLogDiagnostics: true,
  routes: [
    GoRoute(path: '/', redirect: (context, state) => '/account'),
    // Messages as a top-level overlay route (slides over root AppBar without affecting layout)
    GoRoute(
      path: '/messages',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () async {
                try {
                  // Prefer pop to get reverse slide transition when a prior page exists
                  if (Navigator.of(context).canPop()) {
                    GoRouter.of(context).pop();
                  } else {
                    GoRouter.of(context).go('/account');
                  }
                } catch (_) {
                  try { GoRouter.of(context).go('/account'); } catch (_) {}
                }
              },
              icon: Icon(Icons.arrow_back),
            ),
            title: Builder(builder: (context) {
              final t = Theme.of(context);
              final base = t.appBarTheme.titleTextStyle ??
                  t.textTheme.titleLarge ??
                  t.textTheme.titleMedium ??
                  t.textTheme.bodyMedium;
              final reduced = (base?.fontSize != null)
                  ? base!.copyWith(fontSize: base.fontSize! * 0.75)
                  : base;
              return Text(S.of(context).messages.toUpperCase(), style: reduced);
            }),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'New Message',
                icon: const Icon(Icons.edit),
                onPressed: () => GoRouter.of(context).push('/messages/compose'),
              ),
            ],
          ),
          body: MessagePage(),
        ),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
      routes: [
        GoRoute(
          path: 'details',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: (() {
              final extra = state.extra;
              // Prefer CID parameter (stable) over index (dynamic)
              final cid = state.uri.queryParameters['cid'];
              final idxStr = state.uri.queryParameters['index'];
              final idx = idxStr != null ? int.tryParse(idxStr) : null;
              if (extra is MessageThread) {
                return MessageItemPage(idx ?? 0, initialThread: extra);
              }
              // Use CID if provided, otherwise fall back to index
              return MessageItemPage(idx ?? 0, cid: cid);
            })(),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final slide = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: slide, child: child));
            },
          ),
        ),
        GoRoute(
          path: 'compose',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const ComposeMessagePanel(),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final slide = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: slide, child: child));
            },
          ),
        ),
      ],
    ),
    // CLOAK Signature Provider routes
    GoRoute(
      path: '/cloak_requests',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const PendingRequestsPage(),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
    ),
    GoRoute(
      path: '/cloak_requests/:id',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) {
        final id = Uri.decodeComponent(state.pathParameters['id'] ?? '');
        return CustomTransitionPage(
          key: state.pageKey,
          child: RequestApprovalPage(requestId: id),
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
            final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
            return RepaintBoundary(child: SlideTransition(position: offset, child: child));
          },
        );
      },
    ),
    // CLOAK Shield Assets from Telos route
    GoRoute(
      path: '/shield',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ShieldPage(),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
    ),
    // Contacts as a top-level overlay route (slides over root AppBar, no AppBar inside)
    GoRoute(
      path: '/contacts_overlay',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: ContactsPage(main: true, showAppBar: false),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
      routes: [
        GoRoute(
          path: 'pick',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: ContactsPage(main: false, showAppBar: false),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: offset, child: child));
            },
          ),
        ),
        GoRoute(
          path: 'add',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: ContactAddPage(
              showAppBar: false,
              initialAddress: state.extra as String?,
            ),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: offset, child: child));
            },
          ),
        ),
        GoRoute(
          path: 'edit',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: ContactEditPage(
              int.parse(state.uri.queryParameters['id']!),
              showAppBar: false,
            ),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: offset, child: child));
            },
          ),
        ),
        GoRoute(
          path: 'display_name',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const DisplayNameEditPage(showAppBar: false),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: offset, child: child));
            },
          ),
        ),
        GoRoute(
          path: 'submit_tx',
          builder: (context, state) =>
              SubmitTxPage(txPlan: state.extra as String),
        ),
      ],
    ),
    // Activity as a top-level overlay route (slides over root, covers bottom nav)
    GoRoute(
      path: '/activity_overlay',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: TxPage(showAppBar: false),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => ScaffoldBar(shell: shell),
      branches: [
        StatefulShellBranch(
          navigatorKey: _accountNavigatorKey,
          routes: [
            GoRoute(
              path: '/account',
              builder: (context, state) => HomePage(),
              redirect: (context, state) {
                if (aa.id == 0) return '/welcome';
                return null;
              },
              routes: [
                GoRoute(
                  path: 'cloak_confirm',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) => CustomTransitionPage(
                    key: state.pageKey,
                    child: CloakConfirmPage(),
                    transitionDuration: const Duration(milliseconds: 300),
                    reverseTransitionDuration: const Duration(milliseconds: 300),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                      final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                      return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                    },
                  ),
                ),
                GoRoute(
                  path: 'cloak_submit',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) => CustomTransitionPage(
                    key: state.pageKey,
                    child: CloakSubmitPage(),
                    transitionDuration: const Duration(milliseconds: 300),
                    reverseTransitionDuration: const Duration(milliseconds: 300),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                      final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                      return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                    },
                  ),
                ),
                GoRoute(
                  path: 'quick_send',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) {
                    bool custom = state.uri.queryParameters['custom'] == '1';
                    return CustomTransitionPage(
                      key: state.pageKey,
                      child: QuickSendPage(
                        custom: custom,
                        single: true,
                        sendContext: state.extra as SendContext?,
                      ),
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration: const Duration(milliseconds: 300),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                        final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                        return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                      },
                    );
                  },
                  routes: [
                    GoRoute(
                      path: 'contacts',
                      pageBuilder: (context, state) => CustomTransitionPage(
                        key: state.pageKey,
                        child: ContactsPage(main: false, showAppBar: false),
                        transitionDuration: const Duration(milliseconds: 300),
                        reverseTransitionDuration: const Duration(milliseconds: 300),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                        },
                      ),
                    ),
                    GoRoute(
                      path: 'accounts',
                      builder: (context, state) =>
                          AccountManagerPage(main: false),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'request',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) {
                    int? initialMode;
                    try {
                      final modeParam = state.uri.queryParameters['mode'];
                      if (modeParam != null) initialMode = int.tryParse(modeParam);
                    } catch (_) {}
                    // Accept thread context from extra if present
                    Map<String, dynamic>? threadContext;
                    if (state.extra != null && state.extra is Map) {
                      threadContext = state.extra as Map<String, dynamic>;
                    }
                    return CustomTransitionPage(
                      key: state.pageKey,
                      child: RequestPage(initialAddressMode: initialMode, threadContext: threadContext),
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration: const Duration(milliseconds: 300),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                        final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                        return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                      },
                    );
                  },
                ),
                GoRoute(
                  path: 'receive',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) => CustomTransitionPage(
                    key: state.pageKey,
                    child: const ReceiveQrPage(),
                    transitionDuration: const Duration(milliseconds: 300),
                    reverseTransitionDuration: const Duration(milliseconds: 300),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
                      final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
                      return RepaintBoundary(child: SlideTransition(position: offset, child: child));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            // Keep a no-op anchor route so the branch has a derivable default location
            GoRoute(
              path: '/messages_anchor',
              builder: (context, state) => BlankPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
                path: '/blank',
                builder: (context, state) => BlankPage(),
                routes: [
                  GoRoute(
                    path: 'history',
                    builder: (context, state) => TxPage(),
                    routes: [
                      GoRoute(
                        path: 'details',
                        builder: (context, state) => TransactionPage(
                            int.parse(state.uri.queryParameters["index"]!)),
                      ),
                      GoRoute(
                        path: 'details/byid',
                        builder: (context, state) => TransactionByIdPage(
                          int.parse(state.uri.queryParameters["tx"]!),
                          from: state.uri.queryParameters['from'],
                          threadIndex: state.uri.queryParameters['thread']?.let(int.parse),
                        ),
                      ),
                    ],
                  ),
                ]),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
                path: '/contacts',
                pageBuilder: (context, state) => CustomTransitionPage(
                      key: state.pageKey,
                      child: ContactsPage(main: true, showAppBar: false),
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration:
                          const Duration(milliseconds: 300),
                      transitionsBuilder: (context, animation,
                          secondaryAnimation, child) {
                        final curved = CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                            reverseCurve: Curves.easeInCubic);
                        final offset = Tween<Offset>(
                                begin: const Offset(1.0, 0.0),
                                end: Offset.zero)
                            .animate(curved);
                        return RepaintBoundary(child: SlideTransition(
                            position: offset, child: child));
                      },
                    ),
                routes: [
                  GoRoute(
                    path: 'add',
                    builder: (context, state) => ContactAddPage(initialAddress: state.extra as String?),
                  ),
                  GoRoute(
                    path: 'edit',
                    builder: (context, state) => ContactEditPage(
                        int.parse(state.uri.queryParameters['id']!)),
                  ),
                  GoRoute(
                    path: 'submit_tx',
                    builder: (context, state) =>
                        SubmitTxPage(txPlan: state.extra as String),
                  ),
                  GoRoute(
                    path: 'display_name',
                    builder: (context, state) => const DisplayNameEditPage(showAppBar: true, showPromptOnOpen: true),
                  ),
                ]),
          ],
        ),
      ],
    ),
    // More page as full-screen overlay (slides in from right, covers AppBar)
    GoRoute(
      path: '/more',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () {
                try {
                  if (Navigator.of(context).canPop()) {
                    GoRouter.of(context).pop();
                  } else {
                    GoRouter.of(context).go('/account');
                  }
                } catch (_) {
                  try { GoRouter.of(context).go('/account'); } catch (_) {}
                }
              },
              icon: const Icon(Icons.arrow_back),
            ),
            title: Builder(builder: (context) {
              final t = Theme.of(context);
              final base = t.appBarTheme.titleTextStyle ??
                  t.textTheme.titleLarge ??
                  t.textTheme.titleMedium ??
                  t.textTheme.bodyMedium;
              final reduced = (base?.fontSize != null)
                  ? base!.copyWith(fontSize: base.fontSize! * 0.75)
                  : base;
              return Text(S.of(context).more.toUpperCase(), style: reduced);
            }),
            centerTitle: true,
          ),
          body: MorePage(),
        ),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
      routes: [
        GoRoute(
            path: 'account_manager',
            builder: (context, state) =>
                AccountManagerPage(main: true),
            routes: [
              GoRoute(
                  path: 'new',
                  builder: (context, state) => NewImportAccountPage(
                      first: false,
                      seedInfo: state.extra as SeedInfo?)),
            ]),
        GoRoute(
          path: 'coins',
          builder: (context, state) => CoinControlPage(),
        ),
        GoRoute(
          path: 'backup',
          builder: (context, state) => BackupPage(),
        ),
        GoRoute(
          path: 'resync',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: ResyncWalletPage(),
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
              final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
              return RepaintBoundary(child: SlideTransition(position: offset, child: child));
            },
          ),
        ),
        GoRoute(
            path: 'about',
            builder: (context, state) =>
                AboutPage(state.extra as String)),
        GoRoute(
          path: 'import_gui_wallet',
          builder: (context, state) =>
              const ImportGuiWalletPage(),
        ),
        GoRoute(
          path: 'submit_tx',
          builder: (context, state) =>
              SubmitTxPage(txPlan: state.extra as String),
        ),
      ],
    ),
    // Debug-only route to display the "Sending Transaction" page without broadcasting.
    // Useful for design review: shows spinner state indefinitely.
    GoRoute(
      path: '/debug/sending',
      builder: (context, state) => SubmitTxPage(),
    ),
    GoRoute(
      path: '/debug/sent',
      builder: (context, state) => SubmitTxPage(fakeTxId: state.uri.queryParameters['txid'] ?? 'FAKE-TXID-DEADBEEF-1234'),
    ),
    GoRoute(path: '/decrypt_db', builder: (context, state) => DbLoginPage()),
    GoRoute(path: '/disclaimer', builder: (context, state) => DisclaimerPage()),
    GoRoute(
      path: '/splash',
      builder: (context, state) => SplashPage(),
      redirect: (context, state) {
        final c = coins.first;
        if (isMobile()) return null; // db encryption is only for desktop
        if (!File(c.dbFullPath).existsSync()) return null; // fresh install
        return null; // CLOAK doesn't use encrypted DB files
      },
    ),
    GoRoute(
      path: '/welcome',
      builder: (context, state) => WelcomePage(),
    ),
    GoRoute(
      path: '/first_account',
      builder: (context, state) => NewImportAccountPage(first: true),
    ),
    GoRoute(
      path: '/settings',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        final coin =
            state.uri.queryParameters['coin']?.let(int.parse) ?? aa.coin;
        return SettingsPage(coin: coin);
      },
    ),
    GoRoute(
      path: '/quick_send_settings',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) =>
          QuickSendSettingsPage(state.extra as CustomSendSettings),
    ),
    GoRoute(
      path: '/encrypt_db',
      builder: (context, state) => EncryptDbPage(),
    ),
    GoRoute(
      path: '/scan',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: ScanQRCodePage(state.extra as ScanQRContext),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
    ),
    GoRoute(
      path: '/showqr',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: ShowQRPage(
          title: state.uri.queryParameters['title']!,
          text: state.extra as String,
        ),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final offset = Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(curved);
          return RepaintBoundary(child: SlideTransition(position: offset, child: child));
        },
      ),
    ),
  ],
);


/// Coin logo for the account switcher — CLOAK uses a local PNG, Zcash uses the Z SVG.
/// Black circle background blends with the logo's black edges, preventing visible clipping.
Widget _coinLogo(int coin, double size) {
  if (CloakWalletManager.isCloak(coin)) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 4,
            spreadRadius: 0.5,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/cloak_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
  return SizedBox(
    width: size,
    height: size,
    child: Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF4B728),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
          ),
        ),
        Positioned.fill(
          child: ClipOval(
            child: Transform.scale(
              scale: 1.40,
              child: SvgPicture.network(
                'https://z.cash/wp-content/uploads/2023/11/Secondary-Brandmark-Black.svg',
                fit: BoxFit.contain,
                semanticsLabel: 'Zcash brandmark',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class ScaffoldBar extends StatefulWidget {
  final StatefulNavigationShell shell;

  const ScaffoldBar({required this.shell, Key? key});

  @override
  State<ScaffoldBar> createState() => _ScaffoldBar();
}

class _ScaffoldBar extends State<ScaffoldBar> with TickerProviderStateMixin {
  late final AnimationController _refreshController;
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _refreshController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _refreshController.dispose();
    _blinkController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final router = GoRouter.of(context);
    final RouteMatch lastMatch =
        router.routerDelegate.currentConfiguration.last;
    final RouteMatchList matchList = lastMatch is ImperativeRouteMatch
        ? lastMatch.matches
        : router.routerDelegate.currentConfiguration;
    final String location = matchList.uri.toString();
    final bool isQuickSend = location.startsWith('/account/quick_send');
    final bool isTxPlan = location.startsWith('/account/txplan');
    final bool isSubmitTx = location.startsWith('/account/submit_tx') ||
        location.startsWith('/account/broadcast_tx');
    final bool isCloakConfirm = location.startsWith('/account/cloak_confirm');
    final bool isCloakSubmit = location.startsWith('/account/cloak_submit');
    final bool isMessages = location.startsWith('/messages');
    final bool isMessagesDetails = location.startsWith('/messages/details');

    return PopScope(
        canPop: location == '/account',
        onPopInvoked: _onPop,
        child: Scaffold(
          // Bottom nav bar removed — all nav via quick actions + More page
          // Keep AppBar mounted during Messages so it doesn't disappear before overlay slides in
          appBar: (isTxPlan || isSubmitTx || isCloakConfirm || isCloakSubmit)
              ? null
              : AppBar(
            title: Observer(builder: (context) {
              try {
                aaSequence.seqno;
                final t = Theme.of(context);
                final zashi = t.extension<ZashiThemeExt>();
                final color = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                final base = t.textTheme.bodyMedium ?? t.textTheme.titleMedium ?? t.textTheme.bodySmall;
                final sized = (base?.fontSize != null)
                    ? base!.copyWith(fontSize: base.fontSize! * 1.15, fontWeight: FontWeight.w700)
                    : (base ?? const TextStyle(fontWeight: FontWeight.w700));
                final style = sized.copyWith(color: color);
                final fs = style.fontSize ?? 16.0;
                // Always show account name; Send overlay covers this smoothly
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    splashColor: t.colorScheme.onSurface.withOpacity(0.08),
                    highlightColor: t.colorScheme.onSurface.withOpacity(0.06),
                    onTap: _openAccountSwitcher,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _coinLogo(aa.coin, 25),
                          const SizedBox(width: 8),
                          RichText(
                            text: TextSpan(
                              style: style,
                              children: [
                                TextSpan(text: isVaultMode ? (activeVaultLabel ?? 'Vault') : aa.name),
                                const WidgetSpan(child: SizedBox(width: 3)),
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Icon(Icons.expand_more, color: color, size: fs * 1.25),
                                ),
                              ],
                            ),
                          ),
                          
                        ],
                      ),
                    ),
                  ),
                );
              } catch (e, st) {
                debugPrint('Observer build error (router title): $e\n$st');
                rethrow;
              }
            }),
            centerTitle: false,
            actions: [
              // Sync indicator should appear to the left of the eyeball
              // Shows rotating icon during periodic syncs (not the orange banner)
              Observer(builder: (context) {
                try {
                  // Coin-aware: only show sync icon if the syncing coin matches the active coin
                  // This prevents Zcash background sync from showing when user is on CLOAK
                  final isSyncingThisCoin = syncStatus2.syncing &&
                      (syncStatus2.syncingCoin == null || syncStatus2.syncingCoin == aa.coin);

                  if (isSyncingThisCoin) {
                    if (!_refreshController.isAnimating) {
                      _refreshController.repeat();
                    }
                    if (!_blinkController.isAnimating) {
                      _blinkController.repeat(reverse: true);
                    }
                  } else {
                    if (_refreshController.isAnimating) {
                      _refreshController.stop();
                    }
                    _refreshController.value = 0;
                    if (_blinkController.isAnimating) {
                      _blinkController.stop();
                    }
                    _blinkController.value = 0;
                  }

                  final t = Theme.of(context);
                  final appBarBg =
                      t.appBarTheme.backgroundColor ?? t.colorScheme.surface;
                  final baseGrey = Colors.grey.shade400;
                  final colorAnim = ColorTween(begin: baseGrey, end: appBarBg)
                      .animate(CurvedAnimation(
                          parent: _blinkController, curve: Curves.easeInOut));

                  if (!isSyncingThisCoin) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: AnimatedBuilder(
                      animation: _blinkController,
                      builder: (context, child) => RotationTransition(
                        turns: _refreshController,
                        child: Icon(Icons.sync, color: colorAnim.value),
                      ),
                    ),
                  );
                } catch (e, st) {
                  debugPrint('Observer build error (router sync icon): $e\n$st');
                  rethrow;
                }
              }),
              // Eyeball toggle (hide/show balances)
              Observer(builder: (context) {
                try {
                  final hidden = appStore.hideBalances;
                  return IconButton(
                    tooltip: hidden ? 'Show balances' : 'Hide balances',
                    onPressed: () => appStore.setHideBalances(!hidden),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) => child,
                      child: Icon(
                        hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        key: ValueKey<bool>(hidden),
                      ),
                    ),
                  );
                } catch (e, st) {
                  debugPrint('Observer build error (router hide-balance): $e\n$st');
                  rethrow;
                }
              }),
              IconButton(onPressed: help, icon: Icon(Icons.help)),
              IconButton(onPressed: settings, icon: Icon(Icons.settings)),
            ],
          ),
          body: ShowCaseWidget(builder: (context) => widget.shell),
        ));
  }

  help() {
    launchUrl(Uri.https('ywallet.app'));
  }

  settings() {
    GoRouter.of(context).push('/settings');
  }

  _onRefresh() {}

  _onPop(bool didPop) {
    router.go('/account');
  }

  Future<void> _openAccountSwitcher() async {
    final ThemeData t = Theme.of(context);
    final List<CloakAccount> accounts = getAllAccounts();
    final int selectedIndex = accounts.indexWhere((a) => a.coin == aa.coin && a.id == aa.id);

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Accounts',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogCtx, anim, secAnim) {
        return _TopAccountSheet(
          theme: t,
          accounts: accounts,
          selectedIndex: selectedIndex,
          parentContext: context,
        );
      },
      transitionBuilder: (ctx, anim, secAnim, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        final slide = Tween<Offset>(begin: const Offset(0, -1.0), end: Offset.zero).animate(curved);
        final fade = CurvedAnimation(parent: anim, curve: const Interval(0.15, 1.0, curve: Curves.easeOutCubic));
        return SlideTransition(
          position: slide,
          child: FadeTransition(opacity: fade, child: child),
        );
      },
    );
  }
}

class _TopAccountSheet extends StatefulWidget {
  final ThemeData theme;
  final List<CloakAccount> accounts;
  final int selectedIndex;
  final BuildContext parentContext;
  const _TopAccountSheet({required this.theme, required this.accounts, required this.selectedIndex, required this.parentContext});
  @override
  State<_TopAccountSheet> createState() => _TopAccountSheetState();
}

class _TopAccountSheetState extends State<_TopAccountSheet> with SingleTickerProviderStateMixin {
  double _dragOffset = 0.0;
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  Animation<double>? _bounce;
  bool _showNewAccountMenu = false;
  bool _showNewVault = false;
  final Set<int> _actionIndices = {};
  late List<CloakAccount> _accounts;
  int? _editingIndex;
  final TextEditingController _editNameController = TextEditingController();
  final FocusNode _editFocusNode = FocusNode();

  // Imported vaults
  List<Map<String, dynamic>> _vaults = [];
  Map<String, String> _vaultBalances = {}; // commitment_hash -> balance string
  final Set<int> _vaultActionIndices = {}; // Which vaults have action icons showing
  int? _burnConfirmVaultIndex; // Which vault is in burn-confirm mode (fire icon)
  int? _activeBurnVaultIndex; // Which vault is actually undergoing burn (loading panel)

  // Burn fee check (async, queries chain on trash tap)
  bool _burnFeeChecking = false;   // true while querying chain for burn fee
  bool _burnFeeInsufficient = false; // true if balance < burn fee
  double _burnFeeAmount = 0.0;     // cached burn fee from chain query

  // Burn loading flow (mirrors _NewVaultInline pattern)
  bool _burnInProgress = false;
  bool _burnShowSpinner = false;
  String _burnStatusMessage = '';
  String? _fadingVaultHash; // Vault currently fading out after burn/remove

  @override
  void initState() {
    super.initState();
    _accounts = List<CloakAccount>.from(widget.accounts);
    // Ensure persisted order is applied when the sheet opens
    // (async post-frame to avoid setState during build)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshAccounts();
        _loadVaults();
      }
    });
  }

  Future<void> _loadVaults() async {
    final vaults = await CloakWalletManager.getImportedVaults();
    if (!mounted) return;
    setState(() => _vaults = vaults);
    for (final vault in vaults) {
      final hash = vault['commitment_hash'] as String?;
      if (hash != null) {
        _fetchVaultBalance(hash);
      }
    }
  }

  Future<void> _fetchVaultBalance(String commitmentHash) async {
    try {
      final balance = await CloakWalletManager.queryVaultBalance(commitmentHash);
      if (!mounted) return;
      setState(() => _vaultBalances[commitmentHash] = balance ?? '0 CLOAK');
    } catch (_) {}
  }

  Widget _buildVaultsHeader(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 14, color: const Color(0xFF4CAF50)),
                const SizedBox(width: 6),
                Text(
                  'VAULTS',
                  style: TextStyle(
                    color: const Color(0xFF4CAF50),
                    fontFamily: balanceFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVaultCard(BuildContext context, Map<String, dynamic> vault, int vaultIndex) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final vaultId = vault['id'] as int?;
    final label = vault['label'] as String? ?? 'Vault';
    final commitmentHash = vault['commitment_hash'] as String? ?? '';
    final balance = _vaultBalances[commitmentHash] ?? 'Loading...';
    final hashPreview = commitmentHash.length > 16
        ? '${commitmentHash.substring(0, 8)}...${commitmentHash.substring(commitmentHash.length - 8)}'
        : commitmentHash;
    final bool showActions = _vaultActionIndices.contains(vaultIndex);
    // Highlight when this vault is the active vault
    final bool isSelected = isVaultMode && activeVaultHash == commitmentHash;

    final vaultBalStr = _vaultBalances[commitmentHash] ?? '0 CLOAK';
    final vaultHasAssets = !vaultBalStr.startsWith('0 ') && !vaultBalStr.startsWith('0.0000 ') && vaultBalStr != '0 CLOAK';
    final vaultStatus = vault['status'] as String? ?? '';
    final vaultNeverPublished = vaultStatus == 'created';
    // Burn fee check results are in state (_burnFeeChecking, _burnFeeInsufficient, _burnFeeAmount)
    // — populated async when trash icon is tapped, via chain query
    final bool insufficientBalance = _burnConfirmVaultIndex == vaultIndex && _burnFeeInsufficient;

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      clipBehavior: Clip.antiAlias,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF4CAF50).withOpacity(0.28)
              : const Color(0xFF4CAF50).withOpacity(0.12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF4CAF50).withOpacity(0.7)
                : const Color(0xFF4CAF50).withOpacity(0.3),
            width: isSelected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(15),
        ),
        child: (_burnInProgress && _activeBurnVaultIndex == vaultIndex)
          // Burn loading panel — mirrors _NewVaultInline pattern
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedOpacity(
                    opacity: _burnShowSpinner ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 350),
                    child: const SizedBox(
                      width: 32, height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _burnStatusMessage.isNotEmpty ? _burnStatusMessage : 'Burning vault...',
                    style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                      color: balanceTextColor,
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Please wait, this won\'t take long',
                    style: TextStyle(
                      color: balanceTextColor.withOpacity(0.5),
                      fontFamily: balanceFontFamily,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              leading: Container(
                width: 35,
                height: 35,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF4CAF50),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Center(
                  child: Icon(Icons.lock, color: Colors.white, size: 18),
                ),
              ),
              title: Text(
                label,
                style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                  color: balanceTextColor,
                  fontFamily: balanceFontFamily,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(
                    hashPreview,
                    style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                      color: balanceTextColor.withOpacity(0.6),
                      fontFamily: balanceFontFamily,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    balance,
                    style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                      color: const Color(0xFF4CAF50),
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
          trailing: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            child: showActions
                ? Row(
                    key: ValueKey('vault-actions-$vaultIndex'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Builder(builder: (ctx) {
                        final isBurnConfirm = _burnConfirmVaultIndex == vaultIndex;
                        final bool burnBlocked = isBurnConfirm && (_burnInProgress || _fadingVaultHash != null || _burnFeeChecking || insufficientBalance);
                        return _ActionChip(
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            switchInCurve: Curves.easeOut,
                            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                            child: Icon(
                              isBurnConfirm ? Icons.local_fire_department : Icons.delete,
                              key: ValueKey('$isBurnConfirm-$burnBlocked'),
                              color: burnBlocked
                                  ? Colors.grey
                                  : (isBurnConfirm ? Colors.orange : Colors.red),
                              size: 20,
                            ),
                          ),
                          onTap: () async {
                            if (!isBurnConfirm) {
                              // First tap: show fire icon + burn message
                              // Trigger async balance check against on-chain fee
                              setState(() {
                                _burnConfirmVaultIndex = vaultIndex;
                                _burnFeeChecking = !vaultNeverPublished;
                                _burnFeeInsufficient = false;
                                _burnFeeAmount = 0.0;
                              });
                              if (!vaultNeverPublished) {
                                // Query chain + Rust estimator for accurate burn fee
                                try {
                                  final feeStr = await CloakWalletManager.getBurnFee(hasAssets: vaultHasAssets);
                                  final fee = double.tryParse(feeStr.split(' ').first);
                                  if (fee == null) throw Exception('Could not parse fee: $feeStr');
                                  double cloakBal = 0.0;
                                  final balJson = CloakWalletManager.getBalancesJson();
                                  if (balJson != null) {
                                    try {
                                      final bals = jsonDecode(balJson) as List;
                                      for (final b in bals) {
                                        if (b is String && b.endsWith('CLOAK@thezeostoken')) {
                                          cloakBal = double.tryParse(b.split('@')[0].replaceAll('CLOAK', '').trim()) ?? 0.0;
                                          break;
                                        }
                                      }
                                    } catch (_) {}
                                  }
                                  if (mounted) setState(() {
                                    _burnFeeChecking = false;
                                    _burnFeeAmount = fee;
                                    _burnFeeInsufficient = cloakBal < fee;
                                  });
                                } catch (e) {
                                  print('[BURN] Fee estimation failed: $e');
                                  if (mounted) setState(() {
                                    _burnFeeChecking = false;
                                    _burnFeeAmount = -1.0; // Signal estimation failure
                                    _burnFeeInsufficient = true; // Block burn — can't verify balance
                                  });
                                }
                              }
                              return;
                            }
                            // Block if another vault burn is in progress or fee check incomplete
                            if (burnBlocked) return;
                            // Second tap: execute burn with loading feedback
                            final balStr = _vaultBalances[commitmentHash] ?? '0 CLOAK';
                            final hasAssets = !balStr.startsWith('0 ') && !balStr.startsWith('0.0000 ') && balStr != '0 CLOAK';
                            final vaultStatus = vault['status'] as String? ?? '';

                            // Show loading panel immediately (text-only, spinner deferred)
                            setState(() {
                              _burnInProgress = true;
                              _activeBurnVaultIndex = vaultIndex;
                              _burnShowSpinner = false;
                              _burnStatusMessage = 'Checking vault status...';
                            });
                            await WidgetsBinding.instance.endOfFrame;

                            // Check if this vault was actually published on-chain
                            bool wasPublished = vaultStatus != 'created';
                            if (!wasPublished) {
                              final storedHash = await CloakWalletManager.getStoredVaultHash();
                              if (storedHash == commitmentHash && await CloakWalletManager.isVaultPublished()) {
                                wasPublished = true;
                              }
                            }

                            // Vault never published — nothing on-chain, just delete locally
                            if (!wasPublished) {
                              try {
                                if (mounted) setState(() => _burnStatusMessage = 'Removing vault...');
                                if (commitmentHash.isNotEmpty) {
                                  await CloakWalletManager.updateVaultStatus(commitmentHash, 'burned');
                                }
                                if (vaultId != null) {
                                  await CloakWalletManager.deleteImportedVault(vaultId, commitmentHash: commitmentHash);
                                }
                                if (isVaultMode && activeVaultHash == commitmentHash) {
                                  setActiveAccount(CLOAK_COIN, 1);
                                }
                                if (mounted) setState(() => _burnStatusMessage = 'Vault removed!');
                                await Future.delayed(const Duration(milliseconds: 500));
                                // Start fade-out animation (keep burn panel visible during fade)
                                if (mounted) setState(() {
                                  _fadingVaultHash = commitmentHash;
                                  _vaultActionIndices.remove(vaultIndex);
                                });
                                // Vault removal happens in TweenAnimationBuilder onEnd
                              } catch (e) {
                                if (mounted) setState(() {
                                  _burnInProgress = false;
                                  _activeBurnVaultIndex = null;
                                  _burnShowSpinner = false;
                                  _burnStatusMessage = '';
                                });
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('Delete failed: $e')),
                                );
                              }
                              return;
                            }

                            // Auth token is on-chain — need authenticate burn=1 to nullify
                            // Use the fee already fetched from chain on trash tap
                            final minBalance = _burnFeeAmount > 0 ? _burnFeeAmount : double.infinity;
                            double cloakBalance = 0.0;
                            final balJson = CloakWalletManager.getBalancesJson();
                            if (balJson != null) {
                              try {
                                final balances = jsonDecode(balJson) as List;
                                for (final b in balances) {
                                  if (b is String && b.endsWith('CLOAK@thezeostoken')) {
                                    cloakBalance = double.tryParse(b.split('@')[0].replaceAll('CLOAK', '').trim()) ?? 0.0;
                                    break;
                                  }
                                }
                              } catch (_) {}
                            }
                            if (cloakBalance < minBalance) {
                              if (mounted) setState(() {
                                _burnInProgress = false;
                                _activeBurnVaultIndex = null;
                                _burnShowSpinner = false;
                                _burnStatusMessage = '';
                              });
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text(minBalance == double.infinity
                                    ? 'Could not estimate burn fee — please try again'
                                    : 'Insufficient CLOAK to burn vault (need ~${minBalance.toStringAsFixed(2)})')),
                              );
                              return;
                            }

                            final recipientAddress = CloakWalletManager.getDefaultAddress() ?? '';
                            if (recipientAddress.isEmpty) {
                              if (mounted) setState(() {
                                _burnInProgress = false;
                                _activeBurnVaultIndex = null;
                                _burnShowSpinner = false;
                                _burnStatusMessage = '';
                              });
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('Cannot get wallet address')),
                              );
                              return;
                            }

                            try {
                              final quantity = hasAssets ? balStr : '0.0000 CLOAK';
                              print('[BURN] Starting vault burn: hash=${commitmentHash.substring(0, 16)}..., quantity=$quantity, hasAssets=$hasAssets');

                              // All validation done — fade in spinner and update message.
                              // ZK proof runs in isolate so main thread stays free.
                              if (mounted) setState(() {
                                _burnShowSpinner = true;
                                _burnStatusMessage = 'Generating ZK proof...';
                              });
                              await WidgetsBinding.instance.endOfFrame;

                              await CloakWalletManager.authenticateVault(
                                vaultHash: commitmentHash,
                                recipientAddress: recipientAddress,
                                quantity: quantity,
                                burn: 1,
                                onStatus: (msg) {
                                  if (mounted) setState(() => _burnStatusMessage = msg);
                                },
                              );
                              print('[BURN] Vault burn succeeded');

                              if (mounted) setState(() => _burnStatusMessage = 'Cleaning up...');

                              // Record burn event for TX history labeling
                              await CloakDb.addBurnEvent(commitmentHash, DateTime.now().millisecondsSinceEpoch);
                              if (commitmentHash.isNotEmpty) {
                                await CloakWalletManager.updateVaultStatus(commitmentHash, 'burned');
                              }
                              if (vaultId != null) {
                                await CloakWalletManager.deleteImportedVault(vaultId, commitmentHash: commitmentHash);
                              }
                              if (isVaultMode && activeVaultHash == commitmentHash) {
                                setActiveAccount(CLOAK_COIN, 1);
                              }

                              if (mounted) setState(() => _burnStatusMessage = 'Vault burned!');
                              await Future.delayed(const Duration(milliseconds: 600));
                              // Start fade-out animation (keep burn panel visible during fade)
                              if (mounted) setState(() {
                                _fadingVaultHash = commitmentHash;
                                _vaultActionIndices.remove(vaultIndex);
                              });
                              // Vault removal happens in TweenAnimationBuilder onEnd
                            } catch (e, st) {
                              print('[BURN] Vault burn FAILED: $e\n$st');
                              // Clear loading panel FIRST so SnackBar is visible
                              if (mounted) setState(() {
                                _burnInProgress = false;
                                _activeBurnVaultIndex = null;
                                _burnShowSpinner = false;
                                _burnStatusMessage = '';
                              });
                              await WidgetsBinding.instance.endOfFrame;
                              // User-friendly error message
                              final errStr = e.toString();
                              String userMsg;
                              if (errStr.contains('InsufficientFunds')) {
                                final feeHint = _burnFeeAmount > 0
                                    ? ' (need ~${_burnFeeAmount.toStringAsFixed(2)} CLOAK)'
                                    : '';
                                userMsg = 'Insufficient CLOAK balance to cover burn fee$feeHint';
                              } else if (errStr.contains('auth_token') || errStr.contains('AuthToken')) {
                                userMsg = 'Auth token error — try resyncing your wallet';
                              } else {
                                userMsg = 'Burn failed: $errStr';
                              }
                              if (mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(userMsg),
                                    duration: const Duration(seconds: 5),
                                  ),
                                );
                              }
                            }
                          },
                        );
                      }),
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('vault-empty-actions')),
          ),
          // Tap to switch to this vault
          onTap: () {
            if (isSelected) {
              // Already selected — just dismiss
              if (Navigator.of(widget.parentContext).canPop()) {
                Navigator.of(widget.parentContext).pop();
              }
              return;
            }
            // Start closing animation immediately
            if (Navigator.of(widget.parentContext).canPop()) {
              Navigator.of(widget.parentContext).pop();
            }
            // Switch to vault after dismissal begins
            Future(() {
              setActiveVault(
                commitmentHash,
                label: label,
                vaultData: vault,
              );
            });
          },
          onLongPress: () {
            setState(() {
              if (_vaultActionIndices.contains(vaultIndex)) {
                _vaultActionIndices.remove(vaultIndex);
                if (_burnConfirmVaultIndex == vaultIndex) {
                  _burnConfirmVaultIndex = null;
                  _burnFeeChecking = false;
                  _burnFeeInsufficient = false;
                  _burnFeeAmount = 0.0;
                }
              } else {
                _vaultActionIndices.add(vaultIndex);
              }
            });
          },
        ),
            // Burn explanation text — full card width, below ListTile, with fade-in
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _burnConfirmVaultIndex == vaultIndex
                  ? Builder(builder: (ctx) {
                      final bool anotherBurnActive = _burnInProgress || _fadingVaultHash != null;
                      final feeStr = _burnFeeAmount > 0
                          ? _burnFeeAmount.toStringAsFixed(2)
                          : '??';
                      return TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (anotherBurnActive)
                                Text(
                                  'A vault burn is already in progress. Please allow it to complete and try again.',
                                  style: TextStyle(color: Colors.grey.withOpacity(0.8), fontFamily: balanceFontFamily, fontSize: 11),
                                )
                              else if (_burnFeeChecking)
                                Text(
                                  'Checking burn fee...',
                                  style: TextStyle(color: Colors.grey.withOpacity(0.8), fontFamily: balanceFontFamily, fontSize: 11),
                                )
                              else if (_burnFeeAmount < 0)
                                Text(
                                  'Could not estimate burn fee. Check network connection and try again.',
                                  style: TextStyle(color: Colors.orange.withOpacity(0.9), fontFamily: balanceFontFamily, fontSize: 11),
                                )
                              else if (insufficientBalance)
                                Text(
                                  'Insufficient CLOAK balance to burn this vault (need ~$feeStr CLOAK).',
                                  style: TextStyle(color: Colors.grey.withOpacity(0.8), fontFamily: balanceFontFamily, fontSize: 11),
                                )
                              else ...[
                                if (vaultHasAssets)
                                  Text(
                                    'All vault assets will be withdrawn into your wallet before vault burn.',
                                    style: TextStyle(color: Colors.orange.withOpacity(0.9), fontFamily: balanceFontFamily, fontSize: 11),
                                  ),
                                Text(
                                  vaultNeverPublished
                                      ? 'Tap the fire icon to delete.'
                                      : 'Burning costs ~$feeStr CLOAK. Tap the fire icon to burn.',
                                  style: TextStyle(color: balanceTextColor.withOpacity(0.5), fontFamily: balanceFontFamily, fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    })
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  void _showVaultDetails(BuildContext context, Map<String, dynamic> vault) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final label = vault['label'] as String? ?? 'Vault';
    final commitmentHash = vault['commitment_hash'] as String? ?? '';
    final seed = vault['seed'] as String? ?? '';
    final contract = vault['contract'] as String? ?? 'thezeostoken';
    final balance = _vaultBalances[commitmentHash] ?? 'Loading...';

    showDialog(
      context: context,
      builder: (ctx) => _VaultDetailsDialog(
        label: label,
        commitmentHash: commitmentHash,
        seed: seed,
        contract: contract,
        balance: balance,
        balanceTextColor: balanceTextColor,
        balanceFontFamily: balanceFontFamily,
        surfaceColor: t.colorScheme.surface,
        buildDetailRow: _buildDetailRow,
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, Color textColor, String? fontFamily, {bool canCopy = false, bool isSecret = false, bool isHighlight = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: textColor.withOpacity(0.6),
            fontFamily: fontFamily,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                isSecret ? '••••••••••••••••••••••••' : value,
                style: TextStyle(
                  color: isHighlight ? const Color(0xFF4CAF50) : textColor,
                  fontFamily: fontFamily,
                  fontSize: isHighlight ? 16 : 13,
                  fontWeight: isHighlight ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (canCopy)
              IconButton(
                icon: Icon(Icons.copy, size: 18, color: textColor.withOpacity(0.6)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$label copied to clipboard')),
                  );
                },
                tooltip: 'Copy',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _editNameController.dispose();
    _editFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _animateBack() {
    _bounce = Tween<double>(begin: _dragOffset, end: 0.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller
      ..reset()
      ..addListener(() {
        setState(() => _dragOffset = _bounce!.value);
      })
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final panelHeight = MediaQuery.of(context).size.height * 0.60;
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: double.infinity,
              height: panelHeight,
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Builder(builder: (context) {
                        final ThemeData localTheme = Theme.of(context);
                        final s = S.of(context);
                        final zashi = localTheme.extension<ZashiThemeExt>();
                        final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                        final balanceFontFamily = localTheme.textTheme.displaySmall?.fontFamily;
                        final titleStyle = (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
                          fontWeight: FontWeight.w400,
                          color: balanceTextColor,
                          fontFamily: balanceFontFamily,
                        );
                        final iconSize = (titleStyle.fontSize ?? 20.0) * 1.0;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'Wallets & Hardware',
                                style: titleStyle,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: s.newAccount,
                              onPressed: () => setState(() {
                                if (_actionIndices.isNotEmpty || _editingIndex != null || _vaultActionIndices.isNotEmpty) {
                                  _actionIndices.clear();
                                  _editingIndex = null;
                                  _vaultActionIndices.clear();
                                  _burnConfirmVaultIndex = null;
                                } else if (_showNewVault) {
                                  // From Vault → return to chooser
                                  _showNewVault = false;
                                  _showNewAccountMenu = true;
                                } else if (_showNewAccountMenu) {
                                  // From chooser → close overlay
                                  _showNewAccountMenu = false;
                                } else {
                                  // Closed → open chooser first
                                  _showNewAccountMenu = true;
                                }
                              }),
                              icon: AnimatedRotation(
                                turns: (_showNewVault || _showNewAccountMenu || _actionIndices.isNotEmpty || _editingIndex != null || _vaultActionIndices.isNotEmpty) ? 0.125 : 0.0, // 45° rotation when panel/actions visible
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                child: Icon(Icons.add, color: balanceTextColor, size: iconSize),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          // Static account list with vaults section
                          Scrollbar(
                            thumbVisibility: true,
                            child: ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            itemCount: _accounts.length + (_vaults.isNotEmpty ? _vaults.length + 1 : 0), // +1 for header
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (ctx, index) {
                              // Vaults section (after accounts)
                              if (index >= _accounts.length) {
                                final vaultIndex = index - _accounts.length;
                                // Vaults header
                                if (vaultIndex == 0) {
                                  return _buildVaultsHeader(ctx);
                                }
                                // Vault card
                                final vaultListIndex = vaultIndex - 1;
                                final vault = _vaults[vaultListIndex];
                                final vaultHash = vault['commitment_hash'] as String? ?? '';
                                // Fade-out + collapse animation after burn/remove
                                if (_fadingVaultHash != null && _fadingVaultHash == vaultHash) {
                                  return TweenAnimationBuilder<double>(
                                    key: ValueKey('fading-$vaultHash'),
                                    tween: Tween(begin: 1.0, end: 0.0),
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeInCubic,
                                    onEnd: () {
                                      if (mounted) setState(() {
                                        _burnInProgress = false;
                                        _burnShowSpinner = false;
                                        _burnStatusMessage = '';
                                        _burnConfirmVaultIndex = null;
                                        _activeBurnVaultIndex = null;
                                        _fadingVaultHash = null;
                                        _burnFeeChecking = false;
                                        _burnFeeInsufficient = false;
                                        _burnFeeAmount = 0.0;
                                      });
                                      _loadVaults();
                                    },
                                    builder: (context, value, child) {
                                      return Opacity(
                                        opacity: value,
                                        child: Align(
                                          heightFactor: value.clamp(0.0, 1.0),
                                          alignment: Alignment.topCenter,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: _buildVaultCard(ctx, vault, vaultListIndex),
                                  );
                                }
                                return _buildVaultCard(ctx, vault, vaultListIndex);
                              }
                              final a = _accounts[index];
                              final isSelected = !isVaultMode && (a.coin == aa.coin && a.id == aa.id);
                              final c = coins[a.coin];
                              final zashi = t.extension<ZashiThemeExt>();
                              final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                              final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
                              final bool isWatchOnly = (a.keyType == 0x80);
                              const Color watchBlue = Color(0xFF80D8FF);
                              final Color rowFillColor = isWatchOnly
                                  ? watchBlue.withOpacity(isSelected ? 0.28 : 0.18)
                                  : (isSelected
                                      ? t.colorScheme.onSurface.withOpacity(0.10)
                                      : t.colorScheme.onSurface.withOpacity(0.06));
                              final BoxBorder? rowBorder = isWatchOnly ? Border.all(color: watchBlue, width: 1.0) : null;
                              String addrPreview = '';
                              try {
                                String mainAddr = '';
                                if (CloakWalletManager.isCloak(a.coin)) {
                                  // CLOAK uses stable default address (getAddress() mutates wallet)
                                  mainAddr = CloakWalletManager.getDefaultAddress() ?? '';
                                }
                                addrPreview = mainAddr.isNotEmpty
                                    ? (mainAddr.length > 20 ? mainAddr.substring(0, 20) + '...' : mainAddr)
                                    : '';
                              } catch (_) {}
                              final bool isEditing = _editingIndex == index;
                              final bool showChevrons = isEditing && _accounts.length > 1;
                              final bool canMoveUp = showChevrons && index > 0;
                              final bool canMoveDown = showChevrons && index < _accounts.length - 1;
                              return Material(
                                color: Colors.transparent,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                clipBehavior: Clip.antiAlias,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  margin: const EdgeInsets.symmetric(horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: rowFillColor,
                                    border: rowBorder,
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                  child: ListTile(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                      leading: _coinLogo(a.coin, 35),
                                      title: isEditing
                                          ? Theme(
                                              data: t.copyWith(
                                                textSelectionTheme: const TextSelectionThemeData(
                                                  selectionColor: Colors.transparent,
                                                  selectionHandleColor: Colors.white70,
                                                ),
                                              ),
                                              child: TextField(
                                                controller: _editNameController,
                                                focusNode: _editFocusNode,
                                                autofocus: true,
                                                cursorColor: Colors.white,
                                                style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                                                  fontWeight: FontWeight.w400,
                                                  color: balanceTextColor,
                                                  fontFamily: balanceFontFamily,
                                                ),
                                                decoration: InputDecoration(
                                                  isDense: true,
                                                  contentPadding: EdgeInsets.zero,
                                                  filled: false,
                                                  border: InputBorder.none,
                                                  enabledBorder: InputBorder.none,
                                                  focusedBorder: InputBorder.none,
                                                  errorBorder: InputBorder.none,
                                                  focusedErrorBorder: InputBorder.none,
                                                  errorStyle: const TextStyle(height: 0, fontSize: 0),
                                                ),
                                                onSubmitted: (_) => _commitInlineRename(a),
                                              ),
                                            )
                                          : Text(
                                              a.name ?? '',
                                              style: (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                                                fontWeight: FontWeight.w400,
                                                color: balanceTextColor,
                                                fontFamily: balanceFontFamily,
                                              ),
                                            ),
                                      subtitle: addrPreview.isEmpty
                                          ? null
                                          : Text(
                                              addrPreview,
                                              style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                                                fontWeight: FontWeight.w400,
                                                color: balanceTextColor,
                                                fontFamily: balanceFontFamily,
                                              ),
                                            ),
                                      trailing: AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 200),
                                        switchInCurve: Curves.easeInOut,
                                        switchOutCurve: Curves.easeInOut,
                                        transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                                        child: _actionIndices.contains(index)
                                            ? Row(
                                                key: ValueKey('actions-$index'),
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _ActionChip(
                                                    icon: Icon(isEditing ? Icons.check : Icons.edit, color: t.colorScheme.onSurface, size: 20),
                                                    onTap: () => isEditing ? _commitInlineRename(a) : _startInlineRename(index, a),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  showChevrons
                                                      ? _ActionChip(
                                                          icon: Icon(
                                                            Icons.keyboard_arrow_up,
                                                            color: !canMoveUp ? t.colorScheme.onSurface.withOpacity(0.35) : t.colorScheme.onSurface,
                                                            size: 20,
                                                          ),
                                                          onTap: () {
                                                            if (!canMoveUp) return;
                                                            setState(() {
                                                              final moved = _accounts.removeAt(index);
                                                              _accounts.insert(index - 1, moved);
                                                              _actionIndices.remove(index);
                                                              _actionIndices.add(index - 1);
                                                              _editingIndex = index - 1;
                                                            });
                                                          },
                                                        )
                                                      : _ActionChip(
                                                          icon: Icon(Icons.delete, color: t.colorScheme.onSurface, size: 20),
                                                          onTap: () => _deleteAccount(context, a),
                                                        ),
                                                  const SizedBox(width: 8),
                                                  showChevrons
                                                      ? _ActionChip(
                                                          icon: Icon(
                                                            Icons.keyboard_arrow_down,
                                                            color: !canMoveDown ? t.colorScheme.onSurface.withOpacity(0.35) : t.colorScheme.onSurface,
                                                            size: 20,
                                                          ),
                                                          onTap: () {
                                                            if (!canMoveDown) return;
                                                            setState(() {
                                                              final moved = _accounts.removeAt(index);
                                                              _accounts.insert(index + 1, moved);
                                                              _actionIndices.remove(index);
                                                              _actionIndices.add(index + 1);
                                                              _editingIndex = index + 1;
                                                            });
                                                          },
                                                        )
                                                      : (isWatchOnly
                                                          ? const SizedBox.shrink()
                                                          : _ActionChip(
                                                              icon: Icon(MdiIcons.snowflake, color: t.colorScheme.onSurface, size: 20),
                                                              onTap: () => _convertToWatchOnly(context, a),
                                                            )),
                                                ],
                                              )
                                            : (isWatchOnly
                                                ? Padding(
                                                    key: ValueKey('watchonly-$index'),
                                                    padding: const EdgeInsets.only(right: 2),
                                                    child: Text(
                                                      'Watch-Only',
                                                      style: (t.textTheme.bodySmall ?? const TextStyle()).copyWith(
                                                        fontWeight: FontWeight.w400,
                                                        color: balanceTextColor,
                                                        fontFamily: balanceFontFamily,
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox.shrink(key: ValueKey('empty-actions'))),
                                      ),
                                      onTap: () async {
                                        if (!isVaultMode && a.coin == aa.coin && a.id == aa.id) {
                                          if (Navigator.of(widget.parentContext).canPop()) {
                                            Navigator.of(widget.parentContext).pop();
                                          }
                                          return;
                                        }
                                        // Start closing animation immediately
                                        if (Navigator.of(widget.parentContext).canPop()) {
                                          Navigator.of(widget.parentContext).pop();
                                        }
                                        // Perform the account switch after dismissal begins
                                        Future(() async {
                                          final prefs = await SharedPreferences.getInstance();
                                          setActiveAccount(a.coin, a.id);
                                          await aa.save(prefs);
                                        });
                                      },
                                      onLongPress: () {
                                        setState(() {
                                          if (_actionIndices.contains(index)) {
                                            _actionIndices.remove(index);
                                            if (_editingIndex == index) _editingIndex = null;
                                          } else {
                                            _actionIndices.add(index);
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                );
                            },
                          )),
                          // Sliding overlay panel for chooser/new/restore panels
                          Positioned.fill(
                            child: IgnorePointer(
                              ignoring: !(_showNewVault || _showNewAccountMenu),
                              child: AnimatedSlide(
                                duration: const Duration(milliseconds: 260),
                                curve: Curves.easeOutCubic,
                                offset: (_showNewVault || _showNewAccountMenu) ? Offset.zero : const Offset(1, 0),
                                child: Material(
                                  color: t.colorScheme.surface,
                                  child: Stack(
                                    children: [
                                      // Base chooser panel underneath (remains static)
                                      IgnorePointer(
                                        ignoring: _showNewVault,
                                        child: _NewAccountChoicePanel(
                                          key: const ValueKey('chooser'),
                                          onCreateVault: () => setState(() {
                                            _showNewAccountMenu = false;
                                            _showNewVault = true;
                                          }),
                                        ),
                                      ),
                                      // Sliding overlay panel for Vault creation (covers/uncover chooser)
                                      Positioned.fill(
                                        child: AnimatedSlide(
                                          duration: const Duration(milliseconds: 260),
                                          curve: Curves.easeOutCubic,
                                          offset: _showNewVault ? Offset.zero : const Offset(1, 0),
                                          child: Container(
                                            color: t.colorScheme.surface,
                                            child: _showNewVault
                                                ? _NewVaultInline(
                                                    key: const ValueKey('new-vault'),
                                                    onCancel: () => setState(() {
                                                      _showNewVault = false;
                                                      _showNewAccountMenu = true;
                                                    }),
                                                    onCreated: () async {
                                                      Navigator.of(context).pop();
                                                    },
                                                  )
                                                : const SizedBox.shrink(key: ValueKey('no-form')),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) {
                        final dy = details.delta.dy;
                        if (dy < 0) {
                          setState(() => _dragOffset = (_dragOffset + dy).clamp(-panelHeight, 0.0));
                        } else {
                          setState(() => _dragOffset = (_dragOffset + dy * 0.35).clamp(-panelHeight, panelHeight));
                        }
                      },
                      onVerticalDragEnd: (details) {
                        final shouldClose = _dragOffset < -panelHeight * 0.15 || (details.primaryVelocity ?? 0) < -600;
                        if (shouldClose) {
                          Navigator.of(context).pop();
                        } else {
                          _animateBack();
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: t.dividerColor.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
  }

  Future<void> _refreshAccounts() async {
    final loaded = getAllAccounts();
    final order = await loadAccountOrder();
    final applied = applyAccountOrder(loaded, order);
    if (!mounted) return;
    setState(() {
      _accounts = applied;
      _actionIndices.clear();
      _editingIndex = null;
    });
  }

  Future<void> _renameAccount(BuildContext context, CloakAccount a) async {
    final controller = TextEditingController(text: a.name ?? '');
    final s = S.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.accountName),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    await CloakDb.updateAccountName(a.id, newName);
    await refreshCloakAccountsCache();
    await _refreshAccounts();
  }

  Future<void> _deleteAccount(BuildContext context, CloakAccount a) async {
    final s = S.of(context);
    final count = _accounts.length;
    if (count > 1 && a.coin == aa.coin && a.id == aa.id) {
      await showMessageBox2(
          context,
          s.error,
          s.cannotDeleteActive + '.' + '\n\n' + 'To delete this account switch to your other account first.');
      return;
    }
    final confirmed = await showConfirmDialog(context, s.deleteAccount(a.name!), s.confirmDeleteAccount);
    if (!confirmed) return;
    await CloakDb.deleteAccount(a.id);
    await CloakWalletManager.deleteWallet();
    await refreshCloakAccountsCache();
    await _refreshAccounts();
    if (count == 1) {
      setActiveAccount(0, 0);
      GoRouter.of(context).go('/account');
    }
  }

  Future<void> _convertToWatchOnly(BuildContext context, CloakAccount a) async {
    final s = S.of(context);
    final confirmed = await showConfirmDialog(
      context,
      'Convert to Watch-Only',
      s.confirmWatchOnly,
      confirmLabel: s.ok,
      cancelLabel: s.cancel,
    );
    if (!confirmed) return;
    // CLOAK doesn't support watch-only conversion yet
    return;
    // If the converted account is currently active, refresh the active account
    // so Home reacts to canPay change (quick actions update immediately)
    if (a.coin == aa.coin && a.id == aa.id) {
      setActiveAccount(aa.coin, aa.id);
    }
    await _refreshAccounts();
  }

  void _startInlineRename(int index, CloakAccount a) {
    setState(() {
      _editingIndex = index;
      _editNameController.text = a.name ?? '';
      // place cursor at end
      _editNameController.selection = TextSelection.fromPosition(TextPosition(offset: _editNameController.text.length));
      // ensure actions visible for this row
      _actionIndices.add(index);
    });
    // focus after frame to avoid focus conflicts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocusNode.requestFocus();
    });
  }

  Future<void> _commitInlineRename(CloakAccount a) async {
    final newName = _editNameController.text.trim();
    // Persist current order (in case user moved via chevrons) regardless of name change
    await saveAccountOrder(_accounts);
    if (newName.isNotEmpty && newName != (a.name ?? '')) {
      await CloakDb.updateAccountName(a.id, newName);
      await refreshCloakAccountsCache();
    }
    await _refreshAccounts();
  }
}

/// Vault details dialog with publish button (StatefulWidget for progress state)
class _VaultDetailsDialog extends StatefulWidget {
  final String label;
  final String commitmentHash;
  final String seed;
  final String contract;
  final String balance;
  final Color balanceTextColor;
  final String? balanceFontFamily;
  final Color surfaceColor;
  final Widget Function(String, String, Color, String?, {bool canCopy, bool isHighlight, bool isSecret}) buildDetailRow;

  const _VaultDetailsDialog({
    required this.label,
    required this.commitmentHash,
    required this.seed,
    required this.contract,
    required this.balance,
    required this.balanceTextColor,
    required this.balanceFontFamily,
    required this.surfaceColor,
    required this.buildDetailRow,
  });

  @override
  State<_VaultDetailsDialog> createState() => _VaultDetailsDialogState();
}

class _VaultDetailsDialogState extends State<_VaultDetailsDialog> {
  bool _isPublishing = false;
  String? _publishStatus;

  Future<void> _publishVault() async {
    setState(() {
      _isPublishing = true;
      _publishStatus = 'Generating ZK proof...';
    });

    try {
      final txId = await CloakWalletManager.publishVaultDirect();

      if (mounted) {
        setState(() {
          _isPublishing = false;
          _publishStatus = null;
        });
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Vault published! TX: ${txId.substring(0, 16)}...'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[VaultDetails] Publish error: $e');
      if (mounted) {
        setState(() {
          _isPublishing = false;
          _publishStatus = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Publish failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: widget.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock, color: Color(0xFF4CAF50), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.balanceTextColor,
                fontFamily: widget.balanceFontFamily,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.buildDetailRow('Balance', widget.balance, widget.balanceTextColor, widget.balanceFontFamily, isHighlight: true),
            const SizedBox(height: 16),
            widget.buildDetailRow('Deposit To', 'thezeosvault', widget.balanceTextColor, widget.balanceFontFamily, canCopy: true),
            const SizedBox(height: 16),
            widget.buildDetailRow('Deposit Memo', 'AUTH:${widget.commitmentHash}|', widget.balanceTextColor, widget.balanceFontFamily, canCopy: true),
            const SizedBox(height: 16),
            widget.buildDetailRow('Commitment Hash', widget.commitmentHash, widget.balanceTextColor, widget.balanceFontFamily, canCopy: true),
            const SizedBox(height: 16),
            widget.buildDetailRow('Seed Phrase', widget.seed, widget.balanceTextColor, widget.balanceFontFamily, canCopy: true, isSecret: true),
            const SizedBox(height: 16),
            widget.buildDetailRow('Contract', widget.contract, widget.balanceTextColor, widget.balanceFontFamily),
            if (_publishStatus != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _publishStatus!,
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isPublishing ? null : () => Navigator.of(context).pop(),
          child: Text('Close', style: TextStyle(color: widget.balanceTextColor)),
        ),
        ElevatedButton.icon(
          onPressed: _isPublishing ? null : () {
            Navigator.of(context).pop();
            GoRouter.of(context).push('/account/quick_send', extra: SendContext(
              'thezeosvault',
              7,
              Amount(0, false),
              MemoData(false, '', 'AUTH:${widget.commitmentHash}|'),
            ));
          },
          icon: const Icon(Icons.savings, size: 18),
          label: const Text('Deposit'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
        ),
        ElevatedButton.icon(
          onPressed: _isPublishing ? null : _publishVault,
          icon: _isPublishing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.publish, size: 18),
          label: Text(_isPublishing ? 'Publishing...' : 'Publish to Blockchain'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey[700],
          ),
        ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;
  const _ActionChip({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Match SEND suffix chips: subtle dark bg with hairline border
    final addressFillColor = const Color(0xFF2E2C2C);
    final chipBgColor = Color.lerp(addressFillColor, Colors.black, 0.06) ?? addressFillColor;
    final chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
    final radius = BorderRadius.circular(10);
    return Material(
      color: chipBgColor,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: chipBorderColor)),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(child: icon),
        ),
      ),
    );
  }
}

// Exact Zashi QR glyph used in SEND page
const String _ZASHI_QR_GLYPH =
    '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(0.5,0.5)">\n'
    '    <path d="M13.833 18H18V22.167M10.508 18H10.5M14.675 22.167H14.667M18.008 25.5H18M25.508 18H25.5M10.5 22.167H11.75M20.917 18H22.583M10.5 25.5H14.667M18 9.667V14.667M22.667 25.5H24.167C24.633 25.5 24.867 25.5 25.045 25.409C25.202 25.329 25.329 25.202 25.409 25.045C25.5 24.867 25.5 24.633 25.5 24.167V22.667C25.5 22.2 25.5 21.967 25.409 21.788C25.329 21.632 25.202 21.504 25.045 21.424C24.867 21.333 24.633 21.333 24.167 21.333H22.667C22.2 21.333 21.967 21.333 21.788 21.424C21.632 21.504 21.504 21.632 21.424 21.788C21.333 21.967 21.333 22.2 21.333 22.667V24.167C21.333 24.633 21.333 24.867 21.424 25.045C21.504 25.202 21.632 25.329 21.788 25.409C21.967 25.5 22.2 25.5 22.667 25.5ZM22.667 14.667H24.167C24.633 14.667 24.867 14.667 25.045 14.576C25.202 14.496 25.329 14.368 25.409 14.212C25.5 14.033 25.5 13.8 25.5 13.333V11.833C25.5 11.367 25.5 11.133 25.409 10.955C25.329 10.798 25.202 10.671 25.045 10.591C24.867 10.5 24.633 10.5 24.167 10.5H22.667C22.2 10.5 21.967 10.5 21.788 10.591C21.632 10.671 21.504 10.798 21.424 10.955C21.333 11.133 21.333 11.367 21.333 11.833V13.333C21.333 13.8 21.333 14.033 21.424 14.212C21.504 14.368 21.632 14.496 21.788 14.576C21.967 14.667 22.2 14.667 22.667 14.667ZM11.833 14.667H13.333C13.8 14.667 14.033 14.667 14.212 14.576C14.368 14.496 14.496 14.368 14.576 14.212C14.667 14.033 14.667 13.8 14.667 13.333V11.833C14.667 11.367 14.667 11.133 14.576 10.955C14.496 10.798 14.368 10.671 14.212 10.591C14.033 10.5 13.8 10.5 13.333 10.5H11.833C11.367 10.5 11.133 10.5 10.955 10.591C10.798 10.798 10.671 10.955 10.591 10.955C10.5 11.133 10.5 11.367 10.5 11.833V13.333C10.5 13.8 10.5 14.033 10.591 14.212C10.671 14.368 10.798 14.496 10.955 14.576C11.133 14.667 11.367 14.667 11.833 14.667Z" stroke="#231F20" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter" fill="none"/>\n'
    '  </g>\n'
    '</svg>';

class _NewAccountChoicePanel extends StatelessWidget {
  final VoidCallback onCreateVault;
  const _NewAccountChoicePanel({Key? key, required this.onCreateVault}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final labelFamily = t.textTheme.displaySmall?.fontFamily;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: Material(
                color: const Color(0xFF4CAF50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onCreateVault,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Create Vault',
                          style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                            fontFamily: labelFamily,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



class _NewVaultInline extends StatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onCreated;
  const _NewVaultInline({Key? key, required this.onCancel, required this.onCreated}) : super(key: key);
  @override
  State<_NewVaultInline> createState() => _NewVaultInlineState();
}

class _NewVaultInlineState extends State<_NewVaultInline> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _submitting = false;
  bool _showSpinner = false;
  String _statusMessage = '';
  String? _estimatedFee; // null = loading, set after estimation

  @override
  void initState() {
    super.initState();
    _fetchFee();
  }

  Future<void> _fetchFee() async {
    try {
      final feeStr = await CloakWalletManager.getVaultCreationFee();
      final feeVal = double.tryParse(feeStr.split(' ').first);
      if (mounted && feeVal != null) {
        setState(() => _estimatedFee = '~${feeVal.toStringAsFixed(1)}');
      }
    } catch (e) {
      print('[VaultCreate] Fee label estimation failed: $e');
      if (mounted) setState(() => _estimatedFee = null);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final balanceCursorColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    const addressFillColor = Color(0xFF2E2C2C);

    if (_submitting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedOpacity(
                opacity: _showSpinner ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 350),
                child: SizedBox(
                  width: 36, height: 36,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF4CAF50)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _statusMessage.isNotEmpty ? _statusMessage : 'Creating your vault...',
                style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                  color: balanceTextColor,
                  fontFamily: balanceFontFamily,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Please wait, this won\'t take long',
                style: TextStyle(
                  color: balanceTextColor.withOpacity(0.5),
                  fontFamily: balanceFontFamily,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'New Vault',
                    style: (t.textTheme.titleMedium ?? const TextStyle()).copyWith(
                      color: balanceTextColor,
                      fontFamily: balanceFontFamily,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nameController,
                    cursorColor: balanceCursorColor,
                    style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      color: t.colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Vault Name',
                      hintStyle: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                        fontFamily: balanceFontFamily,
                        fontWeight: FontWeight.w400,
                        color: t.colorScheme.onSurface.withOpacity(0.7),
                      ),
                      filled: true,
                      fillColor: addressFillColor,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: t.colorScheme.error, width: 1.2),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: t.colorScheme.error, width: 1.2),
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _estimatedFee != null
                        ? 'Creating a vault costs $_estimatedFee CLOAK from your shielded balance'
                        : 'Creating a vault costs CLOAK from your shielded balance',
                    style: TextStyle(
                      color: balanceTextColor.withOpacity(0.5),
                      fontFamily: balanceFontFamily,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            height: 48,
            width: double.infinity,
            child: Material(
              color: const Color(0xFF4CAF50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _onSubmit,
                child: Center(
                  child: Text(
                    'Create',
                    style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    // Show text-only loading state IMMEDIATELY — spinner hidden until
    // all blocking work is done so the user never sees a frozen spinner.
    setState(() {
      _submitting = true;
      _showSpinner = false;
      _statusMessage = 'Creating your vault...';
    });

    // Wait for the framework to actually paint the loading frame.
    await WidgetsBinding.instance.endOfFrame;

    try {
      final name = _nameController.text.trim();

      // Check shielded balance (runs in background isolate)
      double cloakBalance = 0.0;
      final balJson = await CloakWalletManager.getBalancesJsonAsync();
      if (balJson != null) {
        try {
          final balances = jsonDecode(balJson) as List;
          for (final b in balances) {
            if (b is String && b.endsWith('CLOAK@thezeostoken')) {
              cloakBalance = double.tryParse(b.split('@')[0].replaceAll('CLOAK', '').trim()) ?? 0.0;
              break;
            }
          }
        } catch (_) {}
      }
      // Estimate vault creation fee using Rust (accounts for note fragmentation)
      double requiredFee;
      try {
        final feeStr = await CloakWalletManager.getVaultCreationFee();
        requiredFee = double.tryParse(feeStr.split(' ').first) ?? double.infinity;
      } catch (e) {
        print('[VaultCreate] Fee estimation failed: $e');
        requiredFee = double.infinity;
      }
      if (cloakBalance < requiredFee) {
        if (mounted) setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(requiredFee == double.infinity
              ? 'Could not estimate vault creation fee — check network'
              : 'Insufficient shielded CLOAK to create vault (need ~${requiredFee.toStringAsFixed(2)})')),
        );
        return;
      }

      // Create vault locally (runs in background isolate)
      final hash = await CloakWalletManager.createAndStoreVault(label: name);
      if (hash == null) {
        if (mounted) setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create vault')),
        );
        return;
      }

      // All blocking work done — fade in the spinner and update message.
      // From here on, ZK proof runs in an isolate so the main thread is free.
      if (mounted) setState(() {
        _showSpinner = true;
        _statusMessage = 'Publishing to blockchain...';
      });
      await WidgetsBinding.instance.endOfFrame;

      // Publish vault on-chain (ZK proof in isolate + broadcast)
      try {
        await CloakWalletManager.publishVaultDirect();
      } catch (e) {
        print('[_NewVaultInline] Publish error: $e');
        // Still proceed — vault is created locally, publish can be retried
      }

      // Enter vault mode
      if (mounted) setState(() => _statusMessage = 'Vault ready!');
      await Future.delayed(const Duration(milliseconds: 500));

      final vaultData = await CloakWalletManager.getVaultByHash(hash);
      setActiveVault(hash, label: name, vaultData: vaultData);

      // Dismiss the account switcher — keep _submitting=true so the
      // loading panel stays visible during the slide-out animation.
      if (mounted) widget.onCreated();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      if (mounted) setState(() {
        _submitting = false;
        _showSpinner = false;
      });
    }
  }
}




