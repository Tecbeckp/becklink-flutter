import 'dart:async' show unawaited;
import 'dart:math';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode, visibleForTesting;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:http/http.dart' as http;

import 'core/buffered_broadcast.dart';
import 'core/event_input.dart';
import 'core/link_url_rules.dart' show isPlatformLinkUrl;
import 'core/sdk_options.dart';
import 'core/sdk_runtime.dart' show SdkRuntime;
import 'core/user_id.dart';
import 'http/api_client.dart';
import 'http/retry_policy.dart';
import 'logging/sdk_logger.dart';
import 'models/api_call.dart';
import 'models/attribution.dart';
import 'models/becklink_exception.dart';
import 'models/diagnostics.dart';
import 'models/link_event.dart';
import 'models/link_options.dart';
import 'models/log_level.dart';
import 'platform/becklink_platform.dart';
import 'platform/method_channel_becklink_platform.dart';
import 'sdk_info.dart';

/// Creates the API client for [SdkOptions], reporting every attempt to
/// the observer behind [BeckLink.onApiCall].
typedef _ObservedApiClientFactory = ApiClient Function(
  SdkOptions options,
  ApiCallObserver onCall,
);

/// The Beck Link SDK: deep links, deferred deep links, install attribution,
/// events and share links for Flutter apps on Android and iOS.
///
/// Use the single [instance]. Call [configure] once at app start, before
/// `runApp`; it returns at once and does its work in the background, so the
/// app's launch is never held up:
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await BeckLink.instance.configure(apiKey: 'pk_live_…');
///   runApp(const MyApp());
/// }
/// ```
///
/// Then route with [onLink] (every link, the one that opened the app
/// included) or [getInitialLink], read the install's [getAttribution], and
/// [track] events.
///
/// Every method except the [onLink], [onAttribution] and [onApiCall] getters
/// (and the static [version]) throws a
/// [BeckLinkException] with code `not_configured` when called before
/// [configure]. Arguments that break a documented rule throw an
/// [ArgumentError]. Network trouble is never thrown by [track] and [flush];
/// only [createLink], whose result the app waits for, reports it.
///
/// Call [configure] in the app's main isolate only. In a background isolate
/// or headless engine (for example a push-messaging handler) the SDK reads
/// no launch link and registers no install.
final class BeckLink {
  BeckLink._({
    required SdkLogger logger,
    required BeckLinkPlatform platform,
    required _ObservedApiClientFactory createApiClient,
    TargetPlatform? targetPlatform,
    DateTime Function()? now,
    Random? random,
  })  : _logger = logger,
        _platform = platform,
        _createApiClient = createApiClient,
        _targetPlatform = targetPlatform,
        _now = now,
        _random = random;

  factory BeckLink._production() {
    final logger = SdkLogger();
    return BeckLink._(
      logger: logger,
      platform: MethodChannelBeckLinkPlatform(logger: logger),
      createApiClient: (options, onCall) => ApiClient(
        apiKey: options.apiKey,
        baseUrl: options.apiBaseUrl,
        // Plain HTTP to a development server on the same Wi-Fi; release
        // builds keep the HTTPS-only rule (SEC-001).
        allowPrivateNetworkHttp: kDebugMode,
        logger: logger,
        onCall: onCall,
      ),
    );
  }

  /// Creates an SDK with its dependencies replaced, for the SDK's own tests.
  ///
  /// [platform] stands in for the native layers; [httpClient] and [baseUrl]
  /// for the SDK API (only `https`, or `http` on this machine); [logSink]
  /// receives the log; [targetPlatform] sets the platform reported to the
  /// service (default: [defaultTargetPlatform]); [now] and [random] replace
  /// the clock and the ID generator; [retryPolicy] the backoff;
  /// [compressEvents] `false` sends event batches without gzip.
  @visibleForTesting
  factory BeckLink.withDependencies({
    required BeckLinkPlatform platform,
    http.Client? httpClient,
    Uri? baseUrl,
    LogSink? logSink,
    TargetPlatform? targetPlatform,
    DateTime Function()? now,
    Random? random,
    RetryPolicy retryPolicy = const RetryPolicy(),
    bool compressEvents = true,
  }) {
    final logger = SdkLogger(sink: logSink);
    return BeckLink._(
      logger: logger,
      platform: platform,
      createApiClient: (options, onCall) => ApiClient(
        apiKey: options.apiKey,
        logger: logger,
        httpClient: httpClient,
        baseUrl: baseUrl ?? options.apiBaseUrl,
        onCall: onCall,
        retryPolicy: retryPolicy,
        now: now,
        random: random,
        compressEvents: compressEvents,
      ),
      targetPlatform: targetPlatform,
      now: now,
      random: random,
    );
  }

