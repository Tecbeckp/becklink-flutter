import 'package:meta/meta.dart';

import 'attribution.dart';
import 'link_event.dart';
import 'remote_config.dart';

/// Where the first open of the current install stands.
enum FirstOpenStatus {
  /// Not sent yet: no install ID (tracking off, or the install was just
  /// reset), or the app has not reached the foreground.
  notStarted('not_started'),

  /// Sent at least once and not answered yet; the SDK keeps retrying.
  inFlight('in_flight'),

  /// Answered and stored; it is never sent again for this install.
  completed('completed');

  const FirstOpenStatus(this.wireValue);

  /// The snake_case form used in debug reports.
  final String wireValue;
}

/// A snapshot of the SDK's state for debug and support screens, from
/// `BeckLink.getDiagnostics()`.
///
/// Holds the install ID (a random ID of this install, useful to find it in
/// the dashboard) but never the API key or the user ID. Link data in
/// [firstOpenLinkEvent] comes from the link and is untrusted input.
@immutable
final class BeckLinkDiagnostics {
  /// Creates a snapshot; the times are converted to UTC.
  BeckLinkDiagnostics({
    required this.sdkVersion,
    required this.environment,
    required this.apiBaseUrl,
    required this.trackingEnabled,
    required this.apiKeyRejected,
    required this.firstOpenStatus,
    required this.remoteConfig,
    required this.remoteConfigReceived,
    required this.queuedEvents,
    required this.hasUserId,
    this.installId,
    DateTime? installCreatedAt,
    DateTime? firstOpenStartedAt,
    DateTime? firstOpenCompletedAt,
    this.firstOpenLinkEvent,
    this.unmatchedReason,
    this.attribution,
  })  : installCreatedAt = installCreatedAt?.toUtc(),
        firstOpenStartedAt = firstOpenStartedAt?.toUtc(),
        firstOpenCompletedAt = firstOpenCompletedAt?.toUtc();

  /// The SDK's version, as sent in `X-SDK-Version`.
  final String sdkVersion;

  /// The project environment of the configured key: `test` or `live`.
  final String environment;

  /// The SDK API origin the SDK talks to.
  final Uri apiBaseUrl;

  /// Whether tracking is on (`setTrackingEnabled`).
  final bool trackingEnabled;

  /// Whether the service refused the API key (`401`); the SDK then sends
  /// nothing until `configure()` gets another key.
  final bool apiKeyRejected;

  /// The install ID, or `null` while there is none (tracking off, or the
  /// install was just reset).
  final String? installId;

  /// When the install ID was created on this device.
  final DateTime? installCreatedAt;

  /// Where the first open stands.
  final FirstOpenStatus firstOpenStatus;

  /// When the first open was first sent.
  final DateTime? firstOpenStartedAt;

  /// When the first open's answer arrived.
  final DateTime? firstOpenCompletedAt;

  /// The link the first open matched (a deferred match, or the link that
  /// launched the first run), or `null` when it matched none or has not
  /// been answered.
  final LinkEvent? firstOpenLinkEvent;

  /// Why the first open matched no link (contract section 9.5, for example
  /// `no_evidence` or `click_not_found`), or `null`.
  final String? unmatchedReason;

  /// The install's current attribution, or `null` before it is known.
  final Attribution? attribution;

  /// The remote config in effect: the last one the service sent (first open
  /// or init), or [RemoteConfig.defaults].
  final RemoteConfig remoteConfig;

  /// Whether [remoteConfig] came from the service rather than the defaults.
  final bool remoteConfigReceived;

  /// Events stored on the device and not delivered yet.
  final int queuedEvents;

  /// Whether a user ID is set (the ID itself is not included).
  final bool hasUserId;

  /// A JSON form for debug reports.
  Map<String, Object?> toJson() => <String, Object?>{
        'sdk_version': sdkVersion,
        'environment': environment,
        'api_base_url': apiBaseUrl.toString(),
        'tracking_enabled': trackingEnabled,
        'api_key_rejected': apiKeyRejected,
        'install_id': installId,
        'install_created_at': installCreatedAt?.toIso8601String(),
        'first_open': <String, Object?>{
          'status': firstOpenStatus.wireValue,
          'started_at': firstOpenStartedAt?.toIso8601String(),
          'completed_at': firstOpenCompletedAt?.toIso8601String(),
          'link_event': firstOpenLinkEvent?.toJson(),
          'unmatched_reason': unmatchedReason,
        },
        'attribution': attribution?.toJson(),
        'remote_config': remoteConfig.toJson(),
        'remote_config_received': remoteConfigReceived,
        'queued_events': queuedEvents,
        'has_user_id': hasUserId,
      };

  // The install ID and link data stay out of logs.
  @override
  String toString() => 'BeckLinkDiagnostics(sdkVersion: $sdkVersion, '
      'environment: $environment, firstOpen: ${firstOpenStatus.wireValue}, '
      'queuedEvents: $queuedEvents)';
}
