import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../json/json_value.dart';
import 'log_level.dart';

/// Settings the Beck Link service sends to the SDK at session start.
///
/// The SDK keeps the last config it received and uses it until a newer one
/// arrives; until the first one arrives it uses [RemoteConfig.defaults].
@immutable
final class RemoteConfig {
  /// Creates a config.
  ///
  /// [linkHosts] are converted to lower case; [linkHosts] and [features] are
  /// copied into unmodifiable collections. Throws an [ArgumentError] when
  /// [flushInterval] is outside [minFlushInterval]–[maxFlushInterval].
  RemoteConfig({
    this.logLevel,
    Duration flushInterval = defaultFlushInterval,
    List<String> linkHosts = const <String>[],
    Map<String, bool> features = const <String, bool>{},
  })  : flushInterval = _checkFlushInterval(flushInterval),
        linkHosts = List<String>.unmodifiable(
          linkHosts.map((host) => host.toLowerCase()),
        ),
        features = Map<String, bool>.unmodifiable(features);

  /// Reads the SDK API JSON form (`config` in the contract).
  ///
  /// An unknown `log_level` reads as `null` (the app keeps its own level),
  /// and a `flush_interval_seconds` outside the allowed range is clamped to
  /// it. Throws a [FormatException] when a member is missing or has the
  /// wrong type.
  factory RemoteConfig.fromJson(Map<String, Object?> json) =>
      readRemoteConfig(JsonReader(json));

  /// The config used until the service sent one.
  static final RemoteConfig defaults = RemoteConfig();

  /// Shortest allowed [flushInterval].
  static const Duration minFlushInterval = Duration(seconds: 5);

  /// Longest allowed [flushInterval].
  static const Duration maxFlushInterval = Duration(seconds: 300);

  /// [flushInterval] until the service sent a config.
  static const Duration defaultFlushInterval = Duration(seconds: 15);

  /// A log level that overrides the app's own until the next config, or
  /// `null` to keep the app's level.
  final LogLevel? logLevel;

  /// How often queued events are sent.
  final Duration flushInterval;

  /// Link hosts of this project environment (the platform host and active
  /// custom domains), lower case and without a port.
  final List<String> linkHosts;

  /// Feature flags by name. The SDK ignores flags it does not know.
  final Map<String, bool> features;

  /// The SDK API JSON form (`config` in the contract).
  Map<String, Object?> toJson() => <String, Object?>{
        'log_level': logLevel?.wireValue,
        'flush_interval_seconds': flushInterval.inSeconds,
        'link_hosts': linkHosts,
        'features': features,
      };

  @override
  bool operator ==(Object other) =>
      other is RemoteConfig &&
      other.logLevel == logLevel &&
      other.flushInterval == flushInterval &&
      jsonEquals(other.linkHosts, linkHosts) &&
      jsonEquals(other.features, features);

  @override
  int get hashCode => Object.hash(
        logLevel,
        flushInterval,
        jsonHash(linkHosts),
        jsonHash(features),
      );

  @override
  String toString() => 'RemoteConfig(logLevel: ${logLevel?.wireValue}, '
      'flushInterval: ${flushInterval.inSeconds}s, linkHosts: $linkHosts, '
      'features: $features)';

  static Duration _checkFlushInterval(Duration interval) {
    if (interval < minFlushInterval || interval > maxFlushInterval) {
      throw ArgumentError(
        'must be between ${minFlushInterval.inSeconds} and '
            '${maxFlushInterval.inSeconds} seconds',
        'flushInterval',
      );
    }
    return interval;
  }
}

/// Reads a [RemoteConfig] from [reader]. Internal to the SDK.
RemoteConfig readRemoteConfig(JsonReader reader) {
  final logLevel = reader.optionalString('log_level');
  final seconds = reader.integer('flush_interval_seconds').clamp(
        RemoteConfig.minFlushInterval.inSeconds,
        RemoteConfig.maxFlushInterval.inSeconds,
      );
  return RemoteConfig(
    logLevel: logLevel == null ? null : LogLevel.tryFromWire(logLevel),
    flushInterval: Duration(seconds: seconds),
    linkHosts: reader.stringList('link_hosts'),
    features: reader.boolMap('features'),
  );
}
