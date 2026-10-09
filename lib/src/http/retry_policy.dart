import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:meta/meta.dart';

/// How long to wait between attempts: exponential backoff with full jitter
/// (contract section 11.2, requirements §29.1).
///
/// The wait before retry number `n` (0 for the first retry) is a uniformly
/// random duration between zero and `min(maxDelay, baseDelay × 2^n)`. Full
/// jitter spreads the retries of many installs that failed at the same
/// moment, for example during an outage, so they do not return in waves.
@immutable
final class RetryPolicy {
  /// Creates a policy; the defaults are the contract's 2 s base and 5 min
  /// cap.
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
  });

  /// Upper bound of the first wait.
  final Duration baseDelay;

  /// Upper bound of every wait, and the longest `Retry-After` the client
  /// waits for before it gives up instead (see `ApiClient`).
  final Duration maxDelay;

  /// The jittered wait before retry number [retry] (0-based), drawn from
  /// [random].
  Duration backoff(int retry, Random random) {
    // A double power on purpose: pow() of two ints is an int, which wraps
    // past 2^63 (from retry 43 on, the wait would turn negative or zero and
    // the client would retry in a tight loop). A huge double power becomes
    // infinity, and min() turns that into the cap.
    final ceiling = min(
      maxDelay.inMicroseconds.toDouble(),
      baseDelay.inMicroseconds * pow(2.0, retry),
    );
    return Duration(microseconds: (random.nextDouble() * ceiling).floor());
  }
}

/// How long one logical request may keep retrying.
///
/// The request stops at whichever limit it reaches first; `null` means no
/// limit of that kind. Each endpoint has the contract's default budget
/// (section 11.2); callers can pass their own.
@immutable
final class RetryBudget {
  /// Creates a budget of at most [maxAttempts] attempts (including the
  /// first) within [maxElapsed] from the first attempt.
  const RetryBudget({this.maxAttempts, this.maxElapsed})
      : assert(
          maxAttempts == null || maxAttempts > 0,
          'maxAttempts must be at least 1',
        );

  /// Most attempts, the first one included; `null` for no limit.
  final int? maxAttempts;

  /// Longest time from the start of the first attempt until the last
  /// attempt must have finished; `null` for no limit.
  final Duration? maxElapsed;
}

final _deltaSeconds = RegExp(r'^\d{1,10}$');

/// Reads a `Retry-After` header value (RFC 9110 section 10.2.3): either
/// delay seconds or an HTTP date, which is converted to a delay from [now].
///
/// Returns `null` when [value] is missing or malformed, and [Duration.zero]
/// for a date in the past.
Duration? parseRetryAfter(String? value, DateTime now) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (_deltaSeconds.hasMatch(trimmed)) {
    return Duration(seconds: int.parse(trimmed));
  }
  final DateTime date;
  try {
    date = HttpDate.parse(trimmed);
    // Older Dart SDKs (3.6) can also throw a RangeError on some malformed
    // dates; the header comes from the network, so any failure means
    // "no usable value".
  } catch (_) {
    return null;
  }
  // HttpDate.parse accepts out-of-range fields (day 99, hour 99) and rolls
  // them over into a real date months away. Formatting the result back must
  // give the header again, otherwise it was not a date a server meant. This
  // keeps the preferred IMF-fixdate form (RFC 9110) and rejects the rest.
  if (HttpDate.format(date).toLowerCase() != trimmed.toLowerCase()) return null;
  final delay = date.difference(now);
  return delay.isNegative ? Duration.zero : delay;
}
