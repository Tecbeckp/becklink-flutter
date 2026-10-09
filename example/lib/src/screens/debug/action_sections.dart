import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../demo_state.dart';
import '../../widgets/async_button.dart';
import '../../widgets/created_link.dart';
import '../../widgets/feedback.dart';
import '../../widgets/info_section.dart';
import '../../widgets/json_block.dart';

const InputDecoration _fieldDecoration = InputDecoration(
  border: OutlineInputBorder(),
);

const TextStyle _monospace = TextStyle(fontFamily: 'monospace');

/// Paste a link URL and open it as if the system had, and check what the
/// pasteboard holds for the iOS deferred flow.
class LinkToolsSection extends StatefulWidget {
  const LinkToolsSection({super.key, required this.demo});

  final DemoState demo;

  @override
  State<LinkToolsSection> createState() => _LinkToolsSectionState();
}

class _LinkToolsSectionState extends State<LinkToolsSection> {
  static const String _scheme = 'becklinkdebug';

  // A click URL the redirect page copies: https://{host}/_c/{ULID}.
  static final RegExp _clickUrl = RegExp(
    r'^https://([a-z0-9.-]+)/_c/([0-9A-HJKMNP-TV-Z]{26})$',
    caseSensitive: false,
  );

  final TextEditingController _url = TextEditingController();
  String? _pasteboard;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<String> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return 'The clipboard holds no text';
    _url.text = text;
    return 'Pasted';
  }

  /// The URL in the field wrapped into the custom-scheme form Beck Link
  /// pages use for "Open in app".
  void _asCustomScheme() {
    final link = _url.text.trim();
    if (link.isEmpty) return;
    _url.text = '$_scheme://becklink?url=${Uri.encodeQueryComponent(link)}';
  }

  Future<String> _checkPasteboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final String result;
    final match = _clickUrl.firstMatch(text);
    if (text.isEmpty) {
      result =
          'The pasteboard holds no text. On iOS, open a link of your '
          'project in Safari first and let its page copy the click URL.';
    } else if (match != null) {
      final host = match.group(1)!.toLowerCase();
      final hosts = widget.demo.config?.linkHosts ?? const <String>[];
      result =
          'A Beck Link click URL: host $host, click_id '
          '${match.group(2)!.toUpperCase()}.'
          '${hosts.isEmpty || hosts.contains(host) ? '' : ' Its host is not one of your configured link hosts.'}'
          ' With pasteboard deferred links on, the first open of a new '
          'install sends it (iOS): reset the install, restart the app.';
    } else {
      final uri = Uri.tryParse(text);
      // Other text is not shown: it may be anything the user copied.
      result = uri != null && uri.hasScheme && uri.host.isNotEmpty
          ? 'A URL on ${uri.host}, but not a click URL '
                '(https://{host}/_c/{click_id}).'
          : 'Text that is not a URL (${text.length} characters, not shown).';
    }
    if (mounted) setState(() => _pasteboard = result);
    return 'Pasteboard checked';
  }

  @override
  Widget build(BuildContext context) {
    final demo = widget.demo;
    final hosts = demo.config?.linkHosts ?? const <String>[];
    final pasteboard = _pasteboard;
    return InfoSection(
      title: 'Open a link',
      children: <Widget>[
        const SectionNote(
          'Hands the URL to the SDK as if Android or iOS had opened the app '
          'with it (debugOpenLink): the SDK resolves it through '
          '/v1/sdk/open and onLink delivers it.',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          style: _monospace,
          decoration: _fieldDecoration.copyWith(
            labelText: 'Link URL',
            hintText: 'https://myshop-test.becklinks.com/abc123',
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          minLines: 1,
          maxLines: 3,
        ),
        if (hosts.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final host in hosts)
                ActionChip(
                  label: Text('https://$host/…'),
                  onPressed: () => _url.text = 'https://$host/',
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            AsyncButton(
              label: 'Paste',
              icon: Icons.content_paste,
              kind: AsyncButtonKind.outlined,
              onPressed: () => runWithFeedback(context, _paste),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('As becklinkdebug://'),
              onPressed: _asCustomScheme,
            ),
            AsyncButton(
              label: 'Open',
              icon: Icons.login,
              kind: AsyncButtonKind.filled,
              onPressed: demo.isConfigured && kDebugMode
                  ? () =>
                        runWithFeedback(context, () => demo.openLink(_url.text))
                  : null,
            ),
          ],
        ),
        const Divider(height: 32),
        Text(
          'iOS pasteboard (deferred links)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SectionNote(
          'Reads the pasteboard like the SDK does on the first open of a new '
          'install. iOS asks to allow the paste. Only a click URL is shown.',
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AsyncButton(
            label: 'Check pasteboard',
            icon: Icons.assignment_outlined,
            kind: AsyncButtonKind.outlined,
            onPressed: () => runWithFeedback(context, _checkPasteboard),
          ),
        ),
        if (pasteboard != null) SectionNote(pasteboard),
      ],
    );
  }
}

