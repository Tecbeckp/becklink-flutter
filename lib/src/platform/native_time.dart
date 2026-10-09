/// Reading instants the native layer sends over the platform channel.
/// Internal to the SDK.
library;

/// Largest magnitude [DateTime] supports, in milliseconds since the epoch.
const int _maxEpochMilliseconds = 8640000000000000;

/// The UTC instant [value] milliseconds after the Unix epoch, or `null` when
/// [value] is not a positive integer [DateTime] can hold (a missing or
/// unknown time).
DateTime? dateTimeFromEpochMilliseconds(Object? value) {
  if (value is! int || value <= 0 || value > _maxEpochMilliseconds) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

/// The UTC instant [value] seconds after the Unix epoch, or `null` when
/// [value] is not a positive integer [DateTime] can hold. Play's install
/// referrer reports `0` for a time it does not know.
DateTime? dateTimeFromEpochSeconds(Object? value) {
  if (value is! int || value <= 0 || value > _maxEpochMilliseconds ~/ 1000) {
    return null;
  }
  return dateTimeFromEpochMilliseconds(value * 1000);
}
