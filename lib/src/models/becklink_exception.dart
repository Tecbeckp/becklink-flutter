import 'package:meta/meta.dart';

import 'becklink_error_code.dart';

/// An error reported by the Beck Link SDK, identified by a stable [code].
///
/// Branch on [code], not on [message]: messages are written for developers
/// and may change between versions. Messages never contain API keys, user
/// IDs or other personal data, so the exception is safe to log and to send
/// to crash reporting.
///
/// Mistakes in the arguments of an SDK call (for example a too large
/// `LinkOptions.data`) are programming errors and throw an [ArgumentError]
/// instead.
@immutable
final class BeckLinkException implements Exception {
  /// Creates an exception with [code] and [message].
  ///
  /// [message] must not contain API keys or personal data.
  const BeckLinkException(
    this.code,
    this.message, {
    this.statusCode,
    this.retryAfter,
    this.requestId,
  });

  /// A method was called before `BeckLink.instance.configure()` completed,
  /// or after it failed.
  const BeckLinkException.notConfigured()
      : this(
          BeckLinkErrorCode.notConfigured,
          'Call BeckLink.instance.configure() and wait for it to complete '
          'before using the SDK.',
        );

  /// The API key was refused, locally (not a publishable key) or by the
  /// service ([statusCode] 401 or 403).
  const BeckLinkException.invalidKey({
    String message = 'The API key is not valid. Use the publishable key '
        '(pk_test_… or pk_live_…) of your project environment.',
    int? statusCode,
    String? requestId,
  }) : this(
          BeckLinkErrorCode.invalidKey,
          message,
          statusCode: statusCode,
          requestId: requestId,
        );

  /// The service could not be reached, or kept failing until the retry
  /// budget ran out ([statusCode] set when it answered with an error).
  const BeckLinkException.network({
    String message = 'The Beck Link API could not be reached. Check the '
        'connection and try again.',
    int? statusCode,
    String? requestId,
  }) : this(
          BeckLinkErrorCode.network,
          message,
          statusCode: statusCode,
          requestId: requestId,
        );

  /// The service still answered 429 after the retry budget ran out.
  /// [retryAfter] is the wait the service asked for, when it named one.
  const BeckLinkException.rateLimited({
    Duration? retryAfter,
    String? requestId,
  }) : this(
          BeckLinkErrorCode.rateLimited,
          'Too many requests to the Beck Link API. Try again later.',
          statusCode: 429,
          retryAfter: retryAfter,
          requestId: requestId,
        );

  /// The operation needs tracking, which `setTrackingEnabled(false)` turned
  /// off.
  const BeckLinkException.trackingDisabled()
      : this(
          BeckLinkErrorCode.trackingDisabled,
          'Tracking is disabled with setTrackingEnabled(false), so this '
          'operation is not available.',
        );

  /// The service answered 404: the URL is not an active link of this
  /// project environment.
  const BeckLinkException.linkNotFound({
    String message = 'The URL is not an active link of this project '
        'environment. Check that the API key belongs to the same environment '
        '(test or live) as the link.',
    String? requestId,
  }) : this(
          BeckLinkErrorCode.linkNotFound,
          message,
          statusCode: 404,
          requestId: requestId,
        );

  /// The service did not answer before the client deadline ([statusCode]
  /// 408 when the service or a proxy reported the timeout).
  const BeckLinkException.timeout({int? statusCode, String? requestId})
      : this(
          BeckLinkErrorCode.timeout,
          'The Beck Link API did not answer in time.',
          statusCode: statusCode,
          requestId: requestId,
        );

  /// The service rejected the request as invalid ([statusCode] 400, 404,
  /// 405, 413, 415 or 422).
  const BeckLinkException.invalidRequest({
    String message = 'The Beck Link API rejected the request as invalid.',
    int? statusCode,
    String? requestId,
  }) : this(
          BeckLinkErrorCode.invalidRequest,
          message,
          statusCode: statusCode,
          requestId: requestId,
        );

  /// The stable error code to branch on.
  final BeckLinkErrorCode code;

  /// A developer-facing description; never contains API keys or personal
  /// data.
  final String message;

  /// The HTTP status of the service's answer, or `null` when the error
  /// happened on the device or before an answer arrived.
  final int? statusCode;

  /// How long the service asked the client to wait before trying again
  /// (`Retry-After`), or `null` when it named no wait.
  final Duration? retryAfter;

  /// The service's request ID (`X-Request-Id`), to quote when contacting
  /// support, or `null` when no answer arrived.
  final String? requestId;

  @override
  bool operator ==(Object other) =>
      other is BeckLinkException &&
      other.code == code &&
      other.message == message &&
      other.statusCode == statusCode &&
      other.retryAfter == retryAfter &&
      other.requestId == requestId;

  @override
  int get hashCode =>
      Object.hash(code, message, statusCode, retryAfter, requestId);

  @override
  String toString() {
    final buffer = StringBuffer('BeckLinkException(${code.wireValue}');
    final status = statusCode;
    if (status != null) buffer.write(', status: $status');
    final wait = retryAfter;
    if (wait != null) buffer.write(', retryAfter: ${wait.inSeconds}s');
    final id = requestId;
    if (id != null) buffer.write(', requestId: $id');
    buffer.write('): $message');
    return buffer.toString();
  }
}