  /// The SDK.
  static final BeckLink instance = BeckLink._production();

  final SdkLogger _logger;
  final BeckLinkPlatform _platform;
  final _ObservedApiClientFactory _createApiClient;
  final TargetPlatform? _targetPlatform;
  final DateTime Function()? _now;
  final Random? _random;

  final BufferedBroadcast<LinkEvent> _links =
      BufferedBroadcast<LinkEvent>(capacity: SdkRuntime.linkBufferSize);

  // Only the newest attribution matters to a listener that subscribes late.
  final BufferedBroadcast<Attribution> _attributions =
      BufferedBroadcast<Attribution>(capacity: 1);

  // Enough for the startup calls (first open or init, a link, an event
  // batch) of an app that subscribes after configure().
  final BufferedBroadcast<BeckLinkApiCall> _apiCalls =
      BufferedBroadcast<BeckLinkApiCall>(capacity: 32);

  SdkRuntime? _runtime;

  // Beck Link URIs given to handleUri before configure(), oldest first.
  static const int _maxUriBeforeConfigure = 16;
  final List<Uri> _uriBeforeConfigure = <Uri>[];

  /// Starts the SDK with the publishable [apiKey] of a project environment
  /// (`pk_test_…` or `pk_live_…`; the key decides the environment).
  ///
  /// Returns at once: storage, the launch link, the first open and all
  /// network work run in the background (§29). Calling it again with the
  /// same arguments does nothing; with other arguments it applies them (a
  /// new key is used for every later request). If a later call fails, the
  /// earlier configuration stays in effect.
  ///
  /// - [logLevel]: how much the SDK writes to the debug console; the
  ///   project's remote config can override it. See also [setLogLevel].
  /// - [enablePasteboard]: iOS only. Lets the SDK read the click URL that a
  ///   Beck Link landing page copied before sending the user to the App
  ///   Store, once per install and before the first open, for a certain
  ///   deferred match. iOS may show the user a paste prompt. Off by default.
  /// - [firstOpenTimeout]: how long [getInitialLink] waits for the service
  ///   to resolve the link that opened the app, counted from the moment the
  ///   request is sent (on the first run, the first open that also finds a
  ///   deferred link). After it, the app gets "no deferred link", or the
  ///   launch link without its data; a deferred link that matches later is
  ///   not delivered. Between zero and 30 seconds; 3 seconds by default.
  ///
  /// - [apiBaseUrl]: the origin of the Beck Link SDK API, for staging or a
  ///   local development server; leave it out in apps (production,
  ///   `https://api.becklinks.com`). Must be an `https` origin, or an `http`
  ///   origin on this machine (`localhost`, `127.0.0.1`, or `10.0.2.2` from
  ///   the Android emulator). Debug builds also accept `http` to a private
  ///   network address (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `.local`)
  ///   so a phone can reach a server on the same Wi-Fi; the platform must
  ///   allow cleartext traffic for it.
  /// - [handlePlatformLinks]: `true` (the default) lets the SDK read the
  ///   links the operating system hands to the app (the launch link and links
  ///   opened while it runs). Set it to `false` when your app already
  ///   receives its deep links itself (for example with `app_links`) and
  ///   forwards every URI to [handleUri]: the SDK then subscribes to no
  ///   native link stream and reads no launch link. The deferred deep link
  ///   (install referrer, pasteboard), first open, attribution and events
  ///   work the same. With it off, [getInitialLink] reports only a deferred
  ///   link; links forwarded with [handleUri] arrive on [onLink]. Read once,
  ///   at the first [configure] call of the process.
  ///
  /// Throws a [BeckLinkException] with code `invalid_key` when [apiKey] is
  /// not a publishable key (a secret key `sk_…` is refused before anything
  /// is sent: it must never ship inside an app), and an [ArgumentError]
  /// when [firstOpenTimeout] is out of range or [apiBaseUrl] is not an
  /// origin the SDK may use.
  Future<void> configure({
    required String apiKey,
    LogLevel logLevel = LogLevel.error,
    bool enablePasteboard = false,
    Duration firstOpenTimeout = const Duration(seconds: 3),
    Uri? apiBaseUrl,
    bool handlePlatformLinks = true,
  }) async {
    final options = SdkOptions.parse(
      apiKey: apiKey,
      logLevel: logLevel,
      enablePasteboard: enablePasteboard,
      firstOpenTimeout: firstOpenTimeout,
      apiBaseUrl: apiBaseUrl,
      handlePlatformLinks: handlePlatformLinks,
      allowPrivateNetworkHttp: kDebugMode,
    );
    final running = _runtime;
    if (running != null) {
      running.reconfigure(options);
      return;
    }
    // Platform channels and lifecycle events need the binding; creating it
    // here is what runApp would do a moment later anyway.
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final runtime = SdkRuntime(
      options: options,
      platform: _platform,
      logger: _logger,
      createApiClient: (options) => _createApiClient(options, _apiCalls.add),
      links: _links,
      attributions: _attributions,
      targetPlatform: _targetPlatform ?? defaultTargetPlatform,
      now: _now,
      random: _random,
    );
    _runtime = runtime;
    runtime.start(binding);
    _logger.info('Configured: $options');
    // URIs forwarded before configure() are handled now, in order.
    final waiting = List<Uri>.of(_uriBeforeConfigure);
    _uriBeforeConfigure.clear();
    for (final uri in waiting) {
      unawaited(runtime.handleUri(uri.toString()));
    }
  }

