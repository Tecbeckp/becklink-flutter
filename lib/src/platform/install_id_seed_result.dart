import 'package:meta/meta.dart';

/// What looking up the install ID kept outside the app container (the iOS
/// Keychain) produced. Internal to the SDK.
///
/// [InstallIdSeedAbsent] and [InstallIdSeedUnavailable] are kept apart on
/// purpose: before the first unlock after a reboot the Keychain cannot be
/// read, and treating that as "nothing stored" would create a new install
/// ID and later overwrite the one that tells the service about a reinstall
/// (contract section 8.2).
@immutable
sealed class InstallIdSeedResult {
  const InstallIdSeedResult();
}

/// An install ID is stored. It is not validated here; the caller checks it
/// is a UUID (`SdkStateStore.ensureIdentity`).
final class InstallIdSeedFound extends InstallIdSeedResult {
  /// Creates the result.
  const InstallIdSeedFound(this.installId);

  /// The stored install ID.
  final String installId;

  @override
  bool operator ==(Object other) =>
      other is InstallIdSeedFound && other.installId == installId;

  @override
  int get hashCode => installId.hashCode;

  // The install ID identifies a person's device; it stays out of logs.
  @override
  String toString() => 'InstallIdSeedFound()';
}

/// Nothing is stored, or the platform keeps no install ID outside the app
/// container (Android, or the native plugin is not registered).
final class InstallIdSeedAbsent extends InstallIdSeedResult {
  /// Creates the result.
  const InstallIdSeedAbsent();

  @override
  bool operator ==(Object other) => other is InstallIdSeedAbsent;

  @override
  int get hashCode => (InstallIdSeedAbsent).hashCode;

  @override
  String toString() => 'InstallIdSeedAbsent()';
}

/// The store could not be read now (device locked since a reboot, no
/// answer in time, or a native failure); a later attempt may succeed.
final class InstallIdSeedUnavailable extends InstallIdSeedResult {
  /// Creates the result.
  const InstallIdSeedUnavailable();

  @override
  bool operator ==(Object other) => other is InstallIdSeedUnavailable;

  @override
  int get hashCode => (InstallIdSeedUnavailable).hashCode;

  @override
  String toString() => 'InstallIdSeedUnavailable()';
}
