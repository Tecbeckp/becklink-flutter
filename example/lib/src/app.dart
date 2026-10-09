import 'dart:async';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'deep_link_routes.dart';
import 'demo_state.dart';
import 'screens/config_screen.dart';
import 'screens/debug/debug_screen.dart';
import 'screens/home_screen.dart';
import 'screens/link_detail_screen.dart';
import 'screens/not_found_screen.dart';
import 'screens/product_screen.dart';
import 'screens/referral_screen.dart';

/// Root widget: Material 3 app with go_router, and the one place that turns
/// Beck Link links into navigation.
class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key, required this.demo, this.links});

  final DemoState demo;

  /// The links to route; `null` (every real app) for
  /// `BeckLink.instance.onLink`. The integration test passes its own stream
  /// to check the routing of a link whose deep-link path only the service
  /// knows.
  final Stream<LinkEvent>? links;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  static const Color _seedColor = Color(0xFF3D5AFE);

  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();
  late final GoRouter _router = _buildRouter(widget.demo);
  late final StreamSubscription<LinkEvent> _links;

  @override
  void initState() {
    super.initState();
    // Every Beck Link link is handled here and only here. onLink delivers
    // each link once: the one that launched the app (the same event
    // getInitialLink() returns, so this app does not call it as well), the
    // deferred link on the first run after install, and links opened while
    // the app runs. It keeps links until the first listener subscribes, so
    // subscribing after configure() loses none.
    _links = (widget.links ?? BeckLink.instance.onLink).listen(_openLink);
  }

  void _openLink(LinkEvent event) {
    final demo = widget.demo;
    final link = demo.recordLink(event);
    final detail = '/links/${link.id}';
    // The debug configuration shows every link's payload first, so the
    // owner sees "the app opened with this data" whatever the path.
    if (demo.openEveryLinkInDetail) {
      _router.go(detail, extra: link);
      return;
    }
    final location = appLocationForDeepLink(event.path);
    if (location != null) {
      // The screen gets the whole event to show the link's data.
      _router.go(location, extra: event);
      return;
    }
    _router.go('/');
    _showMessage(
      'That link leads to a page this app does not have, so it opened the '
      'home screen. The Debug screen shows the link.',
      action: SnackBarAction(
        label: 'Details',
        onPressed: () => _router.go(detail, extra: link),
      ),
    );
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    final snackBar = SnackBar(content: Text(message), action: action);
    final messenger = _messenger.currentState;
    if (messenger != null) {
      messenger.showSnackBar(snackBar);
      return;
    }
    // A launch link can arrive before the first frame built the messenger.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messenger.currentState?.showSnackBar(snackBar);
    });
  }

  @override
  void dispose() {
    unawaited(_links.cancel());
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Beck Link Debug',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    scaffoldMessengerKey: _messenger,
    routerConfig: _router,
  );

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    ),
  );

  static GoRouter _buildRouter(DemoState demo) => GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => HomeScreen(demo: demo),
        routes: <RouteBase>[
          GoRoute(
            path: 'product/:id',
            builder: (context, state) => ProductScreen(
              demo: demo,
              productId: state.pathParameters['id'] ?? '',
              link: _linkOf(state),
            ),
          ),
          GoRoute(
            path: 'referral',
            builder: (context, state) =>
                ReferralScreen(demo: demo, link: _linkOf(state)),
          ),
          GoRoute(
            path: 'debug',
            builder: (context, state) => DebugScreen(demo: demo),
          ),
          GoRoute(
            path: 'config',
            builder: (context, state) => ConfigScreen(demo: demo),
          ),
          GoRoute(
            path: 'links/:id',
            builder: (context, state) {
              final extra = state.extra;
              final id = int.tryParse(state.pathParameters['id'] ?? '');
              final link = extra is IncomingLink
                  ? extra
                  : (id == null ? null : demo.incomingLink(id));
              return link == null
                  ? const NotFoundScreen()
                  : LinkDetailScreen(demo: demo, link: link);
            },
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => const NotFoundScreen(),
  );

  /// The link that opened the route, when it was a link.
  static LinkEvent? _linkOf(GoRouterState state) {
    final extra = state.extra;
    return extra is LinkEvent ? extra : null;
  }
}