/// Track a custom event (name and JSON properties), with or without the
/// user ID, and flush the queue.
class EventsSection extends StatefulWidget {
  const EventsSection({super.key, required this.demo});

  final DemoState demo;

  @override
  State<EventsSection> createState() => _EventsSectionState();
}

class _EventsSectionState extends State<EventsSection> {
  final TextEditingController _name = TextEditingController(
    text: 'debug_test_event',
  );
  final TextEditingController _properties = TextEditingController(
    text: '{"screen": "debug", "test": true}',
  );

  @override
  void dispose() {
    _name.dispose();
    _properties.dispose();
    super.dispose();
  }

  Future<String> _track({required bool withUserId}) => widget.demo
      .trackCustomEvent(_name.text, _properties.text, withUserId: withUserId);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.demo,
    builder: (context, _) {
      final demo = widget.demo;
      final configured = demo.isConfigured;
      final queued = demo.diagnostics?.queuedEvents;
      return InfoSection(
        title: 'Events',
        children: <Widget>[
          InfoRow(
            label: 'track() calls in this session · queued on the device',
            value: '${demo.trackedEvents} · ${queued ?? '?'}',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            style: _monospace,
            decoration: _fieldDecoration.copyWith(
              labelText: 'Event name',
              helperText: 'Lower-case letters, digits and _, up to 64.',
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _properties,
            style: _monospace,
            decoration: _fieldDecoration.copyWith(
              labelText: 'Properties (flat JSON object)',
            ),
            autocorrect: false,
            minLines: 1,
            maxLines: 5,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              AsyncButton(
                label: 'Track test event',
                icon: Icons.add_chart,
                kind: AsyncButtonKind.filled,
                onPressed: configured
                    ? () => runWithFeedback(
                        context,
                        () => _track(withUserId: false),
                      )
                    : null,
              ),
              AsyncButton(
                label: 'Track with user ID',
                icon: Icons.person_outline,
                onPressed: configured
                    ? () => runWithFeedback(
                        context,
                        () => _track(withUserId: true),
                      )
                    : null,
              ),
              AsyncButton(
                label: 'Flush now',
                icon: Icons.send_outlined,
                kind: AsyncButtonKind.outlined,
                onPressed: configured
                    ? () => runWithFeedback(context, demo.flush)
                    : null,
              ),
            ],
          ),
          const SectionNote(
            'Both track buttons flush right away, so the timeline shows the '
            '/v1/sdk/events answer. Events wait until the first open '
            'succeeded.',
          ),
        ],
      );
    },
  );
}

/// Create a link through the SDK (`sdk:links` scope) with a deep-link path
/// and data, then copy, share or open it.
class CreateLinkSection extends StatefulWidget {
  const CreateLinkSection({super.key, required this.demo});

  final DemoState demo;

  @override
  State<CreateLinkSection> createState() => _CreateLinkSectionState();
}

class _CreateLinkSectionState extends State<CreateLinkSection> {
  final TextEditingController _path = TextEditingController(
    text: '/product/123',
  );
  final TextEditingController _data = TextEditingController(
    text: '{"coupon": "DEBUG10"}',
  );
  String? _url;

  @override
  void dispose() {
    _path.dispose();
    _data.dispose();
    super.dispose();
  }

  Future<String> _create() async {
    final url = await widget.demo.createCustomLink(_path.text, _data.text);
    if (mounted) setState(() => _url = url);
    return 'Link created';
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return InfoSection(
      title: 'Create a link (SDK)',
      children: <Widget>[
        const SizedBox(height: 4),
        TextField(
          controller: _path,
          style: _monospace,
          decoration: _fieldDecoration.copyWith(labelText: 'Deep-link path'),
          autocorrect: false,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _data,
          style: _monospace,
          decoration: _fieldDecoration.copyWith(
            labelText: 'Data (JSON object, up to 4 KB)',
          ),
          autocorrect: false,
          minLines: 1,
          maxLines: 5,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AsyncButton(
            label: 'Create link',
            icon: Icons.add_link,
            kind: AsyncButtonKind.filled,
            onPressed: widget.demo.isConfigured
                ? () => runWithFeedback(context, _create)
                : null,
          ),
        ),
        if (url != null) CreatedLink(url: url),
        const SectionNote(
          'Uses the project\'s link domain and default redirects. Open it '
          'from another app to test the direct link, or uninstall first to '
          'test the deferred link.',
        ),
      ],
    );
  }
}

/// Everything on this screen as JSON, to paste to the developer.
class ReportSection extends StatelessWidget {
  const ReportSection({super.key, required this.demo});

  final DemoState demo;

  Future<String> _copy() async {
    await Clipboard.setData(ClipboardData(text: await demo.debugReport()));
    return 'Debug report copied';
  }

  Future<String> _share() async {
    await SharePlus.instance.share(
      ShareParams(text: await demo.debugReport(), subject: 'Beck Link debug'),
    );
    return 'Report shared';
  }

