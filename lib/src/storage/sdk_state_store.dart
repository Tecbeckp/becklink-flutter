import 'dart:math';

import '../json/json_reader.dart';
import '../json/json_value.dart';
import '../json/malformed_json_exception.dart';
import '../logging/sdk_logger.dart';
import '../models/remote_config.dart';
import '../util/uuid.dart';
import 'first_open_record.dart';
import 'install_identity.dart';
import 'json_document.dart';
import 'seen_links.dart';
import 'storage_directory.dart';

/// The SDK's persistent state apart from the event queue: install identity,
/// first-open progress, user ID, tracking consent, cached remote config and
/// recently delivered links. One document, `state.json`.
///
/// Reads are synchronous from memory; every change updates memory at once
/// and returns a future that completes when it is on disk. A failed write is
/// logged and the change still applies until the app restarts, so storage
/// trouble never breaks the app. Damaged parts of the stored document are
/// reset one by one and logged at error level. Use one store per directory
/// in a process. Internal to the SDK.
final class SdkStateStore {
  SdkStateStore._(
    this._document,
    this._logger,
    this._now,
    this._random,
    this._seenLinks,
  );

  /// Name of the document in the storage directory.
  static const String documentName = 'state.json';

  /// Layout version of the document this SDK writes (see
  /// [JsonDocument.schemaVersion]).
  static const int schemaVersion = 1;

  /// Opens the state stored in [directory], or empty state when there is
  /// none or it cannot be read.
  ///
  /// [now] and [random] replace the clock and the ID generator in tests;
  /// production uses [Random.secure], because IDs must not be guessable.
  static Future<SdkStateStore> open({
    required StorageDirectory directory,
    required SdkLogger logger,
    DateTime Function()? now,
    Random? random,
  }) async {
    final document = JsonDocument(
      name: documentName,
      schemaVersion: schemaVersion,
      directory: directory,
      logger: logger,
    );
    final store = SdkStateStore._(
      document,
      logger,
      now ?? DateTime.now,
      random ?? Random.secure(),
      SeenLinks(),
    );
    final reader = await document.load();
    if (reader != null && store._restore(reader)) await store._save();
    return store;
  }

  final JsonDocument _document;
  final SdkLogger _logger;
  final DateTime Function() _now;
  final Random _random;
  final SeenLinks _seenLinks;

  InstallIdentity? _identity;
  FirstOpenRecord _firstOpen = const FirstOpenNotStarted();
  String? _userId;
  bool? _trackingEnabled;
  RemoteConfig? _remoteConfig;

  /// The install identity, or `null` before [ensureIdentity] created one or
  /// after [deleteIdentity].
  InstallIdentity? get identity => _identity;

  /// First-open progress of the current identity; [FirstOpenNotStarted]
  /// while there is no identity.
  FirstOpenRecord get firstOpen => _firstOpen;

  /// The user ID the app set, or `null`.
  String? get userId => _userId;

  /// The app's tracking choice (PRV-002), or `null` when it never made one,
  /// so the configured default applies.
  bool? get trackingEnabled => _trackingEnabled;

  /// The last remote config received, or `null` before the first one; the
  /// SDK uses [RemoteConfig.defaults] until then (contract section 7.5).
  RemoteConfig? get remoteConfig => _remoteConfig;

  /// The config in effect: [remoteConfig], or [RemoteConfig.defaults] before
  /// the first one arrived (for example the 15 s flush interval).
  RemoteConfig get effectiveRemoteConfig =>
      _remoteConfig ?? RemoteConfig.defaults;

