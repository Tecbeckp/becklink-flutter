/// The rules for the iOS pasteboard click URL (IOS-005, contract section
/// 9.3): which hosts may be named, and which pasteboard text counts as a
/// click URL. The Swift layer applies the same rules before the text leaves
/// it; Dart checks the answer again so a native bug cannot pass anything
/// else on. Internal to the SDK.
library;

/// Most host patterns one pasteboard read accepts; far above a project's
/// link hosts, it only bounds the native work.
const int maxPasteboardHosts = 100;

/// Longest pasteboard URL accepted, in characters (LNK-002, contract
/// section 8.2 `evidence.ios_pasteboard_url`).
const int maxPasteboardUrlLength = 2048;

const _label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';

// At least two labels, so a pattern can never be as broad as `*.app`.
final _hostPattern = RegExp('^(?:\\*\\.)?$_label(?:\\.$_label)+\$');

final _singleLabel = RegExp('^$_label\$');

// `/_c/` and a ULID (contract section 2), in either case.
final _clickPath = RegExp(r'^/_c/[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$');

/// Returns [hosts] as an unmodifiable list after checking every entry is a
/// host pattern: a lowercase host such as `go.acme.com`, or `*.` and a host
/// (`*.becklinks.com`), which matches exactly one more label in front
/// (`acme.becklinks.com`, not `a.b.becklinks.com` or `becklinks.com`).
///
/// Throws an [ArgumentError] when [hosts] is empty (nothing could match, so
/// reading would only bother the user), has more than [maxPasteboardHosts]
/// entries, or holds an entry that is not a pattern.
List<String> checkPasteboardHosts(List<String> hosts) {
  if (hosts.isEmpty) {
    throw ArgumentError('must name at least one host', 'allowedHosts');
  }
  if (hosts.length > maxPasteboardHosts) {
    throw ArgumentError(
      'must name at most $maxPasteboardHosts hosts',
      'allowedHosts',
    );
  }
  for (final host in hosts) {
    if (!isPasteboardHostPattern(host)) {
      throw ArgumentError.value(
        host,
        'allowedHosts',
        'must be a lowercase host, optionally starting with "*."',
      );
    }
  }
  return List<String>.unmodifiable(hosts);
}

/// Whether [value] is a host pattern [checkPasteboardHosts] accepts: a
/// lowercase host of at least two labels, optionally starting with `*.`.
bool isPasteboardHostPattern(String value) => _hostPattern.hasMatch(value);

/// Whether [host] (lowercase) matches [pattern], a pattern accepted by
/// [checkPasteboardHosts].
bool hostMatchesPattern(String host, String pattern) {
  if (!pattern.startsWith('*.')) return host == pattern;
  final suffix = pattern.substring(1);
  if (!host.endsWith(suffix)) return false;
  return _singleLabel.hasMatch(host.substring(0, host.length - suffix.length));
}

/// Whether [value] is a pasteboard click URL of one of [allowedHosts]:
/// `https://{host}/_c/{ULID}` with nothing else, that is no user info, no
/// port other than 443, no query and no fragment, at most
/// [maxPasteboardUrlLength] characters, and a host matching one of the
/// patterns (see [checkPasteboardHosts]).
///
/// The patterns are coarse (`*.becklinks.com`); the caller still applies the
/// exact link host rule of contract section 9.1 (environment suffix,
/// reserved slugs) before sending the URL.
bool isPasteboardClickUrl(String value, List<String> allowedHosts) {
  if (value.isEmpty || value.length > maxPasteboardUrlLength) return false;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      uri.hasQuery ||
      uri.hasFragment ||
      !_clickPath.hasMatch(uri.path)) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return allowedHosts.any((pattern) => hostMatchesPattern(host, pattern));
}
