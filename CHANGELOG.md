# Changelog

All notable changes to `becklink_flutter` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses
[Semantic Versioning](https://semver.org/).

## 0.1.0 (2026-10-09)

First release, for Android 6.0+ (API 23) and iOS 15+ (Xcode 16+), on Flutter 3.27+ (Dart 3.6+).

### Added

- `BeckLink.instance.isBeckLinkUri(uri)`: synchronous, offline check for a Beck Link URI of the
  configured environment (platform hosts, cached link hosts, the custom-scheme form), so an app's
  own deep-link listener can skip Beck Link URIs.
- `BeckLink.instance.handleUri(uri)`: feeds a URI received by other means (`app_links`,
  `go_router`, a push payload, a QR scan) into the SDK like a link opened by the system. Delivers
  one `LinkEvent` on `onLink`, returns `false` for URIs that are not Beck Link URIs, is
  deduplicated against the platform channel and repeated calls (same URL within 10 seconds), and
  is safe to call before `configure()` finished.
- `configure(handlePlatformLinks: false)`: the SDK reads no launch link and listens to no native
  link stream; the app forwards its links with `handleUri`. Deferred deep linking, first open,
  attribution and events are unchanged. Default `true`, so existing apps are not affected.
- README section "Apps that already handle deep links (app_links, go_router, GetX)".
- `BeckLink.instance.configure()` with a publishable key (`pk_test_…` or `pk_live_…`). It returns
  at once and runs storage, the launch link and network work in the background. Options:
  `logLevel`, `enablePasteboard` and `firstOpenTimeout` (3 seconds by default, up to 30).
- Direct deep links: Universal Links and custom-scheme URLs on iOS (cold start included, for
  app-delegate apps and, from Flutter 3.38, UIScene apps), App Links and custom-scheme URLs on
  Android. Only Beck Link URLs of the configured environment are reported; other URLs never leave
  the device.
- `onLink` stream that delivers every link once (the launch link, the deferred link and links
  received while running) and buffers links until the first listener; `getInitialLink()` for the
  link that opened the app.
- Deferred deep linking on the first open: Google Play Install Referrer on Android, opt-in
  pasteboard click URL on iOS (read at most once per install, only after pattern detection, only
  for the project's link hosts). Every match reports `matchMethod` and `confidence`.
- Install attribution with `getAttribution()` and `onAttribution` (`pending`, `attributed`,
  `organic`, `reinstall`, `unavailable`), stored on the device after the first open.
- Custom events with `track()`: validated on the device, kept in a persistent offline queue (500
  events or 2 MB, 7 days), sent in gzip batches of up to 50 every 15 seconds, at 20 events and when
  the app goes to the background; `flush()` to send now.
- `setUserId()` and `clearUserId()`; the user ID goes with sessions and events and into share links
  as `referrer_user_id`.
- `createLink()` with `LinkOptions` for share and referral links on the environment's link host.
- `setTrackingEnabled()` consent switch: off deletes queued events and the install ID and stops
  collection, while links keep routing.
- `setLogLevel()` and `LogLevel`; logs never contain API keys, user IDs, query strings or event
  properties.
- Typed `BeckLinkException` with stable codes (`not_configured`, `invalid_key`, `network`,
  `rate_limited`, `tracking_disabled`, `link_not_found`, `timeout`, `invalid_request`).
- HTTP client with retries (exponential backoff with full jitter, 2-second base, 5-minute cap),
  `Retry-After` support and idempotency keys.
- Install ID kept in the iOS Keychain (this device only) so reinstalls are recognised; SDK storage
  excluded from backups on both platforms.
- iOS privacy manifest (`PrivacyInfo.xcprivacy`) and a data disclosure for App Store privacy labels
  and Google Play Data safety ([doc/privacy.md](doc/privacy.md)).
- CocoaPods support, and Swift Package Manager support on Flutter 3.44+.
- Example app with go_router and a Debug screen.
- Diagnostics for debug and support screens: `BeckLink.version`, `getDiagnostics()`
  (`BeckLinkDiagnostics`: install ID, first-open outcome with `unmatchedReason`, remote config,
  queued events) and the `onApiCall` stream (`BeckLinkApiCall`: status, request ID,
  `Idempotent-Replayed`).
- `configure(apiBaseUrl:)` for staging and local SDK API servers; debug builds also accept plain
  HTTP to private network addresses.
- Debug-build helpers `debugRunFirstOpen()` and `debugOpenLink()`.
