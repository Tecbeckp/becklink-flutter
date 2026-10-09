import 'package:meta/meta.dart';

import '../models/confidence.dart';
import '../models/link_event.dart';
import '../models/match_method.dart';
import '../platform/pasteboard_click_url.dart';
import 'sdk_options.dart';

/// The platform domain under which every project has its link hosts.
const String platformLinkDomain = 'becklinks.com';

/// Slugs that name Beck Link's own hosts, never a project's (CLAUDE.md,
/// `packages/shared` `RESERVED_SLUGS`). Slugs ending in [testSlugSuffix] are
/// reserved as well.
const Set<String> reservedSlugs = <String>{
  'www',
  'app',
  'api',
  'docs',
  'status',
  'admin',
  'mail',
  'help',
  'cdn',
  'static',
  'assets',
};

/// Suffix of a test environment's link host label (`{slug}-test`).
const String testSlugSuffix = '-test';

/// Longest link URL the SDK API accepts, in characters (contract section
/// 8.3, LNK-002).
const int maxLinkUrlLength = 2048;

/// Most host patterns passed to one pasteboard read (see
/// `checkPasteboardHosts`).
const int _maxPasteboardPatterns = maxPasteboardHosts;

// One DNS label, lowercase: the same rule as `packages/shared` link-hosts.
final _dnsLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

// One short-path segment (LNK-002).
final _shortPath = RegExp(r'^/[A-Za-z0-9_-]{1,64}$');

/// The two shapes of Beck Link URL (contract section 9.1).
enum LinkUrlForm {
  /// Form 1: `https://{host}/{path}[?query]`, an App Link or Universal Link.
  https,

  /// Form 2: `{scheme}://becklink?url={form 1 URL}[&click_id=…]`, the
  /// redirect page's "Open in app" button.
  customScheme,
}

/// A URL the app received that is a Beck Link URL of this project
/// environment (contract section 9.1). Internal to the SDK.
@immutable
final class BeckLinkUrl {
  const BeckLinkUrl._({
    required this.received,
    required this.receivedUri,
    required this.link,
    required this.form,
  });

  /// The URL exactly as the app received it; this is what `/v1/sdk/open`
  /// and `evidence.open_url` carry.
  final String received;

  /// [received], parsed.
  final Uri receivedUri;

  /// The form 1 link URL: [receivedUri] itself, or for [LinkUrlForm.customScheme]
  /// the URL embedded in its `url` parameter.
  final Uri link;

  /// Which form [received] has.
  final LinkUrlForm form;

  /// Whether [received] fits the SDK API's 2,048-character limit. A longer
  /// one (only possible through a long query) is never sent; the app gets
  /// the event the SDK builds on the device instead.
  bool get fitsRequest => received.runes.length <= maxLinkUrlLength;

  // The query can carry user data; only the link's host and path are shown.
  @override
  String toString() => 'BeckLinkUrl(${form.name}: '
      'https://${link.host}${link.path})';
}

/// Decides which received URLs are Beck Link URLs of the configured project
/// environment (contract section 9.1) and which pasteboard URLs may be sent
/// as deferred evidence (contract section 9.3). Every other URL never leaves
/// the device. Internal to the SDK.
@immutable
final class LinkUrlRules {
  /// Creates the rules for [environment], also accepting [linkHosts] (the
  /// cached `config.link_hosts`: the platform host and active custom
  /// domains of the environment).
  LinkUrlRules({
    required this.environment,
    List<String> linkHosts = const <String>[],
  }) : linkHosts = Set<String>.unmodifiable(
          linkHosts.map((host) => host.toLowerCase()),
        );

  /// The environment of the configured key.
  final SdkEnvironment environment;

  /// Link hosts from remote config, lower case.
  final Set<String> linkHosts;

  /// [url] as a Beck Link URL of this environment, or `null` when it is
  /// anything else (another app's or the app's own deep link, an OAuth
  /// callback, a link of the other environment).
  BeckLinkUrl? classify(String url) =>
      _classify(url, environment, includeLinkHosts: true);

  /// Whether [url] is a Beck Link URL of the other environment (a test link
  /// while configured with a live key, or the reverse), which [classify]
  /// refuses. Lets the SDK explain the most common setup mistake.
  bool isOtherEnvironmentLink(String url) {
    final other = switch (environment) {
      SdkEnvironment.test => SdkEnvironment.live,
      SdkEnvironment.live => SdkEnvironment.test,
    };
    return _classify(url, other, includeLinkHosts: false) != null;
  }

  /// The host patterns for the native pasteboard read: every platform link
  /// host (`*.becklinks.com`) plus the cached [linkHosts]. Coarse on purpose:
  /// [acceptsPasteboardUrl] applies the exact rule to the answer.
  List<String> get pasteboardHostPatterns {
    final patterns = <String>{'*.$platformLinkDomain'};
    for (final host in linkHosts) {
      if (patterns.length == _maxPasteboardPatterns) break;
      if (isPasteboardHostPattern(host)) patterns.add(host);
    }
    return List<String>.unmodifiable(patterns);
  }

