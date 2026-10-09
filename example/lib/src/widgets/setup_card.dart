import 'package:flutter/material.dart';

import '../sdk_setup.dart';

/// Whether the SDK started, and how to fix it when it did not.
class SetupCard extends StatelessWidget {
  const SetupCard({super.key, required this.setup});

  final SdkSetup setup;

  @override
  Widget build(BuildContext context) {
    final setup = this.setup;
    switch (setup) {
      case SdkConfigured(:final environment):
        return _StatusCard(
          icon: Icons.check_circle_outline,
          title: 'SDK running with a $environment key',
          body: environment == 'test'
              ? 'Only test links ({slug}-test.becklinks.com) reach this app.'
              : 'Only live links ({slug}.becklinks.com) reach this app.',
        );
      case SdkKeyMissing():
        return const _StatusCard(
          icon: Icons.key_off_outlined,
          isProblem: true,
          title: 'Not configured yet',
          body:
              'Open Configure and enter the SDK API URL and the publishable '
              'key of your project environment (dashboard: project, API '
              'keys). They are kept on this device only.',
        );
      case SdkSetupFailed(:final message):
        return _StatusCard(
          icon: Icons.error_outline,
          isProblem: true,
          title: 'The SDK refused the key',
          body: '$message Never put a secret key (sk_…) in an app.',
        );
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.body,
    this.isProblem = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool isProblem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = isProblem
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Card(
      color: isProblem ? colors.errorContainer : colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
