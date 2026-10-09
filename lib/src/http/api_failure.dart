import 'package:meta/meta.dart';

import '../models/becklink_error_code.dart';
import '../models/becklink_exception.dart';
import '../util/single_line.dart';
import 'api_problem.dart';

/// An attempt that did not produce a usable answer: the exception to throw
/// when the client gives up, and whether another attempt may help.
///
/// Built by the pure functions below from the tables of contract sections
/// 10.2 (codes), 10.3 (mapping to `BeckLinkException`) and 11.2 (retry).
@immutable
final class ApiFailure {
  /// Creates a failure.
  const ApiFailure(
    this.exception, {
    required this.retryable,
    this.rejectsKey = false,
  });

  /// What the caller receives when no further attempt is made.
  final BeckLinkException exception;

  /// Whether a later attempt with the same body may succeed.
  final bool retryable;

  /// Whether the service refused the API key (`401`), after which the
  /// client makes no further calls until the SDK is configured again
  /// (contract section 11.2).
  final bool rejectsKey;

  /// The wait the service asked for (`Retry-After`), if any.
  Duration? get retryAfter => exception.retryAfter;
}

/// No answer arrived: no connection, DNS or TLS failure, or the connection
/// broke while the response was read.
ApiFailure connectionFailure() =>
    const ApiFailure(BeckLinkException.network(), retryable: true);

/// The client deadline of one attempt passed.
ApiFailure attemptTimeout() =>
    const ApiFailure(BeckLinkException.timeout(), retryable: true);

/// A success status whose body is not a JSON object, or a body too large to
/// be an SDK API answer.
///
/// Retryable, because the usual cause is a captive portal or proxy that
/// answers in place of the service (often with `200` and an HTML page).
ApiFailure unreadableResponse({required int statusCode, String? requestId}) =>
    ApiFailure(
      BeckLinkException.network(
        message: 'The Beck Link API answer could not be read (HTTP '
            '$statusCode). A captive portal or proxy may be in the way.',
        statusCode: statusCode,
        requestId: requestId,
      ),
      retryable: true,
    );

/// A JSON answer whose shape this SDK version cannot read: the response
/// reader threw a `MalformedJsonException` (a contract violation by the
/// service). [reason] is that exception's message, which names only a JSON
/// Pointer, never a value.
///
/// Mapped like a server fault (`network`, contract section 10.3 maps 5xx
/// there) and not retried: the service would send the same answer again.
ApiFailure incompatibleResponse({
  required int statusCode,
  required String reason,
  String? requestId,
}) =>
    ApiFailure(
      BeckLinkException.network(
        message: 'The Beck Link API answer does not match what this SDK '
            'version expects. $reason',
        statusCode: statusCode,
        requestId: requestId,
      ),
      retryable: false,
    );

/// An error status ([statusCode] not 2xx), mapped by the problem `code`
/// when [problem] has one this SDK version knows, otherwise by status.
ApiFailure classifyErrorResponse({
  required int statusCode,
  ApiProblem? problem,
  String? requestId,
  Duration? retryAfter,
}) {
  final failure = _Answer(statusCode, problem, requestId, retryAfter);
  final code = problem?.knownCode;
  return code == null ? failure.byStatus() : failure.byCode(code);
}

/// Longest server-provided text kept in an exception message.
const int _maxMessageLength = 500;

/// Field errors of a `422` listed in the message; the rest are counted.
const int _maxFieldErrors = 3;

final class _Answer {
  _Answer(this.statusCode, this.problem, this.requestId, this.retryAfter);

  final int statusCode;
  final ApiProblem? problem;
  final String? requestId;
  final Duration? retryAfter;

