import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../demo_state.dart';
import '../../widgets/async_button.dart';
import '../../widgets/feedback.dart';
import '../../widgets/info_section.dart';
import '../../widgets/json_block.dart';
import '../../widgets/link_details.dart';

/// The SDK version, environment, server and install, from
/// `getDiagnostics()`.
class SdkStateSection extends StatelessWidget {
  const SdkStateSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demo,
    builder: (context, _) {
      final diagnostics = demo.diagnostics;
      final error = demo.diagnosticsError;
      return InfoSection(
        title: 'SDK and install',
        trailing: IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: demo.isConfigured ? demo.refreshDiagnostics : null,
        ),
        children: <Widget>[
          InfoRow(label: 'SDK version', value: BeckLink.version),
          if (error != null) SectionNote('Diagnostics failed: $error'),
          if (diagnostics == null)
            SectionNote(
              demo.isConfigured
                  ? 'Waiting for the SDK to open its storage…'
                  : 'Configure the SDK to see its state.',
            )
          else ...<Widget>[
            InfoRow(label: 'Environment', value: diagnostics.environment),
            InfoRow(
              label: 'SDK API',
              value: diagnostics.apiBaseUrl.toString(),
              monospace: true,
            ),
            if (diagnostics.apiKeyRejected)
              const SectionNote(
                'The service refused the API key (401): nothing is sent '
                'until a valid key is configured.',
              ),
            InfoRow(
              label: 'Install ID',
              value:
                  diagnostics.installId ??
                  'None (tracking off, or the install was just reset)',
              monospace: diagnostics.installId != null,
            ),
            if (diagnostics.installCreatedAt != null)
              InfoRow(
                label: 'Install ID created at (UTC)',
                value: diagnostics.installCreatedAt!.toIso8601String(),
              ),
            InfoRow(
              label: 'Tracking',
              value: diagnostics.trackingEnabled ? 'On' : 'Off',
            ),
            InfoRow(
              label: 'User ID',
              value: diagnostics.hasUserId ? 'Set' : 'Not set',
            ),
            InfoRow(
              label: 'Queued events',
              value: '${diagnostics.queuedEvents}',
            ),
          ],
        ],
      );
    },
  );
}

/// Init result: the remote config (with `link_hosts`) and the last
/// `/v1/sdk/init` request.
class InitSection extends StatelessWidget {
  const InitSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[demo, demo.activity]),
    builder: (context, _) {
      final diagnostics = demo.diagnostics;
      final config = diagnostics?.remoteConfig;
      final lastInit = demo.activity.lastCallTo('/v1/sdk/init');
      return InfoSection(
        title: 'Init and remote config',
        children: <Widget>[
          ApiCallRow(label: 'Last /v1/sdk/init', call: lastInit),
          if (lastInit == null)
            const SectionNote(
              'The first run sends the first open instead of init; later '
              'launches send init once per session.',
            ),
          if (config != null) ...<Widget>[
            InfoRow(
              label: 'Remote config source',
              value: diagnostics!.remoteConfigReceived
                  ? 'From the service (first open or init)'
                  : 'SDK defaults: none received yet',
            ),
            InfoRow(
              label: 'link_hosts',
              value: config.linkHosts.isEmpty
                  ? 'None'
                  : config.linkHosts.join('\n'),
              monospace: config.linkHosts.isNotEmpty,
            ),
            JsonBlock(label: 'config', value: config.toJson()),
          ],
        ],
      );
    },
  );
}

/// The first open: status, matched link, `unmatched_reason`, the last
/// `/v1/sdk/first-open` request, and Re-run first open.
class FirstOpenSection extends StatelessWidget {
  const FirstOpenSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[demo, demo.activity]),
    builder: (context, _) {
      final diagnostics = demo.diagnostics;
      final event = diagnostics?.firstOpenLinkEvent;
      final reason = diagnostics?.unmatchedReason;
      return InfoSection(
        title: 'First open (deferred deep link)',
        children: <Widget>[
          ApiCallRow(
            label: 'Last /v1/sdk/first-open',
            call: demo.activity.lastCallTo('/v1/sdk/first-open'),
          ),
          if (diagnostics != null) ...<Widget>[
            InfoRow(
              label: 'Status',
              value: diagnostics.firstOpenStatus.wireValue,
            ),
            if (diagnostics.firstOpenCompletedAt != null)
              InfoRow(
                label: 'Answered at (UTC)',
                value: diagnostics.firstOpenCompletedAt!.toIso8601String(),
              ),
            if (diagnostics.firstOpenStatus == FirstOpenStatus.completed)
              InfoRow(
                label: 'Result',
                value: event == null
                    ? 'No link matched'
                          '${reason == null ? '' : ' (unmatched_reason: $reason)'}'
                    : 'Matched ${event.path}: '
                          'matchMethod ${event.matchMethod.wireValue}, '
                          'confidence ${event.confidence.wireValue}'
                          '${event.isDeferred ? ' (deferred)' : ' (the launch link)'}',
              ),
            if (event != null)
              JsonBlock(label: 'link_event', value: event.toJson()),
          ],
          if (kDebugMode) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AsyncButton(
                label: 'Re-run first open',
                icon: Icons.replay,
                onPressed: demo.isConfigured
                    ? () => runWithFeedback(context, demo.runFirstOpen)
                    : null,
              ),
            ),
            const SectionNote(
              'Runs only when the first open has not succeeded yet: reset '
              'the install first. The install referrer and the pasteboard '
              'are read once per app process, so for those restart the app '
              'after the reset instead.',
            ),
          ],
        ],
      );
    },
  );
}

