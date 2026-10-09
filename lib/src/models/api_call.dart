import 'package:meta/meta.dart';

import 'becklink_error_code.dart';

/// One attempt of a request the SDK sent to the Beck Link SDK API, for
/// debug and diagnostics screens (see `BeckLink.onApiCall`).
///
/// Holds no API key, no request or response body, no idempotency key and
/// no user or install ID: only what helps to follow a request through the
/// server logs.
@immutable
final class BeckLinkApiCall {
  /// Creates a record; [startedAt] is converted to UTC.
  BeckLinkApiCall({
    required this.method,
    required this.path,
    required this.attempt,
    required DateTime startedAt,
    required this.duration,
    this.statusCode,
    this.requestId,
    this.idempotentReplayed = false,
    this.errorCode,
  }) : startedAt = startedAt.toUtc();

  /// The HTTP method, `POST` for every SDK API call.
  final String method;

  /// The path below the API base URL, for example `/v1/sdk/open`.
  final String path;

  /// 1 for the first attempt, higher for retries of the same request (they
  /// carry the same idempotency key and body).
  final int attempt;

  /// When the attempt was sent, in UTC.
  final DateTime startedAt;

  /// How long the attempt took until the answer was read, or until it was
  /// given up (timeout, no connection).
  final Duration duration;

  /// The HTTP status, or `null` when no answer arrived (no connection,
  /// timeout).
  final int? statusCode;

  /// The service's `X-Request-Id`, to find the request in the server logs.
  final String? requestId;

  /// Whether the service replayed a stored answer (`Idempotent-Replayed:
  /// true`, contract section 6) instead of running the request again.
  final bool idempotentReplayed;

  /// What the attempt failed with, or `null` when it succeeded. A failed
  /// attempt may still be retried; a later record with a higher [attempt]
  /// shows the retry.
  final BeckLinkErrorCode? errorCode;

  /// Whether the service answered with a 2xx status and a readable body.
  bool get succeeded => errorCode == null;

  /// A JSON form for debug reports.
  Map<String, Object?> toJson() => <String, Object?>{
        'method': method,
        'path': path,
        'attempt': attempt,
        'started_at': startedAt.toIso8601String(),
        'duration_ms': duration.inMilliseconds,
        'status_code': statusCode,
        'request_id': requestId,
        'idempotent_replayed': idempotentReplayed,
        'error_code': errorCode?.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      other is BeckLinkApiCall &&
      other.method == method &&
      other.path == path &&
      other.attempt == attempt &&
      other.startedAt == startedAt &&
      other.duration == duration &&
      other.statusCode == statusCode &&
      other.requestId == requestId &&
      other.idempotentReplayed == idempotentReplayed &&
      other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(
        method,
        path,
        attempt,
        startedAt,
        duration,
        statusCode,
        requestId,
        idempotentReplayed,
        errorCode,
      );

  @override
  String toString() => 'BeckLinkApiCall($method $path #$attempt: '
      '${statusCode ?? 'no answer'} in ${duration.inMilliseconds} ms'
      '${requestId == null ? '' : ', request $requestId'}'
      '${idempotentReplayed ? ', replayed' : ''}'
      '${errorCode == null ? '' : ', ${errorCode!.wireValue}'})';
}