  /// Whether the pasteboard click URL [url] (already checked to be
  /// `https://{host}/_c/{ULID}`) names a link host of this environment, so
  /// it may be sent as `evidence.ios_pasteboard_url` (contract section 9.3).
  bool acceptsPasteboardUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return _acceptsHost(uri.host.toLowerCase(), environment, true);
  }

  BeckLinkUrl? _classify(
    String url,
    SdkEnvironment environment, {
    required bool includeLinkHosts,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.scheme == 'https') {
      if (!_isLinkUrl(uri, environment, includeLinkHosts)) return null;
      return BeckLinkUrl._(
        received: url,
        receivedUri: uri,
        link: uri,
        form: LinkUrlForm.https,
      );
    }
    // Form 2 works with whatever URI scheme the app registered, which the
    // SDK does not know; `http` is never an app scheme.
    if (uri.scheme.isEmpty ||
        uri.scheme == 'http' ||
        uri.host.toLowerCase() != 'becklink') {
      return null;
    }
    final embedded = lastQueryValues(uri)['url'];
    if (embedded == null || embedded.length > maxLinkUrlLength) return null;
    final link = Uri.tryParse(embedded);
    if (link == null ||
        link.scheme != 'https' ||
        !_isLinkUrl(link, environment, includeLinkHosts)) {
      return null;
    }
    return BeckLinkUrl._(
      received: url,
      receivedUri: uri,
      link: link,
      form: LinkUrlForm.customScheme,
    );
  }

  bool _isLinkUrl(Uri uri, SdkEnvironment environment, bool includeLinkHosts) {
    // Dart's Uri drops the default port 443, so any port left is another.
    if (uri.userInfo.isNotEmpty || uri.hasPort) return false;
    if (!_shortPath.hasMatch(uri.path)) return false;
    return _acceptsHost(uri.host.toLowerCase(), environment, includeLinkHosts);
  }

  bool _acceptsHost(
    String host,
    SdkEnvironment environment,
    bool includeLinkHosts,
  ) {
    if (includeLinkHosts && linkHosts.contains(host)) return true;
    return platformHostEnvironment(host) == environment;
  }
}

/// Whether [url] is a Beck Link URL on a platform link host of either
/// environment, using no configuration. What `BeckLink.isBeckLinkUri`
/// answers before `configure()` has run, when the key's environment and the
/// project's custom link hosts are not known yet.
bool isPlatformLinkUrl(String url) =>
    LinkUrlRules(environment: SdkEnvironment.live).classify(url) != null ||
    LinkUrlRules(environment: SdkEnvironment.test).classify(url) != null;

/// The environment of the platform link host [host] (lower case):
/// `{slug}.becklinks.com` is live, `{slug}-test.becklinks.com` is test. `null`
/// for any other host, a nested subdomain, or a reserved slug (the same
/// rule as `parsePlatformLinkHost` in `packages/shared`).
SdkEnvironment? platformHostEnvironment(String host) {
  const suffix = '.$platformLinkDomain';
  if (!host.endsWith(suffix)) return null;
  final label = host.substring(0, host.length - suffix.length);
  if (!_dnsLabel.hasMatch(label)) return null;
  final isTest = label.endsWith(testSlugSuffix);
  final slug =
      isTest ? label.substring(0, label.length - testSlugSuffix.length) : label;
  if (!_isProjectSlug(slug)) return null;
  return isTest ? SdkEnvironment.test : SdkEnvironment.live;
}

bool _isProjectSlug(String slug) =>
    slug.length + testSlugSuffix.length <= 63 &&
    _dnsLabel.hasMatch(slug) &&
    !reservedSlugs.contains(slug) &&
    !slug.endsWith(testSlugSuffix);

/// The query parameters of [uri]; for a repeated key the last value wins
/// (contract section 7.3). Empty when the query cannot be decoded.
Map<String, String> lastQueryValues(Uri uri) {
  try {
    return <String, String>{
      for (final entry in uri.queryParametersAll.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.last,
    };
  } on FormatException {
    return const <String, String>{};
  }
}

/// The event the SDK builds on the device for [url] when the service cannot
/// resolve it in time (contract section 7.3 "Offline", §29.4): the link
/// URL's own path and query, no data, no link ID and no campaign.
///
/// The match method follows the contract's derivation: a custom-scheme URL
/// is `uri_scheme`, an `https` URL `universal_link` on iOS and `app_link` on
/// Android.
LinkEvent offlineLinkEvent(
  BeckLinkUrl url, {
  required DateTime receivedAt,
  required bool isIos,
}) =>
    LinkEvent(
      url: url.receivedUri,
      path: url.link.path,
      params: lastQueryValues(url.link),
      isDeferred: false,
      matchMethod: switch (url.form) {
        LinkUrlForm.customScheme => MatchMethod.uriScheme,
        LinkUrlForm.https =>
          isIos ? MatchMethod.universalLink : MatchMethod.appLink,
      },
      confidence: Confidence.certain,
      clickedAt: receivedAt,
    );
