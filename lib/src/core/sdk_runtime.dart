import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../http/api_client.dart';
import '../http/api_client_closed_exception.dart';
import '../http/api_endpoint.dart';
import '../json/json_reader.dart';
import '../logging/sdk_logger.dart';
import '../models/attribution.dart';
import '../models/attribution_state.dart';
import '../models/becklink_error_code.dart';
import '../models/becklink_exception.dart';
import '../models/diagnostics.dart';
import '../models/link_event.dart';
import '../models/link_options.dart';
import '../models/log_level.dart';
import '../models/remote_config.dart';
import '../platform/becklink_platform.dart';
import '../platform/install_id_seed_result.dart';
import '../platform/install_referrer_result.dart';
import '../platform/platform_link.dart';
import '../sdk_info.dart';
import '../storage/event_queue.dart';
import '../storage/file_storage_directory.dart';
import '../storage/first_open_record.dart';
import '../storage/install_identity.dart';
import '../storage/memory_storage_directory.dart';
import '../storage/sdk_state_store.dart';
import '../storage/seen_links.dart';
import '../storage/storage_directory.dart';
import '../util/uuid.dart';
import 'app_lifecycle_watcher.dart';
import 'buffered_broadcast.dart';
import 'event_delivery.dart';
import 'event_input.dart';
import 'first_open_answer.dart';
import 'link_resolver.dart';
import 'link_url_rules.dart';
import 'sdk_options.dart';

/// Creates the API client for the publishable key and API origin of
/// [options]; tests replace the HTTP layer through it.
typedef ApiClientFactory = ApiClient Function(SdkOptions options);

/// A link delivery the SDK accepted: a Beck Link URL of this environment
/// that was not delivered before.
typedef _AcceptedLink = ({PlatformLink link, BeckLinkUrl url});

/// Everything `BeckLink` does after `configure()`: the startup sequence,
/// first open, link resolution, attribution, events and consent (§29).
/// Internal to the SDK.
///
/// Startup runs in the background so `configure()` returns at once, and no
/// stage blocks the app (§29):
///
/// 1. storage directory → state store and event queue (memory only when the
///    platform offers no directory);
/// 2. install identity (only with tracking on; iOS Keychain seed);
/// 3. wait until the app is in the foreground (a headless engine stops
///    here, see [AppLifecycleWatcher]);
/// 4. the launch link, then either the first open (first run, retried until
///    it succeeds) with the launch link as `evidence.open_url`, or
///    `/v1/sdk/open` for the launch link;
/// 5. `/v1/sdk/init` on later launches, and periodic event flushes.
///
/// The app waits for links only through `getInitialLink()`, at most
/// `firstOpenTimeout` after the resolving request was sent; a deferred link
/// that arrives later is not delivered (§13: a late second callback needs an
/// opt-in this API does not offer). Nothing here throws into the app except
/// what the public methods document: internal failures are logged and end
/// in a documented fallback.
final class SdkRuntime {
  /// Creates the runtime; [start] begins the startup sequence.
  SdkRuntime({
    required SdkOptions options,
    required BeckLinkPlatform platform,
    required SdkLogger logger,
    required ApiClientFactory createApiClient,
    required BufferedBroadcast<LinkEvent> links,
    required BufferedBroadcast<Attribution> attributions,
    required TargetPlatform targetPlatform,
    DateTime Function()? now,
    Random? random,
  })  : _options = options,
        _platform = platform,
        _logger = logger,
        _createApiClient = createApiClient,
        _links = links,
        _attributions = attributions,
        _platformName = _wireNameOf(targetPlatform),
        _targetPlatform = targetPlatform,
        _now = now ?? DateTime.now,
        _random = random,
        _appLogLevel = options.logLevel,
        _api = createApiClient(options),
        _rules = LinkUrlRules(environment: options.environment) {
    _logger.level = options.logLevel;
    _lifecycle = AppLifecycleWatcher(
      onForeground: _onForeground,
      onBackground: _onBackground,
      now: _now,
    );
    _resolver = LinkResolver(
      api: () => _api,
      logger: _logger,
      requestContext: _requestContext,
      requester: _openRequester,
      isIos: _platformName == _ios,
    );
  }

  /// A new session starts when the app returns after more than this in the
  /// background (§29 step 3).
  static const Duration sessionTimeout = Duration(minutes: 30);

  /// How long `getInitialLink()` and `getAttribution()` wait, on top of
  /// `firstOpenTimeout`, for an app that is not in the foreground yet before
  /// answering without a result (a headless engine never gets there).
  static const Duration foregroundGrace = Duration(seconds: 1);

  /// Links kept for `onLink` while nobody listens.
  static const int linkBufferSize = 16;

  /// How long the same URL, delivered through `handleUri` and through the
  /// platform channel, or twice through `handleUri`, counts as one delivery.
  static const Duration forwardedLinkWindow = Duration(seconds: 10);

  static const String _android = 'android';
  static const String _ios = 'ios';

  SdkOptions _options;
  final BeckLinkPlatform _platform;
  final SdkLogger _logger;
  final ApiClientFactory _createApiClient;
  final BufferedBroadcast<LinkEvent> _links;
  final BufferedBroadcast<Attribution> _attributions;
  final String? _platformName;
  final TargetPlatform _targetPlatform;
  final DateTime Function() _now;
  final Random? _random;

  late final AppLifecycleWatcher _lifecycle;
  late final LinkResolver _resolver;

  LogLevel _appLogLevel;
  ApiClient _api;
  LinkUrlRules _rules;

  final Completer<void> _storageReady = Completer<void>();
  SdkStateStore? _store;
  EventQueue? _queue;
  EventDelivery? _delivery;
  StreamSubscription<PlatformLink>? _linkSubscription;
  Future<Map<String, Object?>?>? _context;

  /// The app's latest `setTrackingEnabled` choice in this process; it wins
  /// over the stored one at once, before storage is even open.
  bool? _trackingChoice;

