import 'package:meta/meta.dart';

import 'native_time.dart';

/// What reading the Google Play Install Referrer produced (AND-005,
/// contract section 9.2). Expected failures are results, not exceptions,
/// so first-open can always go ahead without this evidence. Internal to the
/// SDK.
@immutable
sealed class InstallReferrerResult {
  const InstallReferrerResult();
}

/// Play reported the install referrer.
final class InstallReferrerFound extends InstallReferrerResult {
  /// Creates the result; the times are converted to UTC.
  InstallReferrerFound({
    required this.rawReferrer,
    DateTime? clickedAt,
    DateTime? installBeganAt,
  })  : clickedAt = clickedAt?.toUtc(),
        installBeganAt = installBeganAt?.toUtc();

  /// Play's `installReferrer` string, unchanged; normally
  /// `click_id=<ULID>`. Sent as `evidence.android_install_referrer` when it
  /// fits the contract's 2,048 characters, otherwise left out.
  final String rawReferrer;

  /// When the user clicked the Play Store link, by the device clock, or
  /// `null` when Play does not know.
  final DateTime? clickedAt;

  /// When the installation began, by the device clock, or `null` when Play
  /// does not know.
  final DateTime? installBeganAt;

  @override
  bool operator ==(Object other) =>
      other is InstallReferrerFound &&
      other.rawReferrer == rawReferrer &&
      other.clickedAt == clickedAt &&
      other.installBeganAt == installBeganAt;

  @override
  int get hashCode => Object.hash(rawReferrer, clickedAt, installBeganAt);

  // The referrer is evidence that ties this install to a click; it stays
  // out of logs.
  @override
  String toString() => 'InstallReferrerFound(length: ${rawReferrer.length}, '
      'clickedAt: ${clickedAt?.toIso8601String()}, '
      'installBeganAt: ${installBeganAt?.toIso8601String()})';
}

/// There is no install referrer, now or for good; see [reason].
final class InstallReferrerUnavailable extends InstallReferrerResult {
  /// Creates the result.
  const InstallReferrerUnavailable(this.reason);

  /// Why there is none.
  final InstallReferrerFailure reason;

  @override
  bool operator ==(Object other) =>
      other is InstallReferrerUnavailable && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'InstallReferrerUnavailable(${reason.name})';
}

/// Why an [InstallReferrerUnavailable] has no referrer.
enum InstallReferrerFailure {
  /// The platform has no install referrer (iOS), or the native plugin is not
  /// registered in this engine.
  notApplicable(null),

  /// Play's referrer service could not be reached or disconnected
  /// (`SERVICE_UNAVAILABLE`, `SERVICE_DISCONNECTED`, or no answer within the
  /// native layer's own deadline). A later attempt may succeed.
  serviceUnavailable('service_unavailable'),

  /// The device's Play Store app does not offer the referrer API, or there
  /// is no Play Store (`FEATURE_NOT_SUPPORTED`).
  featureNotSupported('feature_not_supported'),

  /// Play refused the request as malformed (`DEVELOPER_ERROR`).
  developerError('developer_error'),

  /// The app may not bind to Play's referrer service (`PERMISSION_ERROR`).
  permissionError('permission_error'),

  /// The native layer gave no answer within the Dart deadline. A later
  /// attempt may succeed.
  timeout(null),

  /// The native layer failed unexpectedly or answered in a shape this SDK
  /// version does not understand.
  platformError(null);

  const InstallReferrerFailure(this.nativeStatus);

  /// The `status` the native layer reports for this failure, or `null` for
  /// failures only Dart detects.
  final String? nativeStatus;

  /// Whether asking again later may produce the referrer.
  bool get isRetryable => switch (this) {
        serviceUnavailable || timeout => true,
        notApplicable ||
        featureNotSupported ||
        developerError ||
        permissionError ||
        platformError =>
          false,
      };
}

/// Native `status` of a successful read.
const String _okStatus = 'ok';

/// Reads the native answer to `getInstallReferrer` (see
/// `doc/platform-channel.md`), or returns `null` when it has a shape this
/// SDK version does not understand.
///
/// `null` from the native layer means the platform has no install referrer.
InstallReferrerResult? readInstallReferrer(Object? payload) {
  if (payload == null) {
    return const InstallReferrerUnavailable(
      InstallReferrerFailure.notApplicable,
    );
  }
  if (payload is! Map<Object?, Object?>) return null;
  final status = payload['status'];
  if (status == _okStatus) {
    final rawReferrer = payload['raw_referrer'];
    if (rawReferrer is! String) return null;
    return InstallReferrerFound(
      rawReferrer: rawReferrer,
      clickedAt: dateTimeFromEpochSeconds(payload['click_timestamp_seconds']),
      installBeganAt: dateTimeFromEpochSeconds(
        payload['install_begin_timestamp_seconds'],
      ),
    );
  }
  for (final failure in InstallReferrerFailure.values) {
    final nativeStatus = failure.nativeStatus;
    if (nativeStatus != null && nativeStatus == status) {
      return InstallReferrerUnavailable(failure);
    }
  }
  return null;
}
