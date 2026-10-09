import 'dart:async';
import 'dart:convert';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/foundation.dart';

import 'activity_log.dart';
import 'config/config_store.dart';
import 'config/debug_config.dart';
import 'sdk_log_buffer.dart';
import 'sdk_setup.dart';

/// A link the app received on `onLink`, numbered in arrival order.
@immutable
class IncomingLink {
  const IncomingLink({
    required this.id,
    required this.receivedAt,
    required this.event,
  });

  /// Position in [DemoState.incomingLinks], used in the detail route.
  final int id;

  /// When the app received it, in local time.
  final DateTime receivedAt;
  final LinkEvent event;

  Map<String, Object?> toJson() => <String, Object?>{
    'received_at': receivedAt.toUtc().toIso8601String(),
    'link_event': event.toJson(),
  };
}

/// The example's calls into the SDK and what the screens show about it.
///
/// The SDK has no getters for the tracking choice or the user ID: the app
/// owns those decisions and keeps them itself (a real app stores its
/// consent result, for example). This demo only remembers what was set in
/// the current session.
class DemoState extends ChangeNotifier {
  /// [initialLogLevel] is the level `configure()` was given. [configStore]
  /// keeps the configuration entered on the Configure screen; without it
  /// (tests) nothing is saved.
  DemoState({
    required SdkSetup setup,
    required this.logs,
    required LogLevel initialLogLevel,
    this.configStore,
    DebugConfig? config,
    ActivityLog? activity,
  }) : _currentSetup = setup,
       _activeConfig = config,
       _logLevel = initialLogLevel,
       activity = activity ?? ActivityLog() {
    // May be listened to before or without configure(); the SDK keeps the
    // newest value (attribution) or the last records (requests) for a late
    // listener.
    _attributions = BeckLink.instance.onAttribution.listen(_setAttribution);
    _apiCalls = BeckLink.instance.onApiCall.listen(_onApiCall);
  }

  final SdkLogBuffer logs;
  final ActivityLog activity;
  final ConfigStore? configStore;

  late final StreamSubscription<Attribution> _attributions;
  late final StreamSubscription<BeckLinkApiCall> _apiCalls;

  SdkSetup _currentSetup;
  DebugConfig? _activeConfig;
  String? _configureError;
  final List<IncomingLink> _incomingLinks = <IncomingLink>[];
  Attribution? _attribution;
  BeckLinkDiagnostics? _diagnostics;
  String? _diagnosticsError;
  Timer? _diagnosticsTimer;
  bool? _trackingChoice;
  bool _userIdChanged = false;
  String? _userId;
  LogLevel _logLevel;
  int _trackedEvents = 0;
  bool _disposed = false;

  /// How starting the SDK went.
  SdkSetup get setup => _currentSetup;

  /// The configuration the SDK was started with, or `null` before one was
  /// entered.
  DebugConfig? get config => _activeConfig;

  /// Why the last Save & initialize failed, or `null`.
  String? get configureError => _configureError;

  /// Whether `configure()` succeeded, so SDK calls can be made.
  bool get isConfigured => _currentSetup is SdkConfigured;

  /// Whether every incoming link opens the link detail screen.
  bool get openEveryLinkInDetail =>
      _activeConfig?.openEveryLinkInDetail ?? false;

  /// Links received in this session, oldest first.
  List<IncomingLink> get incomingLinks =>
      List<IncomingLink>.unmodifiable(_incomingLinks);

  /// The newest link the app received through `onLink`.
  LinkEvent? get lastLink =>
      _incomingLinks.isEmpty ? null : _incomingLinks.last.event;

  /// When the app received [lastLink], in local time.
  DateTime? get lastLinkReceivedAt =>
      _incomingLinks.isEmpty ? null : _incomingLinks.last.receivedAt;

  /// The newest link that opened the installed app (not deferred): the
  /// re-engagement the SDK reported through `/v1/sdk/open`.
  IncomingLink? get lastOpen {
    for (final link in _incomingLinks.reversed) {
      if (!link.event.isDeferred) return link;
    }
    return null;
  }

  /// The newest attribution the SDK reported.
  Attribution? get attribution => _attribution;

  /// The SDK's latest diagnostics snapshot.
  BeckLinkDiagnostics? get diagnostics => _diagnostics;

  /// Why the last diagnostics refresh failed, or `null`.
  String? get diagnosticsError => _diagnosticsError;

  /// The tracking choice made in this session, or `null` when none was
  /// made (the SDK then applies the stored choice, on by default).
  bool? get trackingChoice => _trackingChoice;

