import 'package:flutter/foundation.dart';

import '../models/log_level.dart';
import 'redact_secrets.dart';

/// Receives every log message the [SdkLogger] lets through, already
/// redacted.
typedef LogSink = void Function(LogLevel level, String message);

/// The SDK's internal logger: drops messages above the current [level] and
/// redacts secrets from the rest before they reach the [LogSink].
///
/// Callers still must never pass API keys, request bodies or user IDs
/// (contract section 12); [redactSecrets] is only a safety net. Internal to
/// the SDK.
final class SdkLogger {
  /// Creates a logger that writes messages up to [level] to [sink], by
  /// default the debug console.
  SdkLogger({this.level = LogLevel.error, LogSink? sink})
      : _sink = sink ?? _printToConsole;

  /// The most detailed level that is written; [LogLevel.none] silences the
  /// logger.
  LogLevel level;

  final LogSink _sink;

  /// Whether a message at [messageLevel] would be written, so callers can
  /// skip building expensive messages.
  bool isEnabled(LogLevel messageLevel) =>
      messageLevel != LogLevel.none && _rank(messageLevel) <= _rank(level);

  /// Logs a failure. [error] is appended to the message.
  void error(String message, [Object? error]) =>
      _write(LogLevel.error, message, error);

  /// Logs a lifecycle milestone. [error] is appended to the message.
  void info(String message, [Object? error]) =>
      _write(LogLevel.info, message, error);

  /// Logs a troubleshooting detail. [error] is appended to the message.
  void debug(String message, [Object? error]) =>
      _write(LogLevel.debug, message, error);

  void _write(LogLevel messageLevel, String message, Object? error) {
    if (!isEnabled(messageLevel)) return;
    final text = error == null ? message : '$message: $error';
    _sink(messageLevel, redactSecrets(text));
  }

  // An explicit order instead of LogLevel.index, so reordering the public
  // enum can never change which messages are written.
  static int _rank(LogLevel level) => switch (level) {
        LogLevel.none => 0,
        LogLevel.error => 1,
        LogLevel.info => 2,
        LogLevel.debug => 3,
      };

  static void _printToConsole(LogLevel level, String message) =>
      debugPrint('[BeckLink] ${level.wireValue.toUpperCase()}: $message');
}
