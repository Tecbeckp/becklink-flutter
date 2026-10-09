import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Shown for an app location without a screen. Links never get here: their
/// paths are checked before navigating (see `appLocationForDeepLink`).
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'This app has no such page.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Go to the home screen'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