  ApiFailure byCode(ServerErrorCode code) => switch (code) {
        ServerErrorCode.invalidApiKey ||
        ServerErrorCode.insufficientScope =>
          _invalidKey(),
        ServerErrorCode.linkNotFound => ApiFailure(
            BeckLinkException.linkNotFound(
              message: _serverText() ??
                  const BeckLinkException.linkNotFound().message,
              requestId: requestId,
            ),
            retryable: false,
          ),
        ServerErrorCode.malformedRequest ||
        ServerErrorCode.idempotencyKeyRequired ||
        ServerErrorCode.notFound ||
        ServerErrorCode.methodNotAllowed ||
        ServerErrorCode.payloadTooLarge ||
        ServerErrorCode.unsupportedMediaType ||
        ServerErrorCode.validationFailed ||
        ServerErrorCode.idempotencyKeyReused =>
          _invalidRequest(),
        ServerErrorCode.requestTimeout => _timeout(),
        ServerErrorCode.rateLimited => _rateLimited(),
        // 409 means the first attempt with this Idempotency-Key is still
        // running, so a later attempt gets its stored answer.
        ServerErrorCode.idempotencyKeyInProgress ||
        ServerErrorCode.internalError ||
        ServerErrorCode.serviceUnavailable =>
          _serverFault(),
      };

  /// Mapping without a known problem code (a proxy answer, or a code added
  /// after this SDK version). Contract section 10.3 maps unknown codes by
  /// status class; the statuses with their own `BeckLinkException` code
  /// (401, 403, 408, 429) keep it.
  ApiFailure byStatus() {
    if (statusCode == 401 || statusCode == 403) return _invalidKey();
    if (statusCode == 408) return _timeout();
    if (statusCode == 429) return _rateLimited();
    if (statusCode >= 400 && statusCode < 500) return _invalidRequest();
    // 5xx, and anything else that is not an SDK API status (1xx, 3xx): the
    // service or something in front of it failed.
    return _serverFault();
  }

  ApiFailure _invalidKey() => ApiFailure(
        BeckLinkException.invalidKey(
          message: _serverText() ??
              (statusCode == 403
                  ? 'The API key lacks the scope this call needs, for '
                      'example sdk:links for createLink().'
                  : const BeckLinkException.invalidKey().message),
          statusCode: statusCode,
          requestId: requestId,
        ),
        retryable: false,
        rejectsKey: statusCode == 401,
      );

  ApiFailure _invalidRequest() => ApiFailure(
        BeckLinkException.invalidRequest(
          message: _serverText() ??
              'The Beck Link API rejected the request as invalid (HTTP '
                  '$statusCode).',
          statusCode: statusCode,
          requestId: requestId,
        ),
        retryable: false,
      );

  ApiFailure _timeout() => ApiFailure(
        BeckLinkException.timeout(
          statusCode: statusCode,
          requestId: requestId,
        ),
        retryable: true,
      );

  ApiFailure _rateLimited() => ApiFailure(
        BeckLinkException.rateLimited(
          retryAfter: retryAfter,
          requestId: requestId,
        ),
        retryable: true,
      );

  ApiFailure _serverFault() => ApiFailure(
        BeckLinkException(
          BeckLinkErrorCode.network,
          _serverText() ??
              'The Beck Link API is temporarily unavailable (HTTP '
                  '$statusCode). Try again later.',
          statusCode: statusCode,
          retryAfter: retryAfter,
          requestId: requestId,
        ),
        retryable: true,
      );

  /// The problem's explanation plus its field errors, cleaned for use in a
  /// message, or `null` when the answer has none.
  String? _serverText() {
    final answer = problem;
    if (answer == null) return null;
    final summary = answer.detail ?? answer.title;
    final fields = answer.fieldErrors;
    if (summary == null && fields.isEmpty) return null;
    final parts = <String>[
      if (summary != null) summary,
      ...fields.take(_maxFieldErrors),
      if (fields.length > _maxFieldErrors)
        '${fields.length - _maxFieldErrors} more field errors',
    ];
    return singleLine(parts.join('; '), maxLength: _maxMessageLength);
  }
}
