/// How much the SDK writes to the debug console.
///
/// Levels are ordered: each level includes the messages of the levels before
/// it. Logs never contain API keys or user IDs at any level.
///
/// [wireValue] is the snake_case form used by the Beck Link SDK API.
enum LogLevel {
  /// Nothing is logged.
  none('none'),

  /// Only failures are logged. The default.
  error('error'),

  /// Failures and lifecycle milestones, such as a received link or a sent
  /// event batch.
  info('info'),

  /// Everything, including request summaries, for troubleshooting.
  debug('debug');

  const LogLevel(this.wireValue);

  /// The snake_case value used in SDK API JSON, for example `error`.
  final String wireValue;

  /// The level whose [wireValue] is [value], or `null` when this SDK version
  /// does not know [value].
  ///
  /// `null` lets remote config keep the app's own level instead of guessing.
  static LogLevel? tryFromWire(String value) {
    for (final level in values) {
      if (level.wireValue == value) return level;
    }
    return null;
  }
}
