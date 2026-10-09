import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

/// [value] as indented JSON.
String prettyJson(Object? value) => _prettyJson.convert(value);

/// Copies [text] to the clipboard and confirms it in a snack bar.
Future<void> copyWithFeedback(
  BuildContext context,
  String text, {
  String what = 'Copied',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(what)));
}

/// Selectable, monospace JSON on a tinted background, with a copy button.
class JsonBlock extends StatelessWidget {
  const JsonBlock({super.key, required this.value, this.label});

  /// Any JSON value.
  final Object? value;

  /// A caption above the block.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = prettyJson(value);
    final label = this.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (label != null)
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 4),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: <Widget>[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 12, 48, 12),
                  child: SelectableText(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  child: IconButton(
                    tooltip: 'Copy JSON',
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    onPressed: () =>
                        copyWithFeedback(context, text, what: 'JSON copied'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