  /// Returns the install identity, creating and storing one on the first
  /// call.
  ///
  /// A new identity takes [platformInstallId] (the install ID the iOS
  /// Keychain kept from an earlier installation on this device) as its
  /// install ID when it is a usable UUID, so the service can tell a
  /// reinstall; otherwise it gets a new random UUID. The first-open ID is
  /// always new. An existing identity is returned unchanged, even when
  /// [platformInstallId] differs: events of this app container were already
  /// sent with it, so the caller writes it back to the platform instead.
  Future<InstallIdentity> ensureIdentity({String? platformInstallId}) async {
    final existing = _identity;
    if (existing != null) return existing;
    String? seed;
    if (platformInstallId != null) {
      seed = normalizeUuid(platformInstallId);
      if (seed == null) {
        // The value itself is an identifier and stays out of the log.
        _logger.error(
          'The install ID kept by the platform is not a UUID; a new install '
          'ID is created',
        );
      }
    }
    final identity = InstallIdentity(
      installId: seed ?? uuidV4(_random),
      firstOpenId: uuidV4(_random),
      createdAt: _now(),
    );
    _identity = identity;
    _firstOpen = const FirstOpenNotStarted();
    await _save();
    return identity;
  }

  /// Forgets the install identity and its first-open progress, for example
  /// when tracking is turned off and the app does not allow keeping the
  /// install ID (§29). The next [ensureIdentity] starts a new install.
  Future<void> deleteIdentity() async {
    if (_identity == null) return;
    _identity = null;
    _firstOpen = const FirstOpenNotStarted();
    await _save();
  }

  /// Forgets everything that belongs to this install, as on a fresh
  /// install: identity, first-open progress, user ID, tracking choice and
  /// cached remote config. For `debugResetInstall()`.
  ///
  /// Recently delivered links stay recorded: they identify deliveries, not
  /// the install, and a delivery the platform repeats must still not reach
  /// the app twice.
  Future<void> resetInstall() async {
    _identity = null;
    _firstOpen = const FirstOpenNotStarted();
    _userId = null;
    _trackingEnabled = null;
    _remoteConfig = null;
    await _save();
  }

  /// Marks first-open as sent and returns the `evidence` to send.
  ///
  /// On the first call [evidence] is stored as given. While first-open is in
  /// flight, every stored non-null evidence member wins over [evidence], and
  /// [evidence] fills only the members that were missing or `null`:
  /// evidence that can be read only once per install (the iOS pasteboard)
  /// must survive a retry after a restart, while evidence that arrived
  /// late can still join the next attempt.
  ///
  /// Throws a [StateError] when there is no identity or first-open already
  /// completed, and an [ArgumentError] when [evidence] holds a value that is
  /// not JSON.
  Future<Map<String, Object?>> beginFirstOpen(
    Map<String, Object?> evidence,
  ) async {
    _requireIdentity('beginFirstOpen');
    final fresh = checkJsonObjectArgument(evidence, 'evidence');
    final FirstOpenInFlight next;
    switch (_firstOpen) {
      case FirstOpenNotStarted():
        next = FirstOpenInFlight(startedAt: _now(), evidence: fresh);
      case FirstOpenInFlight(:final startedAt, evidence: final stored):
        final merged = _mergeEvidence(stored, fresh);
        if (jsonEquals(merged, stored)) return stored;
        next = FirstOpenInFlight(startedAt: startedAt, evidence: merged);
      case FirstOpenCompleted():
        throw StateError('First-open already completed for this install.');
    }
    _firstOpen = next;
    await _save();
    return next.evidence;
  }

  /// Stores the first-open answer [result] (SDK API JSON without `config`,
  /// which is cached with [saveRemoteConfig]) and drops the stored evidence,
  /// which is no longer needed.
  ///
  /// [firstOpenId] is the `first_open_id` the answered request carried; an
  /// answer for an identity that was deleted meanwhile (tracking turned
  /// off) is ignored, so it never lands on a newer identity. When first-open
  /// already completed, the first stored answer is kept: the service replays
  /// the same answer for the same `first_open_id`, so a second one adds
  /// nothing. Throws a [StateError] when first-open was never begun, and an
  /// [ArgumentError] when [result] holds a value that is not JSON.
  Future<void> completeFirstOpen(
    Map<String, Object?> result, {
    required String firstOpenId,
  }) async {
    final answer = checkJsonObjectArgument(result, 'result');
    if (_identity?.firstOpenId != firstOpenId) {
      _logger.debug('Ignored a first-open answer for a deleted identity');
      return;
    }
    switch (_firstOpen) {
      case FirstOpenNotStarted():
        throw StateError('completeFirstOpen() needs beginFirstOpen() first.');
      case FirstOpenInFlight(:final startedAt):
        _firstOpen = FirstOpenCompleted(
          startedAt: startedAt,
          completedAt: _now(),
          result: answer,
        );
      case FirstOpenCompleted():
        return;
    }
    await _save();
  }