  /// Whether [uri] is a Beck Link URI: a link on a host of the configured
  /// environment (`https://{slug}.becklinks.com/…` for a live key,
  /// `https://{slug}-test.becklinks.com/…` for a test key, or a link host of
  /// the project's remote config such as a custom domain) or its custom-scheme
  /// form `scheme://becklink?url=https://…`.
  ///
  /// Synchronous, pure and offline: it sends and stores nothing and never
  /// throws. Use it in your own deep-link listener to leave Beck Link URIs to
  /// the SDK:
  ///
  /// ```dart
  /// appLinks.uriLinkStream.listen((uri) {
  ///   if (BeckLink.instance.isBeckLinkUri(uri)) return;
  ///   router.go(uri.path);
  /// });
  /// ```
  ///
  /// Before [configure] ran the environment is unknown, so any platform link
  /// host (`*.becklinks.com`, live or test) counts; once [configure] was
  /// called, only the key's environment does. Custom link hosts are known
  /// from the first run's answer on, and only after the SDK opened its
  /// storage; until then only the platform hosts count.
  bool isBeckLinkUri(Uri uri) {
    final runtime = _runtime;
    final url = uri.toString();
    return runtime == null
        ? isPlatformLinkUrl(url)
        : runtime.isBeckLinkUrl(url);
  }

