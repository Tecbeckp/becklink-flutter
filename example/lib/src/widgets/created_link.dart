import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'json_block.dart';

/// A link the app created, with buttons to copy, share and open it.
class CreatedLink extends StatelessWidget {
  const CreatedLink({super.key, required this.url});

  final String url;

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(text: url));
  }

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    // Opened outside the app, as a user would: with a verified App Link the
    // system hands it straight back to this app.
    final opened =
        uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('No app can open it')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SelectableText(
            url,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          Wrap(
            spacing: 4,
            children: <Widget>[
              TextButton.icon(
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy'),
                onPressed: () =>
                    copyWithFeedback(context, url, what: 'Link copied'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share'),
                onPressed: _share,
              ),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
                onPressed: () => _open(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
