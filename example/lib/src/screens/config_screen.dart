import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/config_checks.dart';
import '../config/debug_config.dart';
import '../demo_state.dart';
import '../widgets/async_button.dart';
import '../widgets/feedback.dart';
import '../widgets/info_section.dart';

/// `/config`: where the SDK connects to and with which key. Saved on this
/// device and applied with `configure()` at once and on every launch.
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key, required this.demo});

  final DemoState demo;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late final DebugConfig _start = widget.demo.config ?? DebugConfig.initial;
  late final TextEditingController _apiBaseUrl = TextEditingController(
    text: _start.apiBaseUrl,
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: _start.apiKey,
  );
  late final TextEditingController _linkHosts = TextEditingController(
    text: _start.linkHosts.join('\n'),
  );
  late final TextEditingController _userId = TextEditingController(
    text: _start.userId,
  );
  late bool _enablePasteboard = _start.enablePasteboard;
  late LogLevel _logLevel = _start.logLevel;
  late bool _openEveryLinkInDetail = _start.openEveryLinkInDetail;
  bool _showKey = false;

  static const List<(String, String)> _presets = <(String, String)>[
    ('Production', DebugConfig.productionApiBaseUrl),
    ('USB: localhost:4100', 'http://localhost:4100'),
    ('Emulator: 10.0.2.2:4100', 'http://10.0.2.2:4100'),
    ('Wi-Fi: 192.168.x.x:4100', 'http://192.168.1.20:4100'),
  ];

  @override
  void initState() {
    super.initState();
    for (final controller in <TextEditingController>[
      _apiBaseUrl,
      _apiKey,
      _linkHosts,
      _userId,
    ]) {
      controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _apiBaseUrl.dispose();
    _apiKey.dispose();
    _linkHosts.dispose();
    _userId.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  DebugConfig get _draft => DebugConfig(
    apiBaseUrl: _apiBaseUrl.text.trim(),
    apiKey: _apiKey.text.trim(),
    linkHosts: parseLinkHosts(_linkHosts.text),
    userId: _userId.text.trim(),
    enablePasteboard: _enablePasteboard,
    logLevel: _logLevel,
    openEveryLinkInDetail: _openEveryLinkInDetail,
  );

  Future<String> _apply() async {
    final message = await widget.demo.applyConfig(_draft);
    // Shows or clears the configure() error below.
    if (mounted) setState(() {});
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final issues = checkConfig(draft);
    final configureError = widget.demo.configureError;
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(title: const Text('Configure')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (!kDebugMode)
            const _IssueCard(
              ConfigIssue(
                IssueSeverity.warning,
                'This is not a debug build: plain HTTP to your network, '
                'reset install, re-run first open and open-link testing are '
                'off. Build with flutter build apk --debug.',
              ),
            ),
          InfoSection(
            title: 'Beck Link server',
            children: <Widget>[
              gap,
              TextField(
                controller: _apiBaseUrl,
                decoration: const InputDecoration(
                  labelText: 'SDK API base URL (ingest)',
                  hintText: 'https://api.becklinks.com',
                  helperText:
                      'Origin only. Local server: the ingest port 4100, '
                      'through adb reverse, your LAN IP or an HTTPS tunnel.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final (label, url) in _presets)
                    ActionChip(
                      label: Text(label),
                      onPressed: () => _apiBaseUrl.text = url,
                    ),
                ],
              ),
              gap,
              TextField(
                controller: _apiKey,
                obscureText: !_showKey,
                decoration: InputDecoration(
                  labelText: 'Publishable key',
                  hintText: 'pk_test_…',
                  helperText:
                      'pk_test_… for test links, pk_live_… for live links. '
                      'Never a secret key (sk_…).',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _showKey ? 'Hide key' : 'Show key',
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
            ],
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: 'Links and user',
            children: <Widget>[
              gap,
              TextField(
                controller: _linkHosts,
                decoration: const InputDecoration(
                  labelText: 'Link hosts to test',
                  hintText: 'myshop-test.becklinks.com',
                  helperText:
                      'One per line. Also add each host to the Android '
                      'manifest and iOS Associated Domains (DEBUGGING.md).',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                minLines: 1,
                maxLines: 4,
              ),
              gap,
              TextField(
                controller: _userId,
                decoration: const InputDecoration(
                  labelText: 'User ID (optional)',
                  helperText:
                      'Set with setUserId() after initializing; empty '
                      'clears it. An internal ID, never an email address.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('iOS pasteboard deferred links'),
                subtitle: const Text(
                  'configure(enablePasteboard: true): read the click URL a '
                  'Beck Link page copied, once per install.',
                ),
                value: _enablePasteboard,
                onChanged: (value) => setState(() => _enablePasteboard = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show every link in the detail screen'),
                subtitle: const Text(
                  'Off: links route like in a real app (product, referral, '
                  'home).',
                ),
                value: _openEveryLinkInDetail,
                onChanged: (value) =>
                    setState(() => _openEveryLinkInDetail = value),
              ),
              const SizedBox(height: 4),
              Text(
                'SDK log level',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<LogLevel>(
                  segments: <ButtonSegment<LogLevel>>[
                    for (final level in LogLevel.values)
                      ButtonSegment<LogLevel>(
                        value: level,
                        label: Text(level.wireValue),
                      ),
                  ],
                  selected: <LogLevel>{_logLevel},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      setState(() => _logLevel = selection.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final issue in issues) _IssueCard(issue),
          if (configureError != null)
            _IssueCard(
              ConfigIssue(
                IssueSeverity.error,
                'The last configure() failed: $configureError',
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              AsyncButton(
                label: 'Save & initialize',
                icon: Icons.play_arrow_rounded,
                kind: AsyncButtonKind.filled,
                onPressed: canApply(issues)
                    ? () => runWithFeedback(context, _apply)
                    : null,
              ),
              AsyncButton(
                label: 'Delete saved configuration',
                icon: Icons.delete_outline,
                kind: AsyncButtonKind.outlined,
                onPressed: () =>
                    runWithFeedback(context, widget.demo.forgetConfig),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const SectionNote(
            'Initializing again applies a new key or server at once. A new '
            'install, and with it the first open, only starts after Debug → '
            'Reset install and a restart (or Re-run first open).',
          ),
        ],
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard(this.issue);

  final ConfigIssue issue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (issue.severity) {
      IssueSeverity.error => (
        colors.errorContainer,
        colors.onErrorContainer,
        Icons.error_outline,
      ),
      IssueSeverity.warning => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
        Icons.warning_amber_outlined,
      ),
      IssueSeverity.info => (
        colors.surfaceContainerHigh,
        colors.onSurfaceVariant,
        Icons.info_outline,
      ),
    };
    return Card(
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(issue.message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}