  /// Whether the user ID was set or cleared in this session.
  bool get userIdChanged => _userIdChanged;

  /// The user ID set in this session; `null` after it was cleared.
  String? get userId => _userId;

  /// The log level the app set (remote config can override it).
  LogLevel get logLevel => _logLevel;

  /// Events tracked from this app in this session.
  int get trackedEvents => _trackedEvents;

  /// The incoming link numbered [id], or `null`.
  IncomingLink? incomingLink(int id) =>
      id >= 0 && id < _incomingLinks.length ? _incomingLinks[id] : null;

  /// Records a link `onLink` delivered and returns its record.
  IncomingLink recordLink(LinkEvent event) {
    final link = IncomingLink(
      id: _incomingLinks.length,
      receivedAt: DateTime.now(),
      event: event,
    );
    _incomingLinks.add(link);
    activity.addLink(event);
    _scheduleDiagnostics();
    notifyListeners();
    return link;
  }

  // ---------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------

  /// Saves [next] and starts the SDK with it, as the SDK's README shows:
  /// `configure()` (again, when it already runs: a new key or API origin
  /// applies at once), then the user ID.
  Future<String> applyConfig(DebugConfig next, {bool save = true}) async {
    if (save) await configStore?.save(next);
    _activeConfig = next;
    final origin = next.apiOrigin;
    if (origin == null) {
      return _configureFailed(
        'The SDK API base URL must be an http:// or https:// URL.',
      );
    }
    try {
      await BeckLink.instance.configure(
        apiKey: next.apiKey.trim(),
        logLevel: next.logLevel,
        enablePasteboard: next.enablePasteboard,
        apiBaseUrl: next.usesProduction ? null : origin,
      );
    } on BeckLinkException catch (error) {
      return _configureFailed(error.message);
    } on ArgumentError catch (error) {
      return _configureFailed('${error.message}');
    }
    _currentSetup = SdkConfigured.forKey(next.apiKey.trim());
    _configureError = null;
    _logLevel = next.logLevel;
    final userId = next.userId.trim();
    if (userId.isEmpty) {
      await BeckLink.instance.clearUserId();
      _userId = null;
    } else {
      try {
        await BeckLink.instance.setUserId(userId);
        _userId = userId;
      } on ArgumentError catch (error) {
        activity.addAction(
          'User ID not set',
          detail: '${error.message}',
          isError: true,
        );
      }
    }
    _userIdChanged = true;
    activity.addAction(
      'SDK initialized',
      detail: '${next.keyEnvironment} key ${maskSecret(next.apiKey)} → $origin',
    );
    notifyListeners();
    unawaited(refreshDiagnostics());
    return 'SDK initialized with the ${next.keyEnvironment} key';
  }

  String _configureFailed(String message) {
    _configureError = message;
    if (!isConfigured) _currentSetup = SdkSetupFailed(message);
    activity.addAction('configure() refused', detail: message, isError: true);
    notifyListeners();
    return 'Not initialized: $message';
  }

  /// Forgets the saved configuration. The SDK keeps running with the last
  /// one until the app restarts.
  Future<String> forgetConfig() async {
    await configStore?.clear();
    activity.addAction('Saved configuration deleted');
    return 'Saved configuration deleted. The SDK keeps the current one until '
        'the app restarts.';
  }

  // ---------------------------------------------------------------------
  // Diagnostics
  // ---------------------------------------------------------------------

  /// Asks the SDK for a new diagnostics snapshot.
  Future<void> refreshDiagnostics() async {
    if (!isConfigured || _disposed) return;
    try {
      final snapshot = await BeckLink.instance.getDiagnostics();
      if (_disposed) return;
      _diagnostics = snapshot;
      _diagnosticsError = null;
    } on BeckLinkException catch (error) {
      _diagnosticsError = error.message;
    }
    if (!_disposed) notifyListeners();
  }