  /// Hands the SDK a URI the app received by other means (`app_links`, a
  /// `go_router` redirect, a push payload, a QR scan), as if the operating
  /// system had opened the app with it.
  ///
  /// Returns `true` when [uri] is a Beck Link URI (see [isBeckLinkUri]): the
  /// SDK took it, resolves it in the background (a re-engagement open, or the
  /// event built on the device when the service does not answer within
  /// `firstOpenTimeout`, exactly as for a platform link) and delivers one
  /// [LinkEvent] on [onLink]. Returns `false` for any other URI; nothing about
  /// it is sent, stored or logged beyond its scheme and host, and the app
  /// continues with its own handling. Never throws.
  ///
  /// Safe to call at any time. Before [configure] a Beck Link URI (by the
  /// platform-host rule of [isBeckLinkUri]) is kept, at most 16 of them, and
  /// handled when [configure] runs; while the SDK is starting it waits for
  /// its storage and for the launch link, like the links opened while the
  /// app runs. While tracking is off the link is still resolved and
  /// delivered, without any identifier, like a platform link.
  ///
  /// One open is delivered once: the same URL (scheme and host compared
  /// case-insensitively, everything else exactly) is ignored when it was
  /// already delivered in the last 10 seconds, whether it arrived through
  /// [handleUri] again or through the platform channel (with
  /// [configure]'s `handlePlatformLinks` left on), in either order. A user
  /// opening the same link again later is delivered again.
  Future<bool> handleUri(Uri uri) async {
    final runtime = _runtime;
    if (runtime != null) return runtime.handleUri(uri.toString());
    if (!isPlatformLinkUrl(uri.toString())) return false;
    if (_uriBeforeConfigure.length >= _maxUriBeforeConfigure) {
      _uriBeforeConfigure.removeAt(0);
    }
    _uriBeforeConfigure.add(uri);
    return true;
  }

  /// The link that opened the app, or `null` when it was not opened by a
  /// Beck Link link.
  ///
  /// That is either the link the user opened directly (a Universal Link,
  /// App Link or the "Open in app" button of a link page;
  /// [LinkEvent.isDeferred] is `false`), or on the first run after install
  /// the link the user clicked before installing ([LinkEvent.isDeferred] is
  /// `true`, delivered once per install). Every call returns the same
  /// result.
  ///
  /// Waits until the service resolved the link, at most [configure]'s
  /// `firstOpenTimeout` after the request was sent; offline, the app gets
  /// the link built on the device (no [LinkEvent.data], no
  /// [LinkEvent.linkId]). Returns `null` after `firstOpenTimeout` plus a
  /// second when the app is not in the foreground.
  ///
  /// The same event is also delivered on [onLink]: handle the launch link
  /// either here or there, not in both places.
  Future<LinkEvent?> getInitialLink() async => _require().initialLink();

  /// Every link that opens the app, each delivered once: the link that
  /// launched it (the same event [getInitialLink] returns), the deferred
  /// link on the first run, and links opened while the app runs.
  ///
  /// A broadcast stream that keeps the last links while nobody listens and
  /// hands them to the first listener, so subscribing a moment after
  /// [configure] loses nothing. May be listened to before [configure].
  ///
  /// Only Beck Link URLs of the configured environment arrive here; other
  /// URLs the app receives (its own deep links, OAuth callbacks) are left to
  /// the app and never leave the device. Treat [LinkEvent.path],
  /// [LinkEvent.params] and [LinkEvent.data] as untrusted input.
  Stream<LinkEvent> get onLink => _links.stream;

  /// The install's attribution: which link, if any, brought this install.
  ///
  /// On the first run it waits for the first open's answer, at most
  /// [configure]'s `firstOpenTimeout` after it was sent, and then reports
  /// `pending` while the answer is still on its way. Later runs answer at
  /// once from the stored result. `unavailable` while tracking is disabled
  /// or when no result can be had.
  Future<Attribution> getAttribution() async => _require().attribution();

  /// The attribution each time it changes in this process, starting with
  /// the first value [getAttribution] reports (for example `pending`, then
  /// `attributed` when a slow answer arrives, or `unavailable` when tracking
  /// is turned off).
  ///
  /// A broadcast stream that keeps the newest value while nobody listens.
  /// May be listened to before [configure].
  Stream<Attribution> get onAttribution => _attributions.stream;

