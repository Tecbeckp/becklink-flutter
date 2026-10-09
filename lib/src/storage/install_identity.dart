import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../util/uuid.dart';

/// The IDs that make this app container one install for the SDK API
/// (contract sections 2 and 8.2). Internal to the SDK.
@immutable
final class InstallIdentity {
  /// Creates an identity; [createdAt] is converted to UTC.
  InstallIdentity({
    required this.installId,
    required this.firstOpenId,
    required DateTime createdAt,
  }) : createdAt = createdAt.toUtc();

  /// The install ID: a UUID created on the first run, or on iOS the one the
  /// Keychain kept from an earlier installation on this device, so the
  /// service can tell a reinstall.
  final String installId;

  /// The first-open ID: a UUID created once per app container and never
  /// kept anywhere that survives uninstalling (contract P2). The same value
  /// makes first-open retries idempotent; a new value with a known
  /// [installId] tells the service the app was reinstalled.
  final String firstOpenId;

  /// When this identity was created on this device.
  final DateTime createdAt;

  /// The stored form.
  Map<String, Object?> toJson() => <String, Object?>{
        'install_id': installId,
        'first_open_id': firstOpenId,
        'created_at': createdAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is InstallIdentity &&
      other.installId == installId &&
      other.firstOpenId == firstOpenId &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(installId, firstOpenId, createdAt);

  // The IDs are identifiers of a person's device; they stay out of logs.
  @override
  String toString() =>
      'InstallIdentity(createdAt: ${createdAt.toIso8601String()})';
}

/// Reads the stored form of an [InstallIdentity]; throws a
/// `MalformedJsonException` when an ID is not a usable UUID.
InstallIdentity readInstallIdentity(JsonReader reader) => InstallIdentity(
      installId: _uuid(reader, 'install_id'),
      firstOpenId: _uuid(reader, 'first_open_id'),
      createdAt: reader.timestamp('created_at'),
    );

String _uuid(JsonReader reader, String key) =>
    normalizeUuid(reader.string(key)) ?? reader.fail(key, 'a UUID');