  void _scheduleDiagnostics() {
    if (!isConfigured || _disposed) return;
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(refreshDiagnostics()),
    );
  }

  void _onApiCall(BeckLinkApiCall call) {
    activity.addCall(call);
    _scheduleDiagnostics();
  }

  // ---------------------------------------------------------------------
  // SDK actions
  // ---------------------------------------------------------------------

  /// Asks the SDK for the attribution again. On the first run this waits
  /// for the first open's answer, at most `firstOpenTimeout`.
  Future<String> refreshAttribution() async {
    final attribution = await BeckLink.instance.getAttribution();
    _setAttribution(attribution);
    return 'Attribution: ${attribution.state.wireValue}';
  }

  /// Tracks a demo purchase of [productId], with properties and revenue.
  Future<String> trackPurchase(String productId) async {
    await BeckLink.instance.track(
      'purchase',
      properties: <String, Object?>{
        'product_id': productId,
        'quantity': 1,
        'gift': false,
      },
      revenue: 9.99,
      currency: 'USD',
    );
    return _eventQueued('purchase');
  }

  /// Tracks a test event with properties and revenue.
  Future<String> trackTestEvent() async {
    await BeckLink.instance.track(
      'example_test_event',
      properties: <String, Object?>{
        'screen': 'debug',
        'attempt': _trackedEvents + 1,
        'test': true,
      },
      revenue: 1.5,
      currency: 'EUR',
    );
    return _eventQueued('example_test_event');
  }

  /// Tracks [name] with the flat JSON object [propertiesJson] (may be
  /// empty). With [withUserId], sets the configured user ID first, so the
  /// event carries it. Throws a [FormatException] for invalid JSON and an
  /// [ArgumentError] for what the SDK refuses.
  Future<String> trackCustomEvent(
    String name,
    String propertiesJson, {
    bool withUserId = false,
  }) async {
    final properties = parseJsonObject(propertiesJson);
    if (withUserId) {
      final userId = (_activeConfig?.userId ?? '').trim();
      if (userId.isEmpty) {
        throw ArgumentError(
          'set a user ID on the Configure screen first',
          'userId',
        );
      }
      await setUserId(userId);
    }
    await BeckLink.instance.track(name.trim(), properties: properties);
    await BeckLink.instance.flush();
    return '${_eventQueued(name.trim())} Flushed.';
  }

  /// Sends queued events now.
  Future<String> flush() async {
    await BeckLink.instance.flush();
    activity.addAction('flush()');
    _scheduleDiagnostics();
    return 'Flush finished. Events that could not be sent stay queued; '
        'the timeline shows what was delivered.';
  }

  /// Creates a link that opens the product screen of [productId].
  Future<String> createProductLink(String productId) =>
      BeckLink.instance.createLink(
        LinkOptions(
          deepLinkPath: '/product/$productId',
          data: <String, Object?>{'product_id': productId},
          source: 'example_app',
          medium: 'share',
        ),
      );

  /// Creates a link with [deepLinkPath] and the JSON object [dataJson]
  /// through the SDK (`sdk:links` scope). Throws a [FormatException] for
  /// invalid JSON.
  Future<String> createCustomLink(String deepLinkPath, String dataJson) async {
    final data = parseJsonObject(dataJson);
    final url = await BeckLink.instance.createLink(
      LinkOptions(
        deepLinkPath: deepLinkPath.trim(),
        data: data,
        source: 'debug_app',
        medium: 'sdk',
      ),
    );
    activity.addAction('Link created', detail: url);
    return url;
  }

  /// Sets [userId] as the signed-in user and creates an invite link. While
  /// tracking is on, the SDK adds the user ID to the link's data as
  /// `referrer_user_id`.
  Future<String> createReferralLink(String userId) async {
    await setUserId(userId);
    return BeckLink.instance.createLink(
      LinkOptions(
        deepLinkPath: '/referral',
        source: 'example_app',
        medium: 'referral',
      ),
    );
  }

  /// Hands [url] to the SDK as if the system had opened the app with it.
  Future<String> openLink(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('Enter a full URL, starting with https://');
    }
    final accepted = await BeckLink.instance.debugOpenLink(uri);
    activity.addAction(
      accepted ? 'Link handed to the SDK' : 'Link ignored by the SDK',
      detail: '${uri.scheme}://${uri.host}${uri.path}',
      isError: !accepted,
    );
    if (accepted) {
      return 'The SDK accepted the link and is resolving it; the app opens '
          'it when onLink delivers it.';
    }
    final environment = switch (_currentSetup) {
      SdkConfigured(:final environment) => environment,
      SdkKeyMissing() || SdkSetupFailed() => 'configured',
    };
    return 'Not a Beck Link URL of the $environment environment: it must be '
        'https://{host}/{short path} on a $environment link host (or a host '
        'in the remote config), or {scheme}://becklink?url=…';
  }

  /// Runs the first open again without a restart (debug builds).
  Future<String> runFirstOpen() async {
    activity.addAction('debugRunFirstOpen()');
    try {
      await BeckLink.instance.debugRunFirstOpen();
    } on StateError catch (error) {
      activity.addAction(
        'First open not run',
        detail: error.message,
        isError: true,
      );
      return error.message;
    }
    await refreshDiagnostics();
    final snapshot = _diagnostics;
    if (snapshot == null) return 'First open finished';
    final event = snapshot.firstOpenLinkEvent;
    final reason = snapshot.unmatchedReason;
    final outcome = event != null
        ? 'matched ${event.path} (${event.matchMethod.wireValue}, '
              '${event.confidence.wireValue})'
        : 'no link matched${reason == null ? '' : ' ($reason)'}';
    return 'First open ${snapshot.firstOpenStatus.wireValue}: $outcome';
  }

  /// Turns tracking on or off, as a consent dialog would.
  Future<String> setTrackingEnabled(bool enabled) async {
    await BeckLink.instance.setTrackingEnabled(enabled);
    _trackingChoice = enabled;
    activity.addAction('setTrackingEnabled($enabled)');
    _scheduleDiagnostics();
    notifyListeners();
    return enabled
        ? 'Tracking on. The device counts as a new install from now on.'
        : 'Tracking off. Queued events and the install ID were deleted.';
  }

  /// Sets the user ID; throws an [ArgumentError] for an invalid one.
  Future<String> setUserId(String userId) async {
    await BeckLink.instance.setUserId(userId);
    _userIdChanged = true;
    _userId = userId;
    activity.addAction('setUserId()', detail: maskSecret(userId));
    notifyListeners();
    return 'User ID set';
  }

  /// Forgets the user ID, as on sign-out.
  Future<String> clearUserId() async {
    await BeckLink.instance.clearUserId();
    _userIdChanged = true;
    _userId = null;
    activity.addAction('clearUserId()');
    notifyListeners();
    return 'User ID cleared';
  }

  /// Sets how much the SDK logs.
  void setLogLevel(LogLevel level) {
    BeckLink.instance.setLogLevel(level);
    _logLevel = level;
    notifyListeners();
  }

  /// Debug builds only: forgets the install for a new deferred-link test.
  Future<void> resetInstall() async {
    await BeckLink.instance.debugResetInstall();
    // The SDK forgot the user ID and the tracking choice too.
    _trackingChoice = null;
    _userIdChanged = true;
    _userId = null;
    _trackedEvents = 0;
    activity.addAction('debugResetInstall()');
    notifyListeners();
    await refreshDiagnostics();
  }

  // ---------------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------------

  /// Everything the screens show, as pretty JSON to paste into a chat with
  /// the developer. Keys and the user ID are masked; the SDK's own log
  /// lines are already redacted by the SDK.
  Future<String> debugReport() async {
    await refreshDiagnostics();
    final setup = _currentSetup;
    final report = <String, Object?>{
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'app': <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'debug_build': kDebugMode,
        'sdk_version': BeckLink.version,
      },
      'setup': switch (setup) {
        SdkConfigured(:final environment) => 'configured ($environment)',
        SdkKeyMissing() => 'not configured',
        SdkSetupFailed(:final message) => 'failed: $message',
      },
      'configure_error': _configureError,
      'config': _activeConfig?.toReportJson(),
      'diagnostics': _diagnostics?.toJson(),
      'attribution': _attribution?.toJson(),
      'incoming_links': <Object?>[
        for (final link in _incomingLinks.reversed.take(20)) link.toJson(),
      ],
      'timeline': <Object?>[
        for (final entry in activity.newestFirst.take(100)) entry.toJson(),
      ],
      'sdk_log': <Object?>[
        for (final line in logs.newestFirst.take(100))
          '${line.time.toUtc().toIso8601String()} ${line.level} '
              '${line.message}',
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(report);
  }

  String _eventQueued(String name) {
    _trackedEvents++;
    activity.addAction('track("$name")');
    _scheduleDiagnostics();
    notifyListeners();
    return 'Event "$name" queued. It goes out with the next batch (every '
        '15 s by default, at 20 events, or when the app goes to the '
        'background); while tracking is off it is dropped.';
  }

  void _setAttribution(Attribution attribution) {
    if (attribution == _attribution) return;
    _attribution = attribution;
    _scheduleDiagnostics();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _diagnosticsTimer?.cancel();
    unawaited(_attributions.cancel());
    unawaited(_apiCalls.cancel());
    super.dispose();
  }
}

/// [text] as a JSON object; empty text is an empty object. Throws a
/// [FormatException] for anything else.
Map<String, Object?> parseJsonObject(String text) {
  if (text.trim().isEmpty) return <String, Object?>{};
  final value = jsonDecode(text);
  if (value is! Map<String, Object?>) {
    throw const FormatException('Enter a JSON object, for example {"a": 1}');
  }
  return value;
}
