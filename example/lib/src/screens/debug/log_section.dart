import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';

import '../../activity_log.dart';
import '../../demo_state.dart';
import '../../sdk_log_buffer.dart';
import '../../widgets/info_section.dart';

/// The SDK's recent log lines and its log level.
class LogSection extends StatelessWidget {
  const LogSection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[demo, demo.logs]),
    builder: (context, _) {
      final lines = demo.logs.newestFirst;
      return InfoSection(
        title: 'SDK log',
        trailing: TextButton(
          onPressed: lines.isEmpty ? null : demo.logs.clear,
          child: const Text('Clear'),
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Log level',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // Scrolls instead of overflowing on narrow screens.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<LogLevel>(
              segments: <ButtonSegment<LogLevel>>[
                for (final level in LogLevel.values)
                  ButtonSegment<LogLevel>(
                    value: level,
                    label: Text(level.wireValue),
                    tooltip: 'Log level ${level.wireValue}',
                  ),
              ],
              selected: <LogLevel>{demo.logLevel},
              showSelectedIcon: false,
              onSelectionChanged: demo.isConfigured
                  ? (selection) => demo.setLogLevel(selection.first)
                  : null,
            ),
          ),
          const SectionNote(
            'Newest first. The project\'s remote config can override the '
            'level. The SDK never logs API keys or user IDs.',
          ),
          if (lines.isEmpty)
            const SectionNote('No log lines yet.')
          else
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final line in lines) _LogLineView(line: line),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class _LogLineView extends StatelessWidget {
  const _LogLineView({required this.line});

  final SdkLogLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final time = line.time;
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final clock =
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}:'
        '${twoDigits(time.second)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$clock  ${line.level}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: line.level == 'ERROR'
                  ? colors.error
                  : colors.onSurfaceVariant,
            ),
          ),
          Text(
            line.message,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

/// The debug timeline: every SDK request (status, request ID,
/// `Idempotent-Replayed`), every incoming link and every action taken here.
class ActivitySection extends StatelessWidget {
  const ActivitySection({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demo.activity,
    builder: (context, _) {
      final entries = demo.activity.newestFirst;
      return InfoSection(
        title: 'Timeline',
        trailing: TextButton(
          onPressed: entries.isEmpty ? null : demo.activity.clear,
          child: const Text('Clear'),
        ),
        children: <Widget>[
          const SectionNote(
            'Newest first. Requests come from BeckLink.onApiCall and never '
            'contain the API key or request bodies.',
          ),
          if (entries.isEmpty)
            const SectionNote('Nothing yet.')
          else
            // A bounded, scrolling list, so a long session does not make
            // the whole screen endless.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: Scrollbar(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (context, index) =>
                      _ActivityEntryView(entry: entries[index]),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _ActivityEntryView extends StatelessWidget {
  const _ActivityEntryView({required this.entry});

  final ActivityEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final icon = switch (entry.kind) {
      ActivityKind.request => Icons.swap_vert,
      ActivityKind.link => Icons.link,
      ActivityKind.action => Icons.touch_app_outlined,
    };
    final color = entry.isError ? colors.error : colors.onSurfaceVariant;
    final detail = entry.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${clockOf(entry.time)}  ${entry.title}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      color: entry.isError ? colors.error : null,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `HH:mm:ss.SSS` of [time].
String clockOf(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
}
