/// Thrown when SDK API JSON (a response body or stored SDK state) does not
/// have the shape the SDK API contract documents.
///
/// Internal to the SDK: the client converts it to a `BeckLinkException`
/// before anything reaches the app. The message names only the JSON Pointer
/// and the expected shape, never the received value, because values can
/// carry user data (link data, user IDs).
final class MalformedJsonException extends FormatException {
  /// Creates an exception for the member at [pointer] that is not [expected],
  /// for example `a string` or `an ISO-8601 UTC timestamp`.
  MalformedJsonException(this.pointer, String expected)
      : super(
          'Malformed SDK JSON at "${pointer.isEmpty ? '/' : pointer}": '
          'expected $expected.',
        );

  /// RFC 6901 JSON Pointer of the offending member; empty for the document
  /// root.
  final String pointer;
}
