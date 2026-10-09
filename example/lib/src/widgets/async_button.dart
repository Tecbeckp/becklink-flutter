import 'package:flutter/material.dart';

/// How prominent an [AsyncButton] is.
enum AsyncButtonKind {
  filled,
  tonal,
  outlined,

  /// For an action that deletes data.
  destructive,
}

/// A button that runs an asynchronous action, shows progress while it runs
/// and cannot be pressed again until it finished. Disabled when [onPressed]
/// is `null`.
class AsyncButton extends StatefulWidget {
  const AsyncButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.kind = AsyncButtonKind.tonal,
  });

  final String label;
  final IconData icon;
  final Future<void> Function()? onPressed;
  final AsyncButtonKind kind;

  @override
  State<AsyncButton> createState() => _AsyncButtonState();
}

class _AsyncButtonState extends State<AsyncButton> {
  bool _running = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _running = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.onPressed;
    final onPressed = action == null || _running ? null : () => _run(action);
    final icon = _running
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(widget.icon);
    final label = Text(widget.label);
    switch (widget.kind) {
      case AsyncButtonKind.filled:
        return FilledButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
      case AsyncButtonKind.tonal:
        return FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
      case AsyncButtonKind.outlined:
        return OutlinedButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
      case AsyncButtonKind.destructive:
        final colors = Theme.of(context).colorScheme;
        return FilledButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: label,
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
        );
    }
  }
}
