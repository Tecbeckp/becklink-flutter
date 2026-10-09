import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../deep_link_routes.dart';
import '../demo_state.dart';
import '../widgets/info_section.dart';
import '../widgets/json_block.dart';
import '../widgets/link_details.dart';

/// `/links/:id`: what the app opened with: the incoming URL and the
/// `LinkEvent` the SDK resolved for it, field by field and as JSON.
class LinkDetailScreen extends StatelessWidget {
  const LinkDetailScreen({super.key, required this.demo, required this.link});

  final DemoState demo;
  final IncomingLink link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final event = link.event;
    final location = appLocationForDeepLink(event.path);
    final resolved = event.linkId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(event.isDeferred ? 'Deferred link' : 'Incoming link'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Copy LinkEvent JSON',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => copyWithFeedback(
              context,
              prettyJson(link.toJson()),
              what: 'LinkEvent JSON copied',
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            color: resolved ? colors.primaryContainer : colors.errorContainer,
            child: ListTile(
              leading: Icon(
                resolved ? Icons.verified_outlined : Icons.cloud_off_outlined,
                color: resolved
                    ? colors.onPrimaryContainer
                    : colors.onErrorContainer,
              ),
              title: Text(
                resolved
                    ? 'The app opened with this link'
                    : 'Opened, but not resolved by the service',
                style: TextStyle(
                  color: resolved
                      ? colors.onPrimaryContainer
                      : colors.onErrorContainer,
                ),
              ),
              subtitle: Text(
                resolved
                    ? 'Deep-link path ${event.path}, '
                          '${event.matchMethod.wireValue}, '
                          '${event.confidence.wireValue}'
                    : 'Built on the device: no link ID, data or campaign. '
                          'The timeline on the Debug screen shows why '
                          '/v1/sdk/open failed.',
                style: TextStyle(
                  color: resolved
                      ? colors.onPrimaryContainer
                      : colors.onErrorContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: 'Link',
            children: <Widget>[
              InfoRow(
                label: 'Received by the app at (local time)',
                value: link.receivedAt.toString(),
              ),
              LinkEventDetails(event: event),
            ],
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: 'LinkEvent JSON',
            children: <Widget>[JsonBlock(value: event.toJson())],
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: 'Route',
            children: <Widget>[
              SectionNote(
                location == null
                    ? 'This app has no screen for ${event.path}; a real app '
                          'would open its home screen.'
                    : 'This app routes ${event.path} to $location.',
              ),
              if (location != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Open that screen'),
                    onPressed: () => context.go(location, extra: event),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
