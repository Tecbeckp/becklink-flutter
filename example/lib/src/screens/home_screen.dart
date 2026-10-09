import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../config/debug_config.dart';
import '../demo_state.dart';
import '../widgets/info_section.dart';
import '../widgets/setup_card.dart';

/// The start screen: SDK status, where it connects to, the links the app
/// received and the way to the Debug dashboard.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beck Link example'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Configure',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/config'),
          ),
          IconButton(
            tooltip: 'Debug dashboard',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => context.go('/debug'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: demo,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SetupCard(setup: demo.setup),
            const SizedBox(height: 8),
            _ConnectionCard(demo: demo),
            const SizedBox(height: 8),
            _StatusCard(demo: demo),
            const SizedBox(height: 8),
            _IncomingLinksCard(demo: demo),
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text('Try it', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            const Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  _DemoTile(
                    icon: Icons.bug_report_outlined,
                    title: 'Debug dashboard',
                    subtitle:
                        'First open, attribution, requests, actions and the '
                        'debug report',
                    location: '/debug',
                  ),
                  Divider(height: 1),
                  _DemoTile(
                    icon: Icons.shopping_bag_outlined,
                    title: 'Product 123',
                    subtitle:
                        'The screen a link with deep-link path /product/123 '
                        'opens',
                    location: '/product/123',
                  ),
                  Divider(height: 1),
                  _DemoTile(
                    icon: Icons.card_giftcard_outlined,
                    title: 'Invite a friend',
                    subtitle: 'Create a referral link with your user ID',
                    location: '/referral',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text('Open a link', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            Text(
              'Open a link of your project from another app (Notes, Messages, '
              'a chat), with adb, or paste it on the Debug dashboard: '
              'https://{slug}-test.becklinks.com/{short path}, or '
              'becklinkdebug://becklink?url={encoded link}.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) {
    final config = demo.config;
    return InfoSection(
      title: 'Connection',
      trailing: TextButton(
        onPressed: () => context.go('/config'),
        child: const Text('Configure'),
      ),
      children: <Widget>[
        if (config == null || !config.isComplete)
          const SectionNote('Nothing configured yet.')
        else ...<Widget>[
          InfoRow(label: 'SDK API', value: config.apiBaseUrl, monospace: true),
          InfoRow(
            label: 'Publishable key',
            value: maskSecret(config.apiKey),
            monospace: true,
          ),
          InfoRow(
            label: 'Link hosts',
            value: config.linkHosts.isEmpty
                ? 'None entered'
                : config.linkHosts.join('\n'),
            monospace: config.linkHosts.isNotEmpty,
          ),
        ],
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) {
    final diagnostics = demo.diagnostics;
    final attribution = demo.attribution ?? diagnostics?.attribution;
    return InfoSection(
      title: 'SDK',
      trailing: TextButton(
        onPressed: () => context.go('/debug'),
        child: const Text('Details'),
      ),
      children: <Widget>[
        InfoRow(label: 'SDK version', value: BeckLink.version),
        if (diagnostics != null) ...<Widget>[
          InfoRow(
            label: 'Install ID',
            value: diagnostics.installId ?? 'None',
            monospace: diagnostics.installId != null,
          ),
          InfoRow(
            label: 'First open',
            value: diagnostics.firstOpenStatus.wireValue,
          ),
        ],
        InfoRow(
          label: 'Attribution',
          value: attribution == null
              ? 'Not reported yet'
              : '${attribution.state.wireValue}'
                    '${attribution.matchMethod == null ? '' : ' · ${attribution.matchMethod!.wireValue}'}',
        ),
      ],
    );
  }
}

class _IncomingLinksCard extends StatelessWidget {
  const _IncomingLinksCard({required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) {
    final links = demo.incomingLinks.reversed.take(5).toList();
    return InfoSection(
      title: 'Incoming links',
      children: <Widget>[
        if (links.isEmpty)
          const SectionNote(
            'No link opened the app in this session yet. Each one appears '
            'here with the data the SDK resolved.',
          )
        else
          for (final link in links)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                link.event.isDeferred
                    ? Icons.download_done_outlined
                    : Icons.link,
              ),
              title: Text(
                link.event.path,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              subtitle: Text(
                '${link.event.matchMethod.wireValue} · '
                '${link.event.confidence.wireValue} · '
                '${TimeOfDay.fromDateTime(link.receivedAt).format(context)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/links/${link.id}', extra: link),
            ),
      ],
    );
  }
}

class _DemoTile extends StatelessWidget {
  const _DemoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.location,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String location;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => context.go(location),
  );
}