  /// Stores the app's user ID, or forgets it when [userId] is `null`. The
  /// caller validates it (contract section 2).
  Future<void> setUserId(String? userId) async {
    if (userId == _userId) return;
    _userId = userId;
    await _save();
  }

  /// Stores the app's tracking choice (PRV-002).
  Future<void> setTrackingEnabled(bool enabled) async {
    if (enabled == _trackingEnabled) return;
    _trackingEnabled = enabled;
    await _save();
  }

  /// Caches [config], the newest remote config, until a newer one arrives
  /// (contract section 7.5).
  Future<void> saveRemoteConfig(RemoteConfig config) async {
    if (config == _remoteConfig) return;
    _remoteConfig = config;
    await _save();
  }

  /// Records the link delivery identified by [key] and returns whether it is
  /// new, that is, not delivered within the last 24 hours (see
  /// [SeenLinks]). The caller builds [key] from what identifies one
  /// delivery, such as the URL and the time the platform received it.
  Future<bool> markLinkSeen(String key) async {
    final isNew = _seenLinks.record(key, _now());
    await _save();
    return isNew;
  }

  /// Completes once every change made so far is on disk (or its write
  /// failed and was logged).
  Future<void> whenSaved() => _document.whenIdle();

  void _requireIdentity(String method) {
    if (_identity == null) {
      throw StateError('$method() needs an install identity first.');
    }
  }

  Future<void> _save() => _document.save(_toJson);

  Map<String, Object?> _toJson() {
    final identity = _identity;
    return <String, Object?>{
      'identity': identity == null
          ? null
          : <String, Object?>{
              ...identity.toJson(),
              'first_open': _firstOpen.toJson(),
            },
      'user_id': _userId,
      'tracking_enabled': _trackingEnabled,
      'remote_config': _remoteConfig?.toJson(),
      'seen_links': _seenLinks.toJson(),
    };
  }

  /// Loads the stored state from [reader], section by section, and returns
  /// whether something had to be reset, so the caller rewrites the document
  /// without it.
  bool _restore(JsonReader reader) {
    final damaged = <String>[];
    void section(String key, void Function() read) {
      try {
        read();
      } on MalformedJsonException catch (error) {
        damaged.add(error.pointer);
      } on FormatException {
        damaged.add('/$key');
      }
    }

    section('identity', () {
      final stored = reader.optionalObject('identity');
      if (stored == null) return;
      _identity = readInstallIdentity(stored);
      // First-open progress alone can be lost safely: a repeated first-open
      // with the same IDs gets the stored answer (contract section 6).
      section('identity/first_open', () {
        _firstOpen = readFirstOpenRecord(stored.object('first_open'));
      });
    });
    section('user_id', () {
      final userId = reader.optionalString('user_id');
      _userId = userId == null || userId.isEmpty ? null : userId;
    });
    section('tracking_enabled', () {
      _trackingEnabled = reader.optionalBoolean('tracking_enabled');
    });
    section('remote_config', () {
      final config = reader.optionalObject('remote_config');
      _remoteConfig = config == null ? null : readRemoteConfig(config);
    });
    section('seen_links', () {
      _seenLinks.restore(reader.objectList('seen_links'));
    });

    if (damaged.isEmpty) return false;
    _logger.error(
      'Parts of the stored SDK state were unreadable and were reset: '
      '${damaged.join(', ')}',
    );
    return true;
  }

  /// [fresh] with every non-null member of [stored] on top.
  static Map<String, Object?> _mergeEvidence(
    Map<String, Object?> stored,
    Map<String, Object?> fresh,
  ) =>
      <String, Object?>{
        ...fresh,
        for (final entry in stored.entries)
          if (entry.value != null) entry.key: entry.value,
      };
}
