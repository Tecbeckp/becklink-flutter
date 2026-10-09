import 'dart:convert';

import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../json/json_value.dart';
import '../util/uuid.dart';

/// One custom event waiting in the event queue, in the shape of the SDK API
/// `event` object (contract section 8.4).
///
/// The queue does not judge content: `track()` checks names, properties,
/// revenue and currency against the contract before an event is queued, and
/// the service has the last word (it rejects or strips what breaks its
/// rules, for example properties that look like an email address). Never
/// log [properties] or [userId]. Internal to the SDK.
@immutable
final class QueuedEvent {
  /// Creates an event; [timestamp] is converted to UTC and [properties] is
  /// copied into an unmodifiable map.
  ///
  /// Throws an [ArgumentError] when [eventId] is not a UUID, [name] is
  /// empty, [properties] holds a value that is not JSON, or [revenue] is not
  /// finite.
  QueuedEvent({
    required String eventId,
    required this.name,
    required DateTime timestamp,
    Map<String, Object?>? properties,
    this.revenue,
    this.currency,
    this.userId,
  })  : eventId = _checkEventId(eventId),
        timestamp = timestamp.toUtc(),
        properties = properties == null
            ? null
            : checkJsonObjectArgument(properties, 'properties') {
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    final amount = revenue;
    if (amount != null && !amount.isFinite) {
      throw ArgumentError.value(amount, 'revenue', 'must be finite');
    }
  }

  /// Dedupe key of the event on the service (7 days, §17): a lowercase UUID
  /// created when the event was queued and sent unchanged on every retry.
  final String eventId;

  /// The event name, such as `purchase`.
  final String name;

  /// Client time of `track()`, UTC.
  final DateTime timestamp;

  /// Flat event properties, or `null` when there are none.
  final Map<String, Object?>? properties;

  /// Revenue amount, or `null`.
  final num? revenue;

  /// ISO 4217 code of [revenue], or `null`.
  final String? currency;

  /// The app's user ID when the event was tracked, or `null`.
  final String? userId;

  /// Size of the event in compact UTF-8 JSON, which the queue's 2 MiB limit
  /// and the batch size limit count.
  late final int sizeInBytes = utf8.encode(jsonEncode(toJson())).length;

  /// The SDK API `event` object, also the stored form.
  Map<String, Object?> toJson() => <String, Object?>{
        'event_id': eventId,
        'name': name,
        'timestamp': timestamp.toIso8601String(),
        'properties': properties,
        'revenue': revenue,
        'currency': currency,
        'user_id': userId,
      };

  @override
  bool operator ==(Object other) =>
      other is QueuedEvent &&
      other.eventId == eventId &&
      other.name == name &&
      other.timestamp == timestamp &&
      jsonEquals(other.properties, properties) &&
      other.revenue == revenue &&
      other.currency == currency &&
      other.userId == userId;

  @override
  int get hashCode => Object.hash(
        eventId,
        name,
        timestamp,
        jsonHash(properties),
        revenue,
        currency,
        userId,
      );

  /// A description for logs, without property values and the user ID.
  @override
  String toString() => 'QueuedEvent(eventId: $eventId, name: $name, '
      'timestamp: ${timestamp.toIso8601String()}, '
      'properties: ${properties?.length ?? 0} keys)';

  static String _checkEventId(String eventId) =>
      normalizeUuid(eventId) ??
      (throw ArgumentError.value(eventId, 'eventId', 'is not a UUID'));
}

/// Reads the stored form of a [QueuedEvent]; throws a
/// `MalformedJsonException` when a member has the wrong shape.
QueuedEvent readQueuedEvent(JsonReader reader) {
  final eventId = normalizeUuid(reader.string('event_id')) ??
      reader.fail('event_id', 'a UUID');
  final name = reader.string('name');
  if (name.isEmpty) reader.fail('name', 'a non-empty string');
  return QueuedEvent(
    eventId: eventId,
    name: name,
    timestamp: reader.timestamp('timestamp'),
    properties: reader.optionalJsonObject('properties'),
    revenue: reader.optionalNumber('revenue'),
    currency: reader.optionalString('currency'),
    userId: reader.optionalString('user_id'),
  );
}