  /// Increases on every tracking change, so work started before it can tell
  /// it is stale.
  int _trackingGeneration = 0;

  final Completer<LinkEvent?> _initialLink = Completer<LinkEvent?>();
  final Completer<void> _attributionDecided = Completer<void>();
  Attribution? _attribution;
  Attribution? _lastEmittedAttribution;

  Future<void>? _firstOpenRun;
  Future<void> _linkWork = Future<void>.value();

  // In-memory, per process: URLs accepted from the platform channel and from
  // handleUri in the last [forwardedLinkWindow], by canonical URL, so one
  // open reported through both paths reaches the app once.
  final SeenLinks _platformRecent = SeenLinks(lifetime: forwardedLinkWindow);
  final SeenLinks _forwardedRecent = SeenLinks(lifetime: forwardedLinkWindow);
  bool _identityWaitingForSeed = false;
  bool _sessionStarted = false;
  bool _initSentThisSession = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------

  /// Starts watching the app's lifecycle on [binding] and runs the startup
  /// sequence in the background.
  void start(WidgetsBinding binding) {
    _lifecycle.attach(binding);
    unawaited(_startup());
  }

  /// Applies the options of a later `configure()` call. A new API key or
  /// API origin gets a new client (requests of the old one end, and the
  /// first open retries with the new one); the startup sequence does not
  /// run again.
  void reconfigure(SdkOptions next) {
    final previous = _options;
    if (next == previous) return;
    _options = next;
    _appLogLevel = next.logLevel;
    _applyLogLevel();
    if (next.apiKey != previous.apiKey ||
        next.apiBaseUrl != previous.apiBaseUrl) {
      _replaceApiClient(newKey: true);
    }
    if (next.handlePlatformLinks != previous.handlePlatformLinks) {
      _logger.info(
        'handlePlatformLinks changed; it is read once at start and applies '
        'from the next app launch',
      );
    }
    if (next.environment != previous.environment) {
      _rules = LinkUrlRules(
        environment: next.environment,
        linkHosts: _store?.effectiveRemoteConfig.linkHosts ?? const <String>[],
      );
    }
    _logger.info('Configuration updated: $next');
  }

  /// `setLogLevel()`: the app's level, which remote config can override.
  void setLogLevel(LogLevel level) {
    _appLogLevel = level;
    _applyLogLevel();
  }

  // ---------------------------------------------------------------------
  // Public operations
  // ---------------------------------------------------------------------

  /// `onLink`.
  Stream<LinkEvent> get links => _links.stream;

  /// `onAttribution`.
  Stream<Attribution> get attributions => _attributions.stream;

  /// `getInitialLink()`: the link that opened the app, once it is decided.
  Future<LinkEvent?> initialLink() async {
    if (!_initialLink.isCompleted && !await _waitForForeground()) {
      // Not in the foreground in time: there is no launch to wait for (a
      // headless engine or a background launch). A launch link found later
      // still reaches onLink.
      _completeInitialLink(null);
    }
    return _initialLink.future;
  }

  /// `getAttribution()`: the attribution once it is decided, or the current
  /// state when the app is not in the foreground in time.
  Future<Attribution> attribution() async {
    if (!_attributionDecided.isCompleted && await _waitForForeground()) {
      await _attributionDecided.future;
    }
    return _attribution ?? _unavailableAttribution();
  }

  /// `track()` with validated [input]: queued, or dropped while tracking is
  /// off (consent flows call `track()` everywhere, so this is not an error).
  Future<void> track(EventInput input) async {
    if (!_trackingEnabled) {
      _logger.debug('Tracking is disabled; event "${input.name}" dropped');
      return;
    }
    await _storageReady.future;
    final queue = _queue;
    final store = _store;
    if (_disposed || queue == null || store == null || !_trackingEnabled) {
      return;
    }
    await queue.enqueue(
      name: input.name,
      properties: input.properties,
      revenue: input.revenue,
      currency: input.currency,
      userId: store.userId,
    );
    _logger.debug('Queued event "${input.name}"');
  }

  /// `setUserId()` / `clearUserId()` with a validated ID or `null`.
  Future<void> setUserId(String? userId) async {
    await _storageReady.future;
    await _store?.setUserId(userId);
  }

