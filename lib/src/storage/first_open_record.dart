import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../json/json_value.dart';

/// Where the first-open call of the current install identity stands
/// (contract section 8.2, requirements §29.1 "offline first-open").
///
/// `not_started` → `in_flight` (sent at least once, no answer stored yet;
/// kept across launches so the retry reuses the same `first_open_id` and
/// evidence) → `completed` (the answer is stored; first-open is never sent
/// again for this identity). Internal to the SDK.
@immutable
sealed class FirstOpenRecord {
  const FirstOpenRecord();

  /// The `state` value of the stored form.
  String get stateName;

  /// The stored form.
  Map<String, Object?> toJson();
}

/// First-open has not been sent for this identity yet.
final class FirstOpenNotStarted extends FirstOpenRecord {
  /// Creates the record.
  const FirstOpenNotStarted();

  @override
  String get stateName => 'not_started';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'state': stateName};

  @override
  bool operator ==(Object other) => other is FirstOpenNotStarted;

  @override
  int get hashCode => stateName.hashCode;

  @override
  String toString() => 'FirstOpenNotStarted()';
}

/// First-open was sent at least once and has no stored answer yet.
final class FirstOpenInFlight extends FirstOpenRecord {
  /// Creates the record; [startedAt] is converted to UTC and [evidence] is
  /// copied into an unmodifiable map. Throws an [ArgumentError] when
  /// [evidence] holds a value that is not JSON.
  FirstOpenInFlight({
    required DateTime startedAt,
    required Map<String, Object?> evidence,
  })  : startedAt = startedAt.toUtc(),
        evidence = checkJsonObjectArgument(evidence, 'evidence');

  /// When the first attempt started, kept across launches so the retry
  /// policy can measure how long first-open has been failing.
  final DateTime startedAt;

  /// The `evidence` object to send on every attempt. Kept because some of it
  /// can be read only once per install (the iOS pasteboard, IOS-005), and a
  /// retry after the app was killed must not lose it.
  final Map<String, Object?> evidence;

  @override
  String get stateName => 'in_flight';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'state': stateName,
        'started_at': startedAt.toIso8601String(),
        'evidence': evidence,
      };

  @override
  bool operator ==(Object other) =>
      other is FirstOpenInFlight &&
      other.startedAt == startedAt &&
      jsonEquals(other.evidence, evidence);

  @override
  int get hashCode => Object.hash(startedAt, jsonHash(evidence));

  // Evidence can carry a click ID or a launch URL; it stays out of logs.
  @override
  String toString() =>
      'FirstOpenInFlight(startedAt: ${startedAt.toIso8601String()})';
}

/// First-open succeeded and its answer is stored.
final class FirstOpenCompleted extends FirstOpenRecord {
  /// Creates the record; the times are converted to UTC and [result] is
  /// copied into an unmodifiable map. Throws an [ArgumentError] when
  /// [result] holds a value that is not JSON.
  FirstOpenCompleted({
    required DateTime startedAt,
    required DateTime completedAt,
    required Map<String, Object?> result,
  })  : startedAt = startedAt.toUtc(),
        completedAt = completedAt.toUtc(),
        result = checkJsonObjectArgument(result, 'result');

  /// When the first attempt started.
  final DateTime startedAt;

  /// When the answer arrived.
  final DateTime completedAt;

  /// The stored first-open answer in SDK API JSON form (`matched`,
  /// `link_event`, `attribution`, `unmatched_reason`), so attribution is
  /// available on later launches without asking the service again (§29.6).
  final Map<String, Object?> result;

  @override
  String get stateName => 'completed';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'state': stateName,
        'started_at': startedAt.toIso8601String(),
        'completed_at': completedAt.toIso8601String(),
        'result': result,
      };

  @override
  bool operator ==(Object other) =>
      other is FirstOpenCompleted &&
      other.startedAt == startedAt &&
      other.completedAt == completedAt &&
      jsonEquals(other.result, result);

  @override
  int get hashCode => Object.hash(startedAt, completedAt, jsonHash(result));

  // The answer holds link data and campaign fields; it stays out of logs.
  @override
  String toString() => 'FirstOpenCompleted(startedAt: '
      '${startedAt.toIso8601String()}, completedAt: '
      '${completedAt.toIso8601String()})';
}

/// Reads the stored form of a [FirstOpenRecord]; throws a
/// `MalformedJsonException` for an unknown state or a missing member.
FirstOpenRecord readFirstOpenRecord(JsonReader reader) {
  final state = reader.string('state');
  return switch (state) {
    'not_started' => const FirstOpenNotStarted(),
    'in_flight' => FirstOpenInFlight(
        startedAt: reader.timestamp('started_at'),
        evidence: reader.jsonObject('evidence'),
      ),
    'completed' => FirstOpenCompleted(
        startedAt: reader.timestamp('started_at'),
        completedAt: reader.timestamp('completed_at'),
        result: reader.jsonObject('result'),
      ),
    _ => reader.fail('state', 'not_started, in_flight or completed'),
  };
}
