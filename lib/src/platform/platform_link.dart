import 'package:meta/meta.dart';

import '../models/redaction.dart';
import 'native_time.dart';

/// A URL the operating system handed to the app (App Link, Universal Link
/// or custom-scheme URL) as the native layer reported it. Internal to the
/// SDK.
@immutable
final class PlatformLink {
  /// Creates a link; [receivedAt] is converted to UTC.
  PlatformLink({required this.url, required DateTime receivedAt})
      : receivedAt = receivedAt.toUtc();

  /// The URL exactly as the app received it (contract section 7.3 reports a
  /// direct open's URL unchanged). Not checked to be a Beck Link URL: the
  /// caller decides that before anything leaves the device (contract
  /// section 9.1).
  final String url;

  /// When the native layer received the URL from the operating system, by
  /// the device clock.
  ///
  /// It is the `opened_at` of the direct open (contract section 8.3) even
  /// when Dart reads a buffered link seconds later, and together with [url]
  /// it identifies one delivery, so a delivery reported twice can be told
  /// apart from the same link opened twice.
  final DateTime receivedAt;

  @override
  bool operator ==(Object other) =>
      other is PlatformLink &&
      other.url == url &&
      other.receivedAt == receivedAt;

  @override
  int get hashCode => Object.hash(url, receivedAt);

  // The query string can carry user data; it stays out of logs.
  @override
  String toString() {
    final uri = Uri.tryParse(url);
    final shown = uri == null ? withoutQuery(url) : describeUri(uri);
    return 'PlatformLink(url: $shown, '
        'receivedAt: ${receivedAt.toIso8601String()})';
  }
}

/// Longest URL accepted from the native layer, in UTF-16 code units.
///
/// Far above any real link (the SDK API takes at most 2,048 characters,
/// contract section 8.3); it only bounds what another app can push into this
/// one through a crafted intent or URL.
const int maxPlatformUrlLength = 16 * 1024;

/// Reads a link payload of the platform channel (`{url, received_at_ms}`,
/// see `doc/platform-channel.md`), or returns `null` when [payload] has
/// another shape or the URL is empty or longer than [maxPlatformUrlLength].
///
/// A missing or unusable `received_at_ms` falls back to [now]: a link must
/// not be lost over its timestamp.
PlatformLink? readPlatformLink(
  Object? payload, {
  required DateTime Function() now,
}) {
  if (payload is! Map<Object?, Object?>) return null;
  final url = payload['url'];
  if (url is! String || url.isEmpty || url.length > maxPlatformUrlLength) {
    return null;
  }
  return PlatformLink(
    url: url,
    receivedAt:
        dateTimeFromEpochMilliseconds(payload['received_at_ms']) ?? now(),
  );
}
