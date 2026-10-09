import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  group('RemoteConfig.fromJson', () {
    test('reads the contract example', () {
      final config = RemoteConfig.fromJson(configJson(logLevel: 'debug'));

      expect(config.logLevel, LogLevel.debug);
      expect(config.flushInterval, const Duration(seconds: 15));
      expect(config.linkHosts, <String>[testHost]);
      expect(config.features, isEmpty);
    });

    test('clamps the flush interval to 5–300 seconds', () {
      expect(
        RemoteConfig.fromJson(configJson(flushIntervalSeconds: 1))
            .flushInterval,
        RemoteConfig.minFlushInterval,
      );
      expect(
        RemoteConfig.fromJson(configJson(flushIntervalSeconds: 86400))
            .flushInterval,
        RemoteConfig.maxFlushInterval,
      );
    });

    test('accepts an integral double as the flush interval', () {
      final json = configJson()..['flush_interval_seconds'] = 30.0;

      expect(
        RemoteConfig.fromJson(json).flushInterval,
        const Duration(seconds: 30),
      );
    });

    test('refuses a fractional flush interval', () {
      final json = configJson()..['flush_interval_seconds'] = 7.5;

      expect(() => RemoteConfig.fromJson(json), throwsFormatException);
    });

    test('keeps the app level for an unknown log level', () {
      expect(
        RemoteConfig.fromJson(configJson(logLevel: 'verbose')).logLevel,
        isNull,
      );
    });

    test('lower-cases link hosts', () {
      final config = RemoteConfig.fromJson(
        configJson(linkHosts: <String>['Go.Acme.COM']),
      );

      expect(config.linkHosts, <String>['go.acme.com']);
    });

    test('reads feature flags and refuses non-boolean ones', () {
      final json = configJson()
        ..['features'] = <String, Object?>{'new_matcher': true};
      expect(
        RemoteConfig.fromJson(json).features,
        <String, bool>{'new_matcher': true},
      );

      json['features'] = <String, Object?>{'new_matcher': 'yes'};
      expect(() => RemoteConfig.fromJson(json), throwsFormatException);
    });

    test('refuses missing members', () {
      for (final key in <String>[
        'flush_interval_seconds',
        'link_hosts',
        'features',
      ]) {
        expect(
          () => RemoteConfig.fromJson(configJson()..remove(key)),
          throwsFormatException,
          reason: key,
        );
      }
    });

    test('round-trips through toJson', () {
      final config = RemoteConfig.fromJson(configJson(logLevel: 'info'));

      expect(RemoteConfig.fromJson(config.toJson()), config);
    });
  });

  group('RemoteConfig', () {
    test('defaults until the service sent a config', () {
      expect(RemoteConfig.defaults.logLevel, isNull);
      expect(RemoteConfig.defaults.flushInterval, const Duration(seconds: 15));
      expect(RemoteConfig.defaults.linkHosts, isEmpty);
    });

    test('refuses a flush interval outside the allowed range', () {
      expect(
        () => RemoteConfig(flushInterval: const Duration(seconds: 4)),
        throwsArgumentError,
      );
      expect(
        () => RemoteConfig(flushInterval: const Duration(seconds: 301)),
        throwsArgumentError,
      );
    });

    test('copies its collections', () {
      final hosts = <String>['a.example.com'];
      final config = RemoteConfig(linkHosts: hosts);
      hosts.add('b.example.com');

      expect(config.linkHosts, <String>['a.example.com']);
      expect(() => config.linkHosts.add('c'), throwsUnsupportedError);
    });
  });
}
