/// Helpers that keep user data out of `toString` output.
///
/// Query strings and fragments can carry user data (emails, user IDs,
/// tokens appended by other tools), and SDK logs must never contain user IDs
/// (contract section 12), so descriptions keep only the scheme, host and
/// path. Internal to the SDK.
library;

final _queryOrFragment = RegExp('[?#]');

/// [value] without its query string and fragment.
String withoutQuery(String value) {
  final end = value.indexOf(_queryOrFragment);
  return end < 0 ? value : value.substring(0, end);
}

/// [uri] without user info, query string and fragment.
String describeUri(Uri uri) {
  final withoutUserInfo =
      uri.userInfo.isEmpty ? uri : uri.replace(userInfo: '');
  return withoutQuery(withoutUserInfo.toString());
}