  /// Records the custom event [name] for this install, credited to the link
  /// that brought or last re-engaged it.
  ///
  /// The event is stored on the device and sent in batches (every 15
  /// seconds, at 20 waiting events and when the app goes to the
  /// background), and kept across restarts until it is delivered or 7 days
  /// old. Completes once it is stored; network trouble is never thrown.
  /// While tracking is disabled the event is dropped.
  ///
  /// - [name]: 1 to 64 lower-case letters, digits or `_`, for example
  ///   `purchase` or `add_to_cart`.
  /// - [properties]: a flat map of at most 50 keys (1 to 64 characters)
  ///   with [String], [bool] or [num] values, at most 8 KB as JSON. `null`
  ///   values are left out. Avoid personal data such as email addresses: the
  ///   service removes values that look like them.
  /// - [revenue] with [currency] (ISO 4217, such as `USD`): both or
  ///   neither; revenue within ±1,000,000,000.
  ///
  /// Throws an [ArgumentError] when an argument breaks these rules.
  Future<void> track(
    String name, {
    Map<String, Object?>? properties,
    num? revenue,
    String? currency,
  }) async {
    final runtime = _require();
    final input = checkEventInput(
      name,
      properties: properties,
      revenue: revenue,
      currency: currency,
    );
    await runtime.track(input);
  }

  /// Sets your own ID of the signed-in user, sent with later events and
  /// opens and added as `referrer_user_id` to links from [createLink].
  ///
  /// 1 to 256 characters without control characters. Use an internal ID,
  /// not an email address or phone number. Kept across restarts until
  /// [clearUserId].
  ///
  /// Throws an [ArgumentError] when [id] breaks these rules.
  Future<void> setUserId(String id) async {
    final runtime = _require();
    await runtime.setUserId(checkUserId(id));
  }

  /// Forgets the user ID, for example when the user signs out.
  Future<void> clearUserId() async => _require().setUserId(null);

  /// Creates a link to share from the app, for example a referral link, and
  /// returns its URL.
  ///
  /// The link uses the project environment's link domain, a generated short
  /// path and the project's default redirects. When a user ID is set (and
  /// tracking is enabled), `referrer_user_id` is added to its data unless
  /// [options] already set it.
  ///
  /// Throws an [ArgumentError] when [LinkOptions.expiresAt] is not in the
  /// future or the data grows over 4 KB with `referrer_user_id`, and a
  /// [BeckLinkException] when the link cannot be created: `network` or
  /// `timeout` (tried for at most 30 seconds), `rate_limited`,
  /// `invalid_key` (also when the key may not create links), or
  /// `invalid_request` (for example an unknown campaign key).
  Future<String> createLink(LinkOptions options) async =>
      _require().createLink(options);

  /// Turns tracking on or off, for example from your consent dialog
  /// (PRV-002). The choice is kept across restarts; tracking is on until the
  /// app turns it off.
  ///
  /// Off: the SDK stops collecting and sending: queued events are deleted,
  /// [track] drops events, the install's identifiers are deleted, and
  /// attribution becomes `unavailable`. Links still open and route: they are
  /// resolved without recording anything. On again: the device counts as a
  /// new install.
  Future<void> setTrackingEnabled(bool enabled) async =>
      _require().setTrackingEnabled(enabled);

  /// Sends waiting events now, for example before the user leaves a
  /// checkout flow.
  ///
  /// Completes when they were sent, or after at most 30 seconds while
  /// sending goes on in the background. Never throws for network trouble:
  /// events that could not be sent stay queued.
  Future<void> flush() async => _require().flush();

  /// Sets how much the SDK writes to the debug console. The project's
  /// remote config can override it. Logs never contain API keys or user IDs.
  void setLogLevel(LogLevel level) => _require().setLogLevel(level);

