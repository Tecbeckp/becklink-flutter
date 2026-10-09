import 'dart:math';

import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

/// A clock the test moves by hand.
final class TestClock {
  TestClock([DateTime? start])
      : _now = (start ?? DateTime.utc(2026, 10, 7, 12)).toUtc();

  DateTime _now;

  /// The current time; pass the tear-off `clock.now` as an SDK clock.
  DateTime now() => _now;

  /// Moves the clock forward by [duration] (backward when negative).
  void advance(Duration duration) => _now = _now.add(duration);
}

/// A [Random] whose `nextDouble` is always [value], so jittered backoff is
/// predictable: the wait is [value] times the backoff ceiling.
final class FixedRandom implements Random {
  FixedRandom(this.value) : assert(value >= 0 && value < 1, 'in [0, 1)');

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor();

  @override
  bool nextBool() => value >= 0.5;
}

/// One line the SDK logged.
typedef LogLine = ({LogLevel level, String message});

/// Collects what the SDK logs; pass [add] as the `LogSink`.
final class LogCapture {
  /// Every line, in order.
  final List<LogLine> lines = <LogLine>[];

  /// The SDK's `LogSink`.
  void add(LogLevel level, String message) =>
      lines.add((level: level, message: message));

  /// Messages logged at [level].
  List<String> at(LogLevel level) => <String>[
        for (final line in lines)
          if (line.level == level) line.message,
      ];

  /// Every message, one per line, for "never logs" checks.
  String get text => lines.map((line) => line.message).join('\n');
}

/// Sends the app lifecycle [state] to the framework as the engine does, so
/// `WidgetsBindingObserver`s (the SDK's lifecycle watcher) see it.
Future<void> setAppLifecycle(AppLifecycleState state) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    SystemChannels.lifecycle.name,
    SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
    (_) {},
  );
}

/// Waits (in real time) until [condition] holds, failing the test after
/// [timeout].
Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'The condition did not become true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets pending microtasks and short timers run (real time).
Future<void> settle([
  Duration duration = const Duration(milliseconds: 50),
]) =>
    Future<void>.delayed(duration);

/// Typed access to decoded JSON in assertions.
extension JsonAccess on Map<String, Object?> {
  /// The object member [key].
  Map<String, Object?> obj(String key) => this[key]! as Map<String, Object?>;

  /// The array member [key].
  List<Object?> list(String key) => this[key]! as List<Object?>;

  /// The array member [key], whose items are objects.
  List<Map<String, Object?>> objects(String key) =>
      list(key).cast<Map<String, Object?>>();
}

/// Matches a lowercase 8-4-4-4-12 UUID.
final Matcher isLowercaseUuid = matches(
  RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
);
