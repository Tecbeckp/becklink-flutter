import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One line the SDK wrote to its log.
@immutable
class SdkLogLine {
  const SdkLogLine({
    required this.time,
    required this.level,
    required this.message,
  });

  /// When the app received the line, in local time.
  final DateTime time;

  /// `ERROR`, `INFO` or `DEBUG`.
  final String level;

  final String message;
}

/// The SDK's recent log lines, for the Debug screen.
///
/// The SDK writes its log through `debugPrint` as `[BeckLink] LEVEL: …`,
/// already redacted (no API keys or user IDs). This buffer wraps
/// `debugPrint` and keeps a copy of those lines; every line still reaches
/// the console.
class SdkLogBuffer extends ChangeNotifier {
  SdkLogBuffer({this.capacity = 200});

  /// Most lines kept; older ones are dropped.
  final int capacity;

  static const String _prefix = '[BeckLink] ';

  final ListQueue<SdkLogLine> _lines = ListQueue<SdkLogLine>();
  bool _notifyScheduled = false;

  /// The kept lines, newest first.
  List<SdkLogLine> get newestFirst => _lines.toList().reversed.toList();

  /// Starts keeping the SDK's lines. Call once, before `configure()`.
  void captureDebugPrint() {
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith(_prefix)) {
        _add(message.substring(_prefix.length));
      }
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// Forgets the kept lines.
  void clear() {
    _lines.clear();
    notifyListeners();
  }

  void _add(String text) {
    final separator = text.indexOf(': ');
    _lines.addLast(
      SdkLogLine(
        time: DateTime.now(),
        level: separator > 0 ? text.substring(0, separator) : '',
        message: separator > 0 ? text.substring(separator + 2) : text,
      ),
    );
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    // The SDK may log while a frame is being built; telling listeners after
    // the current work never marks a widget dirty in the middle of a build.
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
