/// Stable error codes of a `BeckLinkException`, shared by every Beck Link
/// SDK.
///
/// [wireValue] is the snake_case form, the same in every SDK and in the
/// documentation.
enum BeckLinkErrorCode {
  /// A method was called before `BeckLink.instance.configure()` completed,
  /// or after it failed.
  notConfigured('not_configured'),

  /// The API key is not a publishable key (`pk_test_…` or `pk_live_…`), or
  /// the service rejected it as unknown, revoked or lacking the required
  /// scope.
  invalidKey('invalid_key'),

  /// The service could not be reached (no connection, DNS or TLS failure) or
  /// kept failing until the retry budget ran out.
  network('network'),

  /// The service still reported too many requests after the retry budget ran
  /// out.
  rateLimited('rate_limited'),

  /// The operation needs tracking, which `setTrackingEnabled(false)` turned
  /// off.
  trackingDisabled('tracking_disabled'),

  /// The URL is not an active link of this project environment.
  linkNotFound('link_not_found'),

  /// The service did not answer before the client deadline.
  timeout('timeout'),

  /// The service rejected the request as invalid for a reason the SDK cannot
  /// check on the device, for example an unknown campaign key.
  invalidRequest('invalid_request');

  const BeckLinkErrorCode(this.wireValue);

  /// The snake_case value, for example `not_configured`.
  final String wireValue;

  /// The code whose [wireValue] is [value], or `null` when this SDK version
  /// does not know [value].
  static BeckLinkErrorCode? tryFromWire(String value) {
    for (final code in values) {
      if (code.wireValue == value) return code;
    }
    return null;
  }
}
