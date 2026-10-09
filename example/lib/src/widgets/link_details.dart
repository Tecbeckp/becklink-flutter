import 'dart:convert';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';

import 'info_section.dart';

const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

/// Every field of a [LinkEvent]. Its values come from the link, so they are
/// shown as plain text only.
class LinkEventDetails extends StatelessWidget {
  const LinkEventDetails({super.key, required this.event});

  final LinkEvent event;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      InfoRow(label: 'URL', value: event.url.toString(), monospace: true),
      InfoRow(label: 'Deep-link path', value: event.path, monospace: true),
      InfoRow(
        label: 'Deferred (matched after install)',
        value: event.isDeferred ? 'Yes' : 'No, opened the installed app',
      ),
      InfoRow(label: 'Match method', value: event.matchMethod.wireValue),
      InfoRow(label: 'Confidence', value: event.confidence.wireValue),
      InfoRow(
        label: 'Link ID',
        value:
            event.linkId ??
            'None: built on the device because the service could not '
                'be reached (no data, no campaign)',
        monospace: event.linkId != null,
      ),
      InfoRow(
        label: event.isDeferred ? 'Clicked at (UTC)' : 'Opened at (UTC)',
        value: event.clickedAt.toIso8601String(),
      ),
      InfoRow(label: 'Campaign', value: describeCampaign(event.campaign)),
      InfoRow(
        label: 'Params',
        value: event.params.isEmpty
            ? 'None'
            : _prettyJson.convert(event.params),
        monospace: event.params.isNotEmpty,
      ),
      InfoRow(
        label: 'Data',
        value: event.data.isEmpty ? 'None' : _prettyJson.convert(event.data),
        monospace: event.data.isNotEmpty,
      ),
    ],
  );
}

/// Every field of an [Attribution].
class AttributionDetails extends StatelessWidget {
  const AttributionDetails({super.key, required this.attribution});

  final Attribution attribution;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      InfoRow(label: 'State', value: attribution.state.wireValue),
      InfoRow(
        label: 'Match method',
        value: attribution.matchMethod?.wireValue ?? 'None',
      ),
      InfoRow(
        label: 'Confidence',
        value: attribution.confidence?.wireValue ?? 'None',
      ),
      InfoRow(
        label: 'Link ID',
        value: attribution.linkId ?? 'None',
        monospace: attribution.linkId != null,
      ),
      InfoRow(label: 'Campaign', value: describeCampaign(attribution.campaign)),
      InfoRow(
        label: 'Installed at (UTC)',
        value: attribution.installedAt.toIso8601String(),
      ),
    ],
  );
}

/// The set fields of [campaign], one per line, or `None`.
String describeCampaign(Campaign? campaign) {
  if (campaign == null) return 'None';
  final fields = <String, String?>{
    'name': campaign.name,
    'source': campaign.source,
    'medium': campaign.medium,
    'content': campaign.content,
    'term': campaign.term,
    'creative': campaign.creative,
  };
  final lines = <String>[
    for (final MapEntry(:key, :value) in fields.entries)
      if (value != null) '$key: $value',
  ];
  return lines.isEmpty ? 'None' : lines.join('\n');
}