  /// Debug builds only: forgets this install, so you can test deferred deep
  /// links again without reinstalling the app.
  ///
  /// Deletes the stored install ID, first-open result, user ID, tracking
  /// choice, cached remote config and queued events, and cancels requests
  /// in flight. On iOS it also replaces the install ID kept in the Keychain,
  /// so the service sees a new install rather than a reinstall.
  ///
  /// The running app keeps its links and session; attribution becomes
  /// `unavailable`. Close the app completely and open it again (for a
  /// deferred test: click the link first, then open the app) to run the
  /// first open of the new install.
  ///
  /// Throws an [UnsupportedError] in profile and release builds, where it
  /// would wipe a real user's attribution.
  Future<void> debugResetInstall() async {
    if (!kDebugMode) {
      throw UnsupportedError(
        'debugResetInstall() is available in debug builds only.',
      );
    }
    await _require().debugResetInstall();
  }

  /// Debug builds only: sends the first open of this install now, without
  /// restarting the app, and completes when it was answered or failed (at
  /// most 30 seconds). Use it after [debugResetInstall], or after fixing
  /// the configuration when the first open kept failing.
  ///
  /// A first open already in progress is awaited instead. A deferred link
  /// it matches is delivered on [onLink]; read the outcome (match method,
  /// confidence, `unmatched_reason`) with [getDiagnostics]. The native
  /// layers read the install referrer and the pasteboard once per process,
  /// so this run carries them only when no earlier first open in this
  /// process read them; restart the app to test those.
  ///
  /// Throws an [UnsupportedError] in profile and release builds, and a
  /// [StateError] when the first open cannot run: it already succeeded for
  /// this install, tracking is off, or the service refused the key.
  Future<void> debugRunFirstOpen() async {
    if (!kDebugMode) {
      throw UnsupportedError(
        'debugRunFirstOpen() is available in debug builds only.',
      );
    }
    await _require().debugRunFirstOpen();
  }

  /// Debug builds only: handles [url] as if the operating system had opened
  /// the app with it, for testing links without another app.
  ///
  /// Returns `true` when [url] is a Beck Link URL of the configured
  /// environment (`https://{slug}-test.becklinks.com/{path}` for a test key,
  /// a host from the remote config, or the `{scheme}://becklink?url=…`
  /// form); it is then resolved through the service and delivered on
  /// [onLink], like a link the user opened. Returns `false` for anything
  /// else, which never leaves the device.
  ///
  /// Throws an [UnsupportedError] in profile and release builds.
  Future<bool> debugOpenLink(Uri url) async {
    if (!kDebugMode) {
      throw UnsupportedError(
        'debugOpenLink() is available in debug builds only.',
      );
    }
    return _require().debugOpenLink(url.toString());
  }

  /// A snapshot of the SDK's state for debug and support screens: SDK
  /// version, environment, API origin, install ID, first-open outcome
  /// (matched link, `unmatched_reason`), attribution, remote config
  /// (including `link_hosts`) and the number of queued events.
  ///
  /// Waits until the SDK opened its storage. Contains no API key and no
  /// user ID.
  Future<BeckLinkDiagnostics> getDiagnostics() async =>
      _require().diagnostics();

  /// Every attempt of every request the SDK sends to the Beck Link SDK API,
  /// for debug screens: path, attempt number, HTTP status, duration,
  /// request ID (`X-Request-Id`), whether the service replayed a stored
  /// answer (`Idempotent-Replayed`) and the error code of a failed attempt.
  ///
  /// Records never contain the API key, bodies, idempotency keys, install
  /// or user IDs. A broadcast stream that keeps the last 32 records while
  /// nobody listens. May be listened to before [configure].
  Stream<BeckLinkApiCall> get onApiCall => _apiCalls.stream;

  /// The version of this SDK, as sent to the service in `X-SDK-Version`.
  static String get version => sdkVersion;

  /// Stops the SDK: lifecycle watching, timers and requests. For the SDK's
  /// own tests with [BeckLink.withDependencies]; apps never call it.
  @visibleForTesting
  Future<void> dispose() async {
    final runtime = _runtime;
    _runtime = null;
    await runtime?.dispose();
    await _links.close();
    await _attributions.close();
    await _apiCalls.close();
  }

  SdkRuntime _require() {
    final runtime = _runtime;
    if (runtime == null) throw const BeckLinkException.notConfigured();
    return runtime;
  }
}
