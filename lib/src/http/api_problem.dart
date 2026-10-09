import 'package:meta/meta.dart';

/// The problem `code` values the SDK API sends (contract section 10.2).
///
/// Codes this SDK version does not know are mapped by HTTP status instead,
/// so the server can add codes within `/v1`.
enum ServerErrorCode {
  /// 400: body is not valid UTF-8 JSON, broken gzip, or SDK headers missing.
  malformedRequest('malformed_request'),

  /// 400: `Idempotency-Key` missing where it is required.
  idempotencyKeyRequired('idempotency_key_required'),

  /// 401: key missing, malformed, unknown, revoked or not publishable.
  invalidApiKey('invalid_api_key'),

  /// 403: key lacks the `sdk` or `sdk:links` scope.
  insufficientScope('insufficient_scope'),

  /// 404: the URL is not an active link of this project environment.
  linkNotFound('link_not_found'),

  /// 404: unknown route.
  notFound('not_found'),

  /// 405: any method other than `POST`.
  methodNotAllowed('method_not_allowed'),

  /// 408: the body did not arrive in time.
  requestTimeout('request_timeout'),

  /// 409: a request with the same `Idempotency-Key` is still running.
  idempotencyKeyInProgress('idempotency_key_in_progress'),

  /// 413: body over the endpoint's limit.
  payloadTooLarge('payload_too_large'),

  /// 415: not JSON, or a `Content-Encoding` the endpoint does not accept.
  unsupportedMediaType('unsupported_media_type'),

  /// 422: schema or rule violation.
  validationFailed('validation_failed'),

  /// 422: same `Idempotency-Key` with a different body.
  idempotencyKeyReused('idempotency_key_reused'),

  /// 429: rate limit exceeded.
  rateLimited('rate_limited'),

  /// 500: unexpected server failure.
  internalError('internal_error'),

  /// 503: dependency down or maintenance.
  serviceUnavailable('service_unavailable');

  const ServerErrorCode(this.wireValue);

  /// The snake_case value of the problem's `code` member.
  final String wireValue;

  /// The code whose [wireValue] is [value], or `null` when this SDK version
  /// does not know it.
  static ServerErrorCode? tryFromWire(String value) {
    for (final code in values) {
      if (code.wireValue == value) return code;
    }
    return null;
  }
}

/// The members of an RFC 9457 problem body that the SDK uses.
///
/// Read leniently: an error body may come from a proxy instead of the SDK
/// API, so a member of the wrong type counts as absent instead of failing.
@immutable
final class ApiProblem {
  /// Creates a problem from already-read members.
  const ApiProblem({
    this.code,
    this.title,
    this.detail,
    this.requestId,
    this.fieldErrors = const <String>[],
  });

  /// Reads the members of a decoded problem body, or returns `null` when
  /// [json] is not a JSON object.
  static ApiProblem? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final code = json['code'];
    return ApiProblem(
      code: code is String ? code : null,
      title: _string(json['title']),
      detail: _string(json['detail']),
      requestId: _string(json['request_id']),
      fieldErrors: _fieldErrors(json['errors']),
    );
  }

  /// The raw `code` member, possibly one this SDK version does not know.
  final String? code;

  /// The short, fixed summary for [code].
  final String? title;

  /// The specific explanation; the contract guarantees it is safe to log.
  final String? detail;

  /// The `request_id` member, the same value as `X-Request-Id`.
  final String? requestId;

  /// The `errors` of a `422`, each as `pointer: detail`.
  final List<String> fieldErrors;

  /// [code] as a known [ServerErrorCode], or `null`.
  ServerErrorCode? get knownCode =>
      code == null ? null : ServerErrorCode.tryFromWire(code!);

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static List<String> _fieldErrors(Object? errors) {
    if (errors is! List<Object?>) return const <String>[];
    final descriptions = <String>[];
    for (final error in errors) {
      if (error is! Map<String, Object?>) continue;
      final pointer = _string(error['pointer']) ?? '/';
      final detail = _string(error['detail']) ?? _string(error['code']);
      if (detail != null) descriptions.add('$pointer: $detail');
    }
    return List<String>.unmodifiable(descriptions);
  }
}