  @override
  Widget build(BuildContext context) => InfoSection(
    title: 'Debug report',
    children: <Widget>[
      const SectionNote(
        'Configuration (key and user ID masked), diagnostics, attribution, '
        'incoming links, the timeline with request IDs, and the SDK log.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          AsyncButton(
            label: 'Copy debug report',
            icon: Icons.copy_all_outlined,
            kind: AsyncButtonKind.filled,
            onPressed: () => runWithFeedback(context, _copy),
          ),
          AsyncButton(
            label: 'Share',
            icon: Icons.share_outlined,
            kind: AsyncButtonKind.outlined,
            onPressed: () => runWithFeedback(context, _share),
          ),
          AsyncButton(
            label: 'Preview',
            icon: Icons.visibility_outlined,
            kind: AsyncButtonKind.outlined,
            onPressed: () async {
              final report = await demo.debugReport();
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Debug report'),
                  content: SingleChildScrollView(
                    child: SelectableText(report, style: _monospace),
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => copyWithFeedback(
                        context,
                        report,
                        what: 'Debug report copied',
                      ),
                      child: const Text('Copy'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    ],
  );
}

/// Tracking consent and the user ID.
class PrivacySection extends StatefulWidget {
  const PrivacySection({super.key, required this.demo});

  final DemoState demo;

  @override
  State<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<PrivacySection> {
  late final TextEditingController _userId = TextEditingController(
    text: widget.demo.userId ?? 'demo_user_42',
  );

  @override
  void dispose() {
    _userId.dispose();
    super.dispose();
  }

  void _setTracking(Set<bool> selection) {
    // Tapping the selected choice again clears the selection; nothing to do.
    if (selection.isEmpty) return;
    unawaited(
      runWithFeedback(
        context,
        () => widget.demo.setTrackingEnabled(selection.first),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.demo,
    builder: (context, _) {
      final demo = widget.demo;
      final tracking = demo.trackingChoice;
      final configured = demo.isConfigured;
      return InfoSection(
        title: 'Consent and user',
        children: <Widget>[
          InfoRow(
            label: 'Tracking',
            value: switch (tracking) {
              null =>
                'Not changed in this session: the SDK applies the '
                    'stored choice (on unless the app turned it off).',
              true => 'On',
              false => 'Off: no events, no install ID; links still open.',
            },
          ),
          const SizedBox(height: 4),
          // Scrolls instead of overflowing at large text sizes.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: true,
                  label: Text('On'),
                  tooltip: 'Turn tracking on',
                  icon: Icon(Icons.visibility_outlined),
                ),
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Off'),
                  tooltip: 'Turn tracking off',
                  icon: Icon(Icons.visibility_off_outlined),
                ),
              ],
              selected: tracking == null ? <bool>{} : <bool>{tracking},
              emptySelectionAllowed: true,
              onSelectionChanged: configured ? _setTracking : null,
            ),
          ),
          const SectionNote(
            'Off deletes queued events and the install ID; on again, '
            'the device counts as a new install.',
          ),
          const Divider(height: 24),
          InfoRow(
            label: 'User ID',
            value: demo.userIdChanged
                ? demo.userId ?? 'Cleared'
                : 'Not changed in this session (the SDK keeps it across '
                      'restarts).',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _userId,
            decoration: const InputDecoration(
              labelText: 'User ID to set',
              helperText:
                  'Your internal ID, never an email address or '
                  'phone number.',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              AsyncButton(
                label: 'Set user ID',
                icon: Icons.person_outline,
                onPressed: configured
                    ? () => runWithFeedback(
                        context,
                        () => demo.setUserId(_userId.text.trim()),
                      )
                    : null,
              ),
              AsyncButton(
                label: 'Clear user ID',
                icon: Icons.person_off_outlined,
                kind: AsyncButtonKind.outlined,
                onPressed: configured
                    ? () => runWithFeedback(context, demo.clearUserId)
                    : null,
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// Debug builds only: start over as a new install to test deferred links.
class ResetInstallSection extends StatelessWidget {
  const ResetInstallSection({super.key, required this.demo});

  final DemoState demo;

  Future<void> _reset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset install?'),
        content: const Text(
          'Deletes the install ID, first-open result, user ID, tracking '
          'choice and queued events of this app, as on a new install.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await runWithFeedback(context, () async {
      await demo.resetInstall();
      return 'Install reset. Close the app completely and open it again, or '
          'use Re-run first open.';
    });
  }

  @override
  Widget build(BuildContext context) => InfoSection(
    title: 'Reset install (debug builds only)',
    children: <Widget>[
      const SectionNote(
        'To test a deferred link on iOS without reinstalling: 1. Reset '
        'install. 2. Close the app completely. 3. Open a link of your '
        'project in Safari and let its page copy the link. 4. Open the '
        'app: its first open finds the link and opens its screen. On '
        'Android a real deferred match needs an install from Google Play '
        '(internal testing); DEBUGGING.md explains how to test the '
        'referrer. A reset always runs the first open again.',
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: AsyncButton(
          label: 'Reset install',
          icon: Icons.restart_alt,
          kind: AsyncButtonKind.destructive,
          onPressed: demo.isConfigured ? () => _reset(context) : null,
        ),
      ),
    ],
  );
}
