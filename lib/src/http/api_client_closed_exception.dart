/// Thrown by an `ApiClient` call that was pending when `ApiClient.close()`
/// ran, or that started afterwards.
///
/// Means "the SDK is shutting down", not a failure: callers keep queued
/// work for the next session and log nothing at error level. Internal to the
/// SDK; it never reaches the app (the `BeckLink` core converts it before a
/// public method returns).
final class ApiClientClosedException implements Exception {
  /// Creates the exception.
  const ApiClientClosedException();

  @override
  String toString() =>
      'ApiClientClosedException: the SDK API client was closed.';
}