  /// `createLink()`: the new link's URL.
  ///
  /// Throws an [ArgumentError] when [options] expires in the past or its
  /// data gets too large with `referrer_user_id`, and a `BeckLinkException`
  /// when the service refuses or cannot be reached.
  Future<String> createLink(LinkOptions options) async {
    final expiresAt = options.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(_now())) {
      throw ArgumentError.value(
        expiresAt,
        'options.expiresAt',
        'must be in the future',
      );
    }
    await _storageReady.future;
    try {
      return await _withCurrentClient(
        (client) => client.post(
          ApiEndpoint.links,
          body: _linkRequestBody(options),
          read: (response) => response.body.string('url'),
        ),
        stillWanted: () => !_disposed,
      );
    } on ApiClientClosedException {
      throw const BeckLinkException.network(
        message: 'The link was not created because the SDK was shut down. '
            'Try again.',
      );
    }
  }

  /// `setTrackingEnabled()` (PRV-002, §29).
  ///
  /// Off: requests that record data are cancelled, the queue is deleted,
  /// the install identity is forgotten (the app has no way to allow keeping
  /// it, §29) and attribution becomes `unavailable`; links still resolve
  /// without identifiers. On: a new install identity and first open.
  Future<void> setTrackingEnabled(bool enabled) async {
    final changed = enabled != _trackingEnabled;
    _trackingChoice = enabled;
    if (changed) {
      _trackingGeneration++;
      if (!enabled) _replaceApiClient(newKey: false);
    }
    await _storageReady.future;
    final store = _store;
    if (_disposed || store == null) return;
    await store.setTrackingEnabled(enabled);
    if (!changed) return;
    _logger.info('Tracking ${enabled ? 'enabled' : 'disabled'}');
    if (enabled) {
      await _applyTrackingOn();
    } else {
      await _applyTrackingOff();
    }
  }

  /// `flush()`: sends queued events now, waiting a bounded time.
  Future<void> flush() async {
    await _storageReady.future;
    await _delivery?.flushNow();
  }

  /// `debugResetInstall()`: forgets the install so the next launch is a
  /// first run on a new install.
  ///
  /// Only stored state changes: this process keeps its launch link and
  /// session, and the native layers read the install referrer and the
  /// pasteboard once per process, so the first open runs again only after
  /// a restart.
  Future<void> debugResetInstall() async {
    await _storageReady.future;
    final store = _store;
    final queue = _queue;
    if (_disposed || store == null || queue == null) return;
    // Work started before the reset (first open, init, an event batch) must
    // not store its result afterwards: the new generation makes it stale,
    // and the new client ends its requests.
    _trackingGeneration++;
    _trackingChoice = null;
    _identityWaitingForSeed = false;
    _replaceApiClient(newKey: false);
    await queue.clear();
    await store.resetInstall();
    _applyRemoteConfig(store.effectiveRemoteConfig);
    // The Keychain copy would turn the next launch into a reinstall of the
    // old install; an ID that was never sent makes it a new install.
    await _platform.saveInstallIdSeed(uuidV4(_random ?? Random.secure()));
    _setAttribution(_unavailableAttribution(), decided: true);
    _logger.info(
      'Install reset for testing; restart the app to run the first open '
      'again',
    );
  }

  /// `debugRunFirstOpen()`: sends the first open of this install now, when
  /// it has not succeeded yet, and waits at most [wait] for it to finish.
  ///
  /// A first open already in progress is awaited instead of started again.
  /// A deferred match is delivered on `onLink`. Throws a [StateError] when
  /// it cannot run: it already succeeded (reset the install first),
  /// tracking is off, the platform is not Android or iOS, or the service
  /// refused the key.
  Future<void> debugRunFirstOpen({
    Duration wait = const Duration(seconds: 30),
  }) async {
    await _storageReady.future;
    final store = _store;
    if (_disposed || store == null) return;
    final running = _firstOpenRun;
    if (running != null) await running.timeout(wait, onTimeout: () {});
    if (store.firstOpen is FirstOpenCompleted) {
      if (running != null) return;
      throw StateError(
        'The first open of this install already succeeded; call '
        'debugResetInstall() first to test it again.',
      );
    }
    if (!_trackingEnabled) {
      throw StateError('Tracking is off; the first open needs it.');
    }
    if (_platformName == null) {
      throw StateError('The first open runs on Android and iOS only.');
    }
    if (_api.isKeyRejected) {
      throw StateError(
        'The service refused the API key; configure() a valid key first.',
      );
    }
    if (store.identity == null) await _ensureIdentity();
    if (store.identity == null) {
      throw StateError(
        'The install ID cannot be read yet (iOS Keychain before the first '
        'unlock); try again in a moment.',
      );
    }
    if (_canStartFirstOpen()) {
      _logger.info('Running the first open again for testing');
      _startFirstOpen(
        launch: null,
        decidesInitialLink: false,
        deliverDeferred: true,
      );
    }
    final started = _firstOpenRun;
    if (started != null) await started.timeout(wait, onTimeout: () {});
  }

  /// `debugOpenLink()`: handles [url] as if the operating system had opened
  /// the app with it. Returns whether it is a Beck Link URL of this
  /// environment; only then it is resolved and delivered on `onLink`.
  Future<bool> debugOpenLink(String url) async {
    await _storageReady.future;
    if (_disposed || _store == null) return false;
    if (_rules.classify(url) == null) {
      _logIgnoredUrl(url);
      return false;
    }
    _onPlatformLink(PlatformLink(url: url, receivedAt: _now()));
    return true;
  }

  /// `isBeckLinkUri()`: whether [url] is a Beck Link URL of this
  /// environment, by the rules as known now (cached link hosts only once
  /// storage is open).
  bool isBeckLinkUrl(String url) => _rules.classify(url) != null;

  /// `handleUri()`: takes [url], received by the app by other means, like a
  /// link opened by the platform. Returns whether it is a Beck Link URL of
  /// this environment (it is then resolved and delivered on `onLink` in the
  /// background); never throws.
  Future<bool> handleUri(String url) async {
    await _storageReady.future;
    if (_disposed || _store == null) return false;
    if (_rules.classify(url) == null) {
      _logIgnoredUrl(url);
      return false;
    }
    final link = PlatformLink(url: url, receivedAt: _now());
    _linkWork = _linkWork.then(
      (_) => _guard(_handleForwardedLink(link), 'Handling a forwarded link'),
    );
    return true;
  }

  Future<void> _handleForwardedLink(PlatformLink raw) async {
    await _initialLink.future;
    if (_disposed) return;
    final url = _rules.classify(raw.url);
    if (url == null) return;
    final key = _canonicalUrl(raw.url);
    final now = _now();
    if (_platformRecent.contains(key, now) ||
        !_forwardedRecent.record(key, now)) {
      _logger.debug('A forwarded link was already delivered; ignored');
      return;
    }
    _logger.info('Received $url (forwarded by the app)');
    final event = await _resolver.resolve(
      raw,
      url,
      deadline: _options.firstOpenTimeout,
    );
    if (event != null && !_disposed) _deliverLink(event);
  }

  // The same URL can reach the app as text from the platform and as a parsed
  // Uri from another plugin; parsing normalizes the case of scheme and host.
  static String _canonicalUrl(String url) =>
      Uri.tryParse(url)?.toString() ?? url;

  /// `getDiagnostics()`: a snapshot of the stored state, once storage is
  /// open.
  Future<BeckLinkDiagnostics> diagnostics() async {
    await _storageReady.future;
    final store = _store;
    final record = store?.firstOpen;
    final identity = store?.identity;
    LinkEvent? linkEvent;
    String? unmatchedReason;
    DateTime? startedAt;
    DateTime? completedAt;
    final FirstOpenStatus status;
    switch (record) {
      case null:
      case FirstOpenNotStarted():
        status = FirstOpenStatus.notStarted;
      case FirstOpenInFlight():
        status = FirstOpenStatus.inFlight;
        startedAt = record.startedAt;
      case FirstOpenCompleted():
        status = FirstOpenStatus.completed;
        startedAt = record.startedAt;
        completedAt = record.completedAt;
        try {
          final reader = JsonReader(record.result);
          final event = reader.optionalObject('link_event');
          linkEvent = event == null ? null : readLinkEvent(event);
          unmatchedReason = reader.optionalString('unmatched_reason');
        } on FormatException catch (error) {
          _logger.error('The stored first-open answer is unreadable', error);
        }
    }
    return BeckLinkDiagnostics(
      sdkVersion: sdkVersion,
      environment: _options.environment.name,
      apiBaseUrl: _options.apiBaseUrl ?? productionBaseUrl,
      trackingEnabled: _trackingEnabled,
      apiKeyRejected: _api.isKeyRejected,
      installId: _trackingEnabled ? identity?.installId : null,
      installCreatedAt: _trackingEnabled ? identity?.createdAt : null,
      firstOpenStatus: status,
      firstOpenStartedAt: startedAt,
      firstOpenCompletedAt: completedAt,
      firstOpenLinkEvent: linkEvent,
      unmatchedReason: unmatchedReason,
      attribution: _attribution,
      remoteConfig: store?.effectiveRemoteConfig ?? RemoteConfig.defaults,
      remoteConfigReceived: store?.remoteConfig != null,
      queuedEvents: _queue?.length ?? 0,
      hasUserId: store?.userId != null,
    );
  }

  /// Stops everything: lifecycle watching, timers, requests, the queue.
  /// For tests; the app's runtime lives as long as the process.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycle.detach();
    _api.close();
    _completeInitialLink(null);
    _decideAttribution();
    await _linkSubscription?.cancel();
    await _delivery?.stop();
    await _queue?.close();
    await _store?.whenSaved();
  }

  // ---------------------------------------------------------------------
  // Startup
  // ---------------------------------------------------------------------

  Future<void> _startup() async {
    try {
      await _openStorage();
      if (_platformName == null) {
        _logger.error(
          'Beck Link supports Android and iOS. On ${_targetPlatform.name} '
          'the SDK resolves no links and sends no data',
        );
      }
      if (_trackingEnabled) {
        await _ensureIdentity();
      } else {
        await _applyTrackingOff();
      }
      _settleStoredAttribution();

      await _lifecycle.firstForeground;
      if (_disposed) return;
      // With handlePlatformLinks off the app forwards its links itself.
      final launch = _options.handlePlatformLinks
          ? await _platform.getInitialLink()
          : null;
      final store = _store!;
      final registeredBefore = store.firstOpen is FirstOpenCompleted;
      await _handleLaunchLink(launch);
      _sessionStarted = true;
      if (registeredBefore && _trackingEnabled) {
        unawaited(_guard(_sendInit(), 'Starting the session'));
      }
      _delivery?.trigger('launch');
    } catch (error) {
      // Only an SDK bug gets here (every stage handles its expected
      // failures). The app must not wait for decisions that will not come.
      _logger.error('The SDK could not finish starting', error);
      if (!_storageReady.isCompleted) _storageReady.complete();
      _completeInitialLink(null);
      _decideAttribution();
    }
  }

  Future<void> _openStorage() async {
    final path = await _platform.getStorageDirectory();
    final StorageDirectory directory;
    if (path == null) {
      _logger.info(
        'No storage directory is available; the SDK keeps its state in '
        'memory until the app restarts',
      );
      directory = MemoryStorageDirectory();
    } else {
      directory = FileStorageDirectory(Directory(path));
    }
    final (store, queue) = await (
      SdkStateStore.open(
        directory: directory,
        logger: _logger,
        now: _now,
        random: _random,
      ),
      EventQueue.open(
        directory: directory,
        logger: _logger,
        now: _now,
        random: _random,
      ),
    ).wait;
    _store = store;
    _queue = queue;
    final config = store.effectiveRemoteConfig;
    _applyRemoteConfig(config);
    _delivery = EventDelivery(
      queue: queue,
      logger: _logger,
      api: () => _api,
      sendingInstallId: _sendingInstallId,
      requestContext: _requestContext,
      now: _now,
    )..start(config.flushInterval);
    // The native layer buffers links until Dart listens; they are handled
    // after the launch link (see _onPlatformLink).
    if (_options.handlePlatformLinks) {
      _linkSubscription = _platform.links.listen(_onPlatformLink);
    }
    _storageReady.complete();
  }

  /// Creates the install identity on the first run, or keeps the platform
  /// copy (iOS Keychain) in step with the stored one.
  Future<void> _ensureIdentity() async {
    final store = _store!;
    final generation = _trackingGeneration;
    final existing = store.identity;
    if (existing != null) {
      _identityWaitingForSeed = false;
      // In the background: the launch link must not wait for the Keychain.
      unawaited(
        _guard(
          _keepSeedInStep(existing, generation),
          'Keeping the platform install ID in step',
        ),
      );
      return;
    }
    final seed = await _platform.getInstallIdSeed();
    if (!_isCurrentTracking(generation) || store.identity != null) return;
    final String? seedId;
    switch (seed) {
      case InstallIdSeedUnavailable():
        // Before the first unlock after a reboot the Keychain cannot be
        // read; a new ID now would later overwrite the one that tells the
        // service about a reinstall.
        _identityWaitingForSeed = true;
        _logger.info(
          'The install ID kept by the platform cannot be read yet; the '
          'install is registered when the app returns to the foreground',
        );
        return;
      case InstallIdSeedAbsent():
        seedId = null;
      case InstallIdSeedFound(:final installId):
        seedId = installId;
    }
    _identityWaitingForSeed = false;
    final identity = await store.ensureIdentity(platformInstallId: seedId);
    // Tracking turned off meanwhile deleted the identity; saving it now
    // would bring it back through the Keychain.
    if (!_isCurrentTracking(generation)) return;
    if (seedId == null || normalizeUuid(seedId) != identity.installId) {
      await _platform.saveInstallIdSeed(identity.installId);
    }
  }

  /// Writes the stored install ID to the platform (iOS Keychain) when the
  /// copy there is missing or differs: the stored ID wins, because this app
  /// container already sent events with it (T5).
  Future<void> _keepSeedInStep(
    InstallIdentity identity,
    int generation,
  ) async {
    final seed = await _platform.getInstallIdSeed();
    if (!_isCurrentTracking(generation) || _store?.identity != identity) {
      return;
    }
    final inStep = switch (seed) {
      // Cannot tell now; the next launch checks again.
      InstallIdSeedUnavailable() => true,
      InstallIdSeedFound(:final installId) =>
        normalizeUuid(installId) == identity.installId,
      InstallIdSeedAbsent() => false,
    };
    if (!inStep) await _platform.saveInstallIdSeed(identity.installId);
  }

  void _settleStoredAttribution() {
    final store = _store!;
    if (!_trackingEnabled) return;
    final record = store.firstOpen;
    if (record is! FirstOpenCompleted) return;
    try {
      _setAttribution(readStoredAttribution(record.result), decided: true);
    } on FormatException catch (error) {
      _logger.error('The stored attribution is unreadable', error);
      _setAttribution(_unavailableAttribution(), decided: true);
    }
  }

  // ---------------------------------------------------------------------
  // Links
  // ---------------------------------------------------------------------

  Future<void> _handleLaunchLink(PlatformLink? raw) async {
    if (_initialLink.isCompleted) {
      // getInitialLink() stopped waiting before the app was visible; the
      // launch link still reaches onLink, and a first open still runs, but
      // its deferred link is no longer delivered.
      if (raw != null) _onPlatformLink(raw);
      if (_canStartFirstOpen()) {
        _startFirstOpen(launch: null, decidesInitialLink: false);
      }
      return;
    }
    final launch = raw == null ? null : await _acceptLink(raw);
    if (_canStartFirstOpen()) {
      _startFirstOpen(launch: launch, decidesInitialLink: true);
      return;
    }
    _decideAttribution();
    await _resolveLaunchDirectly(launch);
  }

  Future<void> _resolveLaunchDirectly(_AcceptedLink? launch) async {
    if (launch == null) {
      _completeInitialLink(null);
      return;
    }
    final event = await _resolver.resolve(
      launch.link,
      launch.url,
      deadline: _options.firstOpenTimeout,
    );
    _completeInitialLink(event);
  }

  /// A link the operating system handed to the running app. Handled in
  /// arrival order, and only after the launch link, so `onLink` keeps the
  /// order the user opened them in.
  void _onPlatformLink(PlatformLink link) {
    _linkWork = _linkWork.then(
      (_) => _guard(_handleRunningLink(link), 'Handling a link'),
    );
  }

  Future<void> _handleRunningLink(PlatformLink raw) async {
    await _initialLink.future;
    if (_disposed) return;
    final accepted = await _acceptLink(raw);
    if (accepted == null) return;
    final event = await _resolver.resolve(
      accepted.link,
      accepted.url,
      deadline: _options.firstOpenTimeout,
    );
    if (event != null && !_disposed) _deliverLink(event);
  }

  /// [link] when it is a Beck Link URL of this environment that was not
  /// delivered before (§29 step 5: once per link), otherwise `null`.
  Future<_AcceptedLink?> _acceptLink(PlatformLink link) async {
    final url = _rules.classify(link.url);
    if (url == null) {
      _logIgnoredUrl(link.url);
      return null;
    }
    // The app forwarded the same URL with handleUri a moment ago.
    final canonical = _canonicalUrl(link.url);
    final now = _now();
    if (_forwardedRecent.contains(canonical, now)) {
      _logger.debug('A link was already delivered through handleUri; ignored');
      return null;
    }
    // URL plus the platform's receive time identifies one delivery: the
    // same delivery reported twice is dropped, the same link opened twice is
    // not (T5, T6).
    final key = '${link.url}\n${link.receivedAt.microsecondsSinceEpoch}';
    if (!await _store!.markLinkSeen(key)) {
      _logger.debug('A link delivery was reported twice; ignored');
      return null;
    }
    _platformRecent.record(canonical, now);
    _logger.info('Received $url');
    return (link: link, url: url);
  }

  void _completeInitialLink(LinkEvent? event) {
    if (_initialLink.isCompleted) return;
    _initialLink.complete(event);
    if (event != null) _deliverLink(event);
  }

  void _deliverLink(LinkEvent event) {
    _logger.info('Delivering $event');
    _links.add(event);
  }

  void _logIgnoredUrl(String url) {
    if (_rules.isOtherEnvironmentLink(url)) {
      final (linkEnvironment, keyEnvironment) = switch (_options.environment) {
        SdkEnvironment.live => ('test', 'live'),
        SdkEnvironment.test => ('live', 'test'),
      };
      _logger.error(
        'Ignored a link of the $linkEnvironment environment because the SDK '
        'is configured with a $keyEnvironment key. Use links and the '
        'publishable key of the same environment',
      );
      return;
    }
    final uri = Uri.tryParse(url);
    // Scheme and host only: the path of another tool's URL (an OAuth
    // callback) can carry a token.
    final shown =
        uri == null ? 'an unparsable URL' : '${uri.scheme}://${uri.host}';
    _logger.debug('Ignored $shown: not a Beck Link URL of this project');
  }

  // ---------------------------------------------------------------------
  // First open
  // ---------------------------------------------------------------------

  bool _canStartFirstOpen() {
    final store = _store;
    return !_disposed &&
        _firstOpenRun == null &&
        store != null &&
        _trackingEnabled &&
        _platformName != null &&
        store.identity != null &&
        store.firstOpen is! FirstOpenCompleted &&
        !_api.isKeyRejected;
  }

  void _startFirstOpen({
    required _AcceptedLink? launch,
    required bool decidesInitialLink,
    bool deliverDeferred = false,
  }) {
    final run = _guard(
      _firstOpen(
        launch: launch,
        decidesInitialLink: decidesInitialLink,
        deliverDeferred: deliverDeferred,
      ),
      'The first open',
    );
    _firstOpenRun = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_firstOpenRun, run)) _firstOpenRun = null;
      }),
    );
  }

  /// Sends the first open (contract section 8.2) and, when
  /// [decidesInitialLink], decides the initial link from its answer: the
  /// launch link resolved through `evidence.open_url`, or the deferred link
  /// when the app was not opened by a link. The decision falls back to "no
  /// match" (or the launch link built on the device) `firstOpenTimeout`
  /// after the request was sent; the request keeps retrying in the
  /// background for up to 24 hours. [deliverDeferred] (only
  /// `debugRunFirstOpen()`) delivers a deferred match on `onLink` even when
  /// this run does not decide the initial link.
  Future<void> _firstOpen({
    required _AcceptedLink? launch,
    required bool decidesInitialLink,
    bool deliverDeferred = false,
  }) async {
    final store = _store!;
    final generation = _trackingGeneration;
    // Whether this run still has to decide the initial link from its answer;
    // false once the launch link went to /v1/sdk/open instead.
    var decides = decidesInitialLink;
    LinkEvent? fallback() =>
        launch == null ? null : _resolver.offlineEvent(launch.link, launch.url);
    try {
      final evidence = await _gatherEvidence(launch);
      final identity = store.identity;
      if (!_isCurrentTracking(generation) ||
          identity == null ||
          store.firstOpen is FirstOpenCompleted) {
        // Tracking was turned off meanwhile.
        if (decides) {
          decides = false;
          await _resolveLaunchDirectly(launch);
        }
        return;
      }
      final sent = await store.beginFirstOpen(evidence);
      final covered = launch != null && sent['open_url'] == launch.url.received;
      if (decides && launch != null && !covered) {
        // The stored evidence names the URL of an earlier launch; this
        // launch's link is a direct open of its own (§14 priority 1).
        decides = false;
        unawaited(_guard(_resolveLaunchDirectly(launch), 'Resolving a link'));
      }
      final record = store.firstOpen;
      if (record is FirstOpenInFlight) {
        _setAttribution(
          Attribution(
            state: AttributionState.pending,
            installedAt: record.startedAt,
          ),
          decided: false,
        );
      }
      final context = (await _requestContext())!;
      final timeout = _options.firstOpenTimeout;
      final timer = Timer(timeout, () {
        if (decides && !_initialLink.isCompleted) {
          _logger.info(
            'No first-open answer within ${timeout.inMilliseconds} ms: the '
            'app gets no deferred link; the first open continues in the '
            'background',
          );
          _completeInitialLink(covered ? fallback() : null);
        }
        _decideAttribution();
      });
      try {
        final answer = await _withCurrentClient(
          (client) => client.post(
            ApiEndpoint.firstOpen,
            body: <String, Object?>{
              'install_id': identity.installId,
              'first_open_id': identity.firstOpenId,
              'user_id': store.userId,
              'context': context,
              'evidence': sent,
            },
            read: (response) => readFirstOpenAnswer(response.body),
          ),
          stillWanted: () => _isCurrentTracking(generation),
        );
        timer.cancel();
        await _onFirstOpenAnswer(
          answer,
          identity,
          generation,
          decides: decides,
          covered: covered,
          deliverDeferred: deliverDeferred,
        );
      } on BeckLinkException catch (error) {
        timer.cancel();
        _logApiFailure('The first open', error, transientAsError: true);
        if (decides) _completeInitialLink(covered ? fallback() : null);
        if (error.code == BeckLinkErrorCode.invalidKey ||
            error.code == BeckLinkErrorCode.invalidRequest) {
          _setAttribution(_unavailableAttribution(), decided: true);
        }
      } on ApiClientClosedException {
        // Tracking turned off, or the SDK shut down: not a failure.
        timer.cancel();
        if (decides) _completeInitialLink(covered ? fallback() : null);
      }
    } finally {
      if (decides) _completeInitialLink(fallback());
      _decideAttribution();
    }
  }

  Future<void> _onFirstOpenAnswer(
    FirstOpenAnswer answer,
    InstallIdentity identity,
    int generation, {
    required bool decides,
    required bool covered,
    required bool deliverDeferred,
  }) async {
    final store = _store!;
    // Consent withdrawn while the answer was on its way: keep nothing.
    if (!_isCurrentTracking(generation) ||
        store.identity?.firstOpenId != identity.firstOpenId) {
      return;
    }
    await store.completeFirstOpen(
      answer.toStoredJson(),
      firstOpenId: identity.firstOpenId,
    );
    await store.saveRemoteConfig(answer.config);
    _applyRemoteConfig(answer.config);
    // The first open registered this session; no init needed (§29 step 3).
    _initSentThisSession = true;
    _setAttribution(answer.attribution, decided: true);
    final event = answer.linkEvent;
    if (decides && !_initialLink.isCompleted) {
      // Covered launch: its resolution (or the deferred match evaluated
      // because it did not resolve). No launch link: only a deferred match
      // navigates; a direct match of an earlier launch's URL does not.
      _completeInitialLink(
        covered ? event : (event != null && event.isDeferred ? event : null),
      );
    } else if (event != null && event.isDeferred && deliverDeferred) {
      _deliverLink(event);
    } else if (event != null && event.isDeferred) {
      _logger.info(
        'A deferred link matched after firstOpenTimeout; it is not '
        'delivered',
      );
    }
    final reason = answer.unmatchedReason;
    _logger.info(
      'First open: ${answer.attribution.state.wireValue}'
      '${reason == null ? '' : ', no link matched ($reason)'}',
    );
    _delivery?.trigger('first open');
  }

  Future<Map<String, Object?>> _gatherEvidence(_AcceptedLink? launch) async {
    final evidence = <String, Object?>{};
    if (launch != null && launch.url.fitsRequest) {
      evidence['open_url'] = launch.url.received;
    }
    final record = _store!.firstOpen;
    final stored = record is FirstOpenInFlight
        ? record.evidence
        : const <String, Object?>{};
    if (_platformName == _android &&
        stored['android_install_referrer'] == null) {
      final referrer = await _readInstallReferrer();
      if (referrer != null) evidence['android_install_referrer'] = referrer;
    }
    // At most once per install: a stored member, even null, means it was
    // read before (the native layer reads once per process). Not when a
    // link opened the app: it wins over deferred evidence (contract 9.4),
    // so the user is spared the paste prompt.
    if (_platformName == _ios &&
        _options.enablePasteboard &&
        launch == null &&
        !stored.containsKey('ios_pasteboard_url')) {
      evidence['ios_pasteboard_url'] = await _readPasteboardClickUrl();
    }
    return evidence;
  }

  Future<String?> _readInstallReferrer() async {
    final result = await _platform.getInstallReferrer();
    switch (result) {
      case InstallReferrerFound(:final rawReferrer):
        if (rawReferrer.isEmpty) {
          _logger.debug('Google Play reported an empty install referrer');
          return null;
        }
        if (rawReferrer.runes.length > maxLinkUrlLength) {
          _logger.info(
            'The install referrer is longer than $maxLinkUrlLength '
            'characters and is not sent',
          );
          return null;
        }
        return rawReferrer;
      case InstallReferrerUnavailable(:final reason):
        _logger.debug('No install referrer (${reason.name})');
        return null;
    }
  }

  Future<String?> _readPasteboardClickUrl() async {
    final url = await _platform.readPasteboardUrl(
      allowedHosts: _rules.pasteboardHostPatterns,
    );
    if (url == null) return null;
    if (!_rules.acceptsPasteboardUrl(url)) {
      // Contract section 9.3: anything else is neither sent nor kept.
      _logger.info(
        'The pasteboard held a click URL of another host or environment; it '
        'was not used',
      );
      return null;
    }
    return url;
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  void _onForeground(Duration backgroundFor) {
    if (_disposed || !_sessionStarted) return;
    final newSession = backgroundFor > sessionTimeout;
    if (newSession) _initSentThisSession = false;
    if (newSession || _identityWaitingForSeed) {
      unawaited(_guard(_startSession(), 'Starting a session'));
    }
    _delivery?.onForeground();
  }

  void _onBackground() {
    if (_disposed) return;
    _delivery?.onBackground();
  }

  /// A new session: init, or until it succeeded the first open again
  /// (contract section 1.1).
  Future<void> _startSession() async {
    final store = _store;
    if (store == null || !_trackingEnabled || _platformName == null) return;
    if (store.identity == null) await _ensureIdentity();
    if (store.identity == null) return;
    if (store.firstOpen is FirstOpenCompleted) {
      await _sendInit();
    } else if (_canStartFirstOpen()) {
      _startFirstOpen(launch: null, decidesInitialLink: false);
    }
  }

  Future<void> _sendInit() async {
    final store = _store!;
    final identity = store.identity;
    final context = await _requestContext();
    if (_initSentThisSession ||
        identity == null ||
        context == null ||
        !_trackingEnabled ||
        _api.isKeyRejected) {
      return;
    }
    _initSentThisSession = true;
    final generation = _trackingGeneration;
    try {
      final config = await _api.post(
        ApiEndpoint.init,
        body: <String, Object?>{
          'install_id': identity.installId,
          'user_id': store.userId,
          'context': context,
        },
        read: (response) => readRemoteConfig(response.body.object('config')),
      );
      if (!_isCurrentTracking(generation)) return;
      await store.saveRemoteConfig(config);
      _applyRemoteConfig(config);
    } on BeckLinkException catch (error) {
      _logApiFailure('Starting the session (init)', error);
    } on ApiClientClosedException {
      // Tracking turned off or the SDK reconfigured; the next session sends
      // it again.
    }
  }

  // ---------------------------------------------------------------------
  // Tracking consent
  // ---------------------------------------------------------------------

  bool get _trackingEnabled =>
      _trackingChoice ?? _store?.trackingEnabled ?? true;

  bool _isCurrentTracking(int generation) =>
      !_disposed && _trackingEnabled && generation == _trackingGeneration;

  Future<void> _applyTrackingOff() async {
    final store = _store!;
    // Also on every launch while tracking stays off, in case an earlier
    // delete could not be written (T5).
    await _queue!.clear();
    if (store.identity != null) {
      await store.deleteIdentity();
      // The Keychain copy would survive and bring the old ID back; a random
      // ID that was never sent replaces it, so nothing links the device to
      // its past install.
      final random = _random ?? Random.secure();
      unawaited(
        _guard(
          _platform.saveInstallIdSeed(uuidV4(random)),
          'Replacing the platform install ID',
        ),
      );
    }
    _setAttribution(_unavailableAttribution(), decided: true);
  }

  Future<void> _applyTrackingOn() async {
    await _ensureIdentity();
    _settleStoredAttribution();
    if (_sessionStarted) await _startSession();
  }

  // ---------------------------------------------------------------------
  // Attribution
  // ---------------------------------------------------------------------

  void _setAttribution(Attribution value, {required bool decided}) {
    _attribution = value;
    if (decided && !_attributionDecided.isCompleted) {
      _attributionDecided.complete();
    }
    if (_attributionDecided.isCompleted) _emitAttribution();
  }

  /// Ends the wait for attribution with the current value (§29 step 6:
  /// `pending` when the first open is still on its way).
  void _decideAttribution() {
    _attribution ??= _unavailableAttribution();
    if (!_attributionDecided.isCompleted) _attributionDecided.complete();
    _emitAttribution();
  }

  void _emitAttribution() {
    final value = _attribution;
    if (value == null || value == _lastEmittedAttribution) return;
    _lastEmittedAttribution = value;
    _logger.info('Attribution: $value');
    _attributions.add(value);
  }

  Attribution _unavailableAttribution() {
    final current = _attribution;
    if (current != null && current.state == AttributionState.unavailable) {
      return current;
    }
    return Attribution(
      state: AttributionState.unavailable,
      installedAt: _store?.identity?.createdAt ?? _now(),
    );
  }

  // ---------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------

  Map<String, Object?> _linkRequestBody(LinkOptions options) {
    final store = _store;
    final body = options.toJson();
    final tracking = _trackingEnabled;
    final userId = tracking ? store?.userId : null;
    if (userId != null && !options.data.containsKey('referrer_user_id')) {
      // §14 referral payload; contract P13.
      final data = <String, Object?>{
        ...options.data,
        'referrer_user_id': userId,
      };
      final bytes = utf8.encode(jsonEncode(data)).length;
      if (bytes > LinkOptions.maxDataBytes) {
        throw ArgumentError(
          'data plus the referrer_user_id the SDK adds for the current user '
              'is $bytes bytes, over ${LinkOptions.maxDataBytes}; make data '
              'smaller or set referrer_user_id yourself',
          'options',
        );
      }
      body['data'] = data;
    }
    final installId = tracking ? store?.identity?.installId : null;
    if (installId != null) body['install_id'] = installId;
    return body;
  }

  /// Runs [call] with the current client, and again with the new one when
  /// `configure()` replaced the client meanwhile and [stillWanted] says the
  /// work is still wanted. Throws [ApiClientClosedException] otherwise.
  Future<T> _withCurrentClient<T>(
    Future<T> Function(ApiClient client) call, {
    required bool Function() stillWanted,
  }) async {
    while (true) {
      final client = _api;
      try {
        return await call(client);
      } on ApiClientClosedException {
        if (identical(client, _api) || !stillWanted()) rethrow;
      }
    }
  }

  /// Ends every request of the current client (it holds nothing a new one
  /// needs) and continues with a new one for the configured key.
  ///
  /// Without a [newKey], a client that saw its key refused is kept: it
  /// sends nothing (so nothing needs cancelling) until `configure()` brings
  /// another key (contract section 11.2: a refused key is not tried again).
  void _replaceApiClient({required bool newKey}) {
    final current = _api;
    if (!newKey && current.isKeyRejected) return;
    current.close();
    _api = _createApiClient(_options);
  }

  Future<Map<String, Object?>?> _requestContext() {
    final name = _platformName;
    if (name == null) return Future<Map<String, Object?>?>.value();
    return _context ??= _platform.getDeviceContext().then(
          (device) => Map<String, Object?>.unmodifiable(<String, Object?>{
            'platform': name,
            ...device.toJson(),
          }),
        );
  }

  String? _sendingInstallId() {
    final store = _store;
    if (_disposed ||
        store == null ||
        !_trackingEnabled ||
        _platformName == null ||
        _api.isKeyRejected ||
        store.firstOpen is! FirstOpenCompleted) {
      return null;
    }
    return store.identity?.installId;
  }

  OpenRequester _openRequester() {
    final store = _store;
    final identity = _trackingEnabled ? store?.identity : null;
    return (
      installId: identity?.installId,
      userId: identity == null ? null : store?.userId,
    );
  }

  void _applyRemoteConfig(RemoteConfig config) {
    _applyLogLevel();
    _rules = LinkUrlRules(
      environment: _options.environment,
      linkHosts: config.linkHosts,
    );
    _delivery?.updateInterval(config.flushInterval);
  }

  void _applyLogLevel() {
    _logger.level = _store?.remoteConfig?.logLevel ?? _appLogLevel;
  }

  /// Logs a request that failed for good. Failures the app's developer must
  /// fix are errors; network trouble is expected on phones and only info,
  /// unless [transientAsError] (the first open, which carries attribution).
  void _logApiFailure(
    String what,
    BeckLinkException error, {
    bool transientAsError = false,
  }) {
    switch (error.code) {
      case BeckLinkErrorCode.invalidKey:
      case BeckLinkErrorCode.invalidRequest:
      case BeckLinkErrorCode.linkNotFound:
      case BeckLinkErrorCode.notConfigured:
      case BeckLinkErrorCode.trackingDisabled:
        _logger.error('$what failed', error);
      case BeckLinkErrorCode.network:
      case BeckLinkErrorCode.timeout:
      case BeckLinkErrorCode.rateLimited:
        if (transientAsError) {
          _logger.error('$what failed; it is tried again later', error);
        } else {
          _logger.info('$what failed; it is tried again later', error);
        }
    }
  }

  Future<bool> _waitForForeground() {
    if (_lifecycle.hasBeenInForeground) return Future<bool>.value(true);
    return _lifecycle.firstForeground.then((_) => true).timeout(
          _options.firstOpenTimeout + foregroundGrace,
          onTimeout: () => false,
        );
  }

  /// Runs [work] and logs instead of throwing: background work of the SDK
  /// must never surface as an unhandled error in the app.
  Future<void> _guard(Future<void> work, String what) async {
    try {
      await work;
    } catch (error) {
      _logger.error('$what failed unexpectedly', error);
    }
  }

  // Plain comparisons rather than an exhaustive switch: a TargetPlatform
  // value added by a later Flutter must not break compiling this package.
  static String? _wireNameOf(TargetPlatform platform) {
    if (platform == TargetPlatform.android) return _android;
    if (platform == TargetPlatform.iOS) return _ios;
    return null;
  }
}
