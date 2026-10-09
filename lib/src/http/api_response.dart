import '../json/json_reader.dart';

/// A successful (2xx) SDK API answer whose body is a JSON object.
final class ApiResponse {
  /// Creates a response.
  const ApiResponse({
    required this.statusCode,
    required this.body,
    this.requestId,
    this.replayed = false,
  });

  /// The HTTP status, for example `200`, `201` or `202`.
  final int statusCode;

  /// Reader over the decoded body. Its methods throw a
  /// `MalformedJsonException` for a member of the wrong shape, which the
  /// client converts into a `BeckLinkException`.
  final JsonReader body;

  /// The service's request ID (`X-Request-Id`), or `null` when it sent none
  /// or an unusable one.
  final String? requestId;

  /// Whether the service replayed a stored answer for the same
  /// `Idempotency-Key` (`Idempotent-Replayed: true`).
  final bool replayed;
}

/// Converts a successful answer into the caller's result.
///
/// May throw a `FormatException` (including `MalformedJsonException`) when
/// the body does not have the documented shape.
typedef ResponseReader<T> = T Function(ApiResponse response);
