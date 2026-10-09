/// Product IDs the demo catalogue uses.
final RegExp _productId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// The app location a link's deep-link [path] opens, or `null` when the app
/// has no such screen.
///
/// Anyone can create a URL, so the path is untrusted input: only known
/// screens are accepted, and their parameters are checked before a screen
/// sees them. The Debug screen is deliberately not reachable from a link,
/// because it can reset the install. The path's own query string is not
/// carried over; screens read the link's `params` and `data` from the
/// `LinkEvent` instead.
String? appLocationForDeepLink(String path) {
  final List<String> segments;
  try {
    final uri = Uri.tryParse(path);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        !uri.path.startsWith('/')) {
      return null;
    }
    // Decoding happens here and throws for an invalid percent-encoding.
    segments = uri.pathSegments;
  } on FormatException {
    return null;
  }
  // `/referral/` means `/referral`.
  final parts = segments.isNotEmpty && segments.last.isEmpty
      ? segments.sublist(0, segments.length - 1)
      : segments;
  if (parts.isEmpty) return '/';
  if (parts.length == 1 && parts.first == 'referral') return '/referral';
  if (parts.length == 2 &&
      parts.first == 'product' &&
      _productId.hasMatch(parts.last)) {
    return '/product/${parts.last}';
  }
  return null;
}
