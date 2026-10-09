/// SDK API JSON shared by the tests, shaped like the examples of
/// `docs/contracts/sdk-api.md` (sections 7 and 8).
library;

/// A well-formed publishable key of a test environment.
const String testKey = 'pk_test_0123456789abcdefABCDEF';

/// A second test key, for reconfiguration.
const String otherTestKey = 'pk_test_ZYXWVUTSRQ9876543210';

/// A well-formed publishable key of a live environment.
const String liveKey = 'pk_live_0123456789abcdefABCDEF';

/// A click ID (ULID) as the redirect puts it into Play's referrer and the
/// pasteboard click URL.
const String clickId = '01K6ZPWR5N7Y3A9S2D4F6G8HJK';

/// A link's public ID (ULID).
const String linkId = '01K6ZQ3M8X4T2V9B7C5D1E0FGH';

/// The link host of the test project's test environment.
const String testHost = 'acme-test.becklinks.com';

/// The link host of the test project's live environment.
const String liveHost = 'acme.becklinks.com';

/// A link URL of the test environment, as the operating system hands it
/// to the app.
const String testLinkUrl = 'https://$testHost/summer24?ref=newsletter';

/// Play's install referrer for [clickId].
const String installReferrer = 'click_id=$clickId';

/// The pasteboard click URL the redirect copied for [clickId].
const String pasteboardClickUrl = 'https://$testHost/_c/$clickId';

/// A `config` object (contract section 7.5).
Map<String, Object?> configJson({
  String? logLevel,
  int flushIntervalSeconds = 15,
  List<String> linkHosts = const <String>[testHost],
}) =>
    <String, Object?>{
      'log_level': logLevel,
      'flush_interval_seconds': flushIntervalSeconds,
      'link_hosts': linkHosts,
      'features': <String, Object?>{},
    };

/// A `campaign` object (contract section 7.2).
Map<String, Object?> campaignJson() => <String, Object?>{
      'name': 'Summer sale 2026',
      'source': 'newsletter',
      'medium': 'email',
      'content': 'hero_banner',
      'term': null,
      'creative': 'blue_v2',
    };

/// A `link_event` object (contract section 7.3).
Map<String, Object?> linkEventJson({
  String url = testLinkUrl,
  String path = '/product/123',
  bool isDeferred = false,
  String matchMethod = 'app_link',
  String confidence = 'certain',
  String? id = linkId,
  Map<String, Object?> params = const <String, Object?>{'ref': 'newsletter'},
  Map<String, Object?> data = const <String, Object?>{
    'coupon': 'SUMMER10',
    'color': 'blue',
  },
  bool withCampaign = true,
  String clickedAt = '2026-10-07T08:41:17.204Z',
}) =>
    <String, Object?>{
      'url': url,
      'path': path,
      'params': params,
      'data': data,
      'is_deferred': isDeferred,
      'match_method': matchMethod,
      'confidence': confidence,
      'link_id': id,
      'campaign': withCampaign ? campaignJson() : null,
      'clicked_at': clickedAt,
    };

/// An `attribution` object (contract section 7.4).
Map<String, Object?> attributionJson({
  String state = 'attributed',
  String? matchMethod = 'install_referrer',
  String? confidence = 'certain',
  String? id = linkId,
  bool withCampaign = true,
  String installedAt = '2026-10-07T08:46:03.551Z',
}) =>
    <String, Object?>{
      'state': state,
      'match_method': matchMethod,
      'confidence': confidence,
      'link_id': id,
      'campaign': withCampaign ? campaignJson() : null,
      'installed_at': installedAt,
    };

/// A first-open `200` answer (contract section 8.2).
Map<String, Object?> firstOpenAnswerJson({
  Map<String, Object?>? linkEvent,
  Map<String, Object?>? attribution,
  String? unmatchedReason,
  Map<String, Object?>? config,
}) =>
    <String, Object?>{
      'matched': linkEvent != null,
      'link_event': linkEvent,
      'attribution': attribution ??
          attributionJson(
            state: 'organic',
            matchMethod: null,
            confidence: null,
            id: null,
            withCampaign: false,
          ),
      'unmatched_reason':
          linkEvent == null ? (unmatchedReason ?? 'no_evidence') : null,
      'config': config ?? configJson(),
    };

/// An organic install: nothing matched.
Map<String, Object?> organicAnswerJson({String? unmatchedReason}) =>
    firstOpenAnswerJson(unmatchedReason: unmatchedReason);

/// A deferred match through Play's install referrer.
Map<String, Object?> installReferrerAnswerJson() => firstOpenAnswerJson(
      linkEvent: linkEventJson(
        url: 'https://$testHost/summer24?ref=newsletter',
        isDeferred: true,
        matchMethod: 'install_referrer',
      ),
      attribution: attributionJson(),
    );

/// A deferred match through the iOS pasteboard click URL.
Map<String, Object?> pasteboardAnswerJson() => firstOpenAnswerJson(
      linkEvent: linkEventJson(
        url: 'https://$testHost/summer24',
        isDeferred: true,
        matchMethod: 'pasteboard',
        params: const <String, Object?>{},
      ),
      attribution: attributionJson(matchMethod: 'pasteboard'),
    );

/// A direct open resolved through first-open's `evidence.open_url`.
Map<String, Object?> directOpenAnswerJson({String url = testLinkUrl}) =>
    firstOpenAnswerJson(
      linkEvent: linkEventJson(url: url),
      attribution: attributionJson(matchMethod: 'app_link'),
    );

/// The answer of `POST /v1/sdk/open` (contract section 8.3).
Map<String, Object?> openAnswerJson({
  String url = testLinkUrl,
  String path = '/product/123',
  String matchMethod = 'app_link',
}) =>
    <String, Object?>{
      'link_event': linkEventJson(
        url: url,
        path: path,
        matchMethod: matchMethod,
      ),
    };

/// The `202` answer of `POST /v1/sdk/events` (contract section 8.4).
Map<String, Object?> eventsReceiptJson({
  int accepted = 0,
  List<Map<String, Object?>> rejected = const <Map<String, Object?>>[],
  List<Map<String, Object?>> warnings = const <Map<String, Object?>>[],
}) =>
    <String, Object?>{
      'accepted': accepted,
      'rejected': rejected,
      'warnings': warnings,
    };

/// The `201` answer of `POST /v1/sdk/links` (contract section 8.5).
Map<String, Object?> createdLinkJson({
  String url = 'https://$testHost/k7Qm2Xa',
}) =>
    <String, Object?>{
      'id': '01K6ZS2T4V6W8X0Y1Z3A5B7C9D',
      'url': url,
      'status': 'active',
      'created_at': '2026-10-07T11:20:05.310Z',
      'expires_at': null,
    };