/// The last link that opened the installed app (re-engagement) and its
/// `/v1/sdk/open` request.
class LastOpenSection extends StatelessWidget {
  const LastOpenSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[demo, demo.activity]),
    builder: (context, _) {
      final open = demo.lastOpen;
      return InfoSection(
        title: 'Last open (re-engagement)',
        children: <Widget>[
          ApiCallRow(
            label: 'Last /v1/sdk/open',
            call: demo.activity.lastCallTo('/v1/sdk/open'),
          ),
          if (open == null)
            const SectionNote(
              'No link opened the installed app yet. Open a link (or paste '
              'one below) to see what /v1/sdk/open resolved.',
            )
          else ...<Widget>[
            InfoRow(
              label: 'Received at (local time)',
              value: open.receivedAt.toString(),
            ),
            InfoRow(
              label: 'URL',
              value: open.event.url.toString(),
              monospace: true,
            ),
            InfoRow(
              label: 'Resolved',
              value: open.event.linkId == null
                  ? 'No: built on the device (no data). See the timeline.'
                  : '${open.event.path} · ${open.event.matchMethod.wireValue}'
                        ' · ${open.event.confidence.wireValue}',
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => context.go('/links/${open.id}', extra: open),
                child: const Text('Show the payload'),
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// Every link `onLink` delivered in this session.
class IncomingLinksSection extends StatelessWidget {
  const IncomingLinksSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demo,
    builder: (context, _) {
      final links = demo.incomingLinks.reversed.toList();
      return InfoSection(
        title: 'Incoming links (${links.length})',
        children: <Widget>[
          if (links.isEmpty)
            const SectionNote('No link yet.')
          else
            for (final link in links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: SelectableText(
                  link.event.url.toString(),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                subtitle: Text(
                  '${link.event.isDeferred ? 'deferred · ' : ''}'
                  '${link.event.path} · ${link.event.matchMethod.wireValue} · '
                  '${link.receivedAt}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/links/${link.id}', extra: link),
              ),
        ],
      );
    },
  );
}

/// The newest link `onLink` delivered, with every field.
class LastLinkSection extends StatelessWidget {
  const LastLinkSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demo,
    builder: (context, _) {
      final link = demo.lastLink;
      final receivedAt = demo.lastLinkReceivedAt;
      return InfoSection(
        title: 'Last link',
        children: <Widget>[
          if (link == null)
            const SectionNote(
              'No link yet. Open a link of your project to see every '
              'field of its LinkEvent here.',
            )
          else ...<Widget>[
            if (receivedAt != null)
              InfoRow(
                label: 'Received by the app at (local time)',
                value: receivedAt.toString(),
              ),
            LinkEventDetails(event: link),
          ],
        ],
      );
    },
  );
}

/// The install's attribution, as `onAttribution` reports it.
class AttributionSection extends StatelessWidget {
  const AttributionSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demo,
    builder: (context, _) {
      final attribution = demo.attribution;
      return InfoSection(
        title: 'Install attribution',
        children: <Widget>[
          if (attribution == null)
            SectionNote(
              demo.isConfigured
                  ? 'Not reported yet: the first open is on its way.'
                  : 'Configure the SDK to see attribution.',
            )
          else
            AttributionDetails(attribution: attribution),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AsyncButton(
              label: 'Ask the SDK again',
              icon: Icons.refresh,
              kind: AsyncButtonKind.outlined,
              onPressed: demo.isConfigured
                  ? () => runWithFeedback(context, demo.refreshAttribution)
                  : null,
            ),
          ),
        ],
      );
    },
  );
}

/// One request record: status, duration, request ID, replay.
class ApiCallRow extends StatelessWidget {
  const ApiCallRow({super.key, required this.label, required this.call});

  final String label;
  final BeckLinkApiCall? call;

  @override
  Widget build(BuildContext context) {
    final call = this.call;
    if (call == null) {
      return InfoRow(label: label, value: 'Not sent in this session');
    }
    final status = call.statusCode?.toString() ?? 'no answer';
    return InfoRow(
      label: label,
      value: <String>[
        'HTTP $status in ${call.duration.inMilliseconds} ms'
            '${call.attempt > 1 ? ' (attempt ${call.attempt})' : ''}',
        if (call.errorCode != null) 'error: ${call.errorCode!.wireValue}',
        if (call.requestId != null) 'request ID: ${call.requestId}',
        if (call.idempotentReplayed) 'Idempotent-Replayed: true',
        'at ${call.startedAt.toIso8601String()}',
      ].join('\n'),
      monospace: true,
    );
  }
}
