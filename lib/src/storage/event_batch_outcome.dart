import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../util/single_line.dart';
import 'queued_event.dart';

/// Sends one batch of queued events to `POST /v1/sdk/events` and reports
/// what became of it. Must not throw: every failure maps to an outcome.
typedef EventBatchSender = Future<EventBatchOutcome> Function(
  List<QueuedEvent> batch,
);

/// What became of one event batch, which decides whether its events leave
/// the queue (contract section 8.4 "SDK handling"). Internal to the SDK.
@immutable
sealed class EventBatchOutcome {
  const EventBatchOutcome();
}

/// The service answered `202`: every event of the batch is done (accepted,
/// duplicate or rejected for good) and leaves the queue.
final class EventBatchDelivered extends EventBatchOutcome {
  /// Creates the outcome with the service's [receipt].
  const EventBatchDelivered(this.receipt);

  /// What the service said about the individual events.
  final EventBatchReceipt receipt;
}

/// The service refused the whole batch for good (`400`, `413`, `415` or
/// `422`): the batch leaves the queue so it cannot block later events.
final class EventBatchRefused extends EventBatchOutcome {
  /// Creates the outcome; [reason] is logged and must be safe to log (for
  /// example a `BeckLinkException` message, whose server text the contract
  /// declares log-safe).
  const EventBatchRefused(this.reason);

  /// Why the batch was refused.
  final String reason;
}

/// The batch was not delivered and may succeed later (no connection, retry
/// budget used up, rate limited, API key rejected, SDK shutting down, or
/// sending not allowed yet): its events stay queued.
final class EventBatchDeferred extends EventBatchOutcome {
  /// Creates the outcome.
  const EventBatchDeferred();
}

/// The body of a `202` events answer (contract section 8.4).
@immutable
final class EventBatchReceipt {
  /// Creates a receipt.
  const EventBatchReceipt({
    this.accepted,
    this.rejected = const <RejectedEvent>[],
    this.warnings = const <EventWarning>[],
  });

  /// Events accepted for storage, duplicates included; `null` when the
  /// answer did not say.
  final int? accepted;

  /// Events the service rejected for good.
  final List<RejectedEvent> rejected;

  /// Accepted events the service changed, for example by removing a
  /// property that looked like an email address.
  final List<EventWarning> warnings;
}

/// One rejected event of an [EventBatchReceipt].
@immutable
final class RejectedEvent {
  /// Creates a rejected event.
  const RejectedEvent({required this.eventId, required this.code, this.detail});

  /// The `event_id` of the rejected event.
  final String eventId;

  /// Why, for example `validation_failed`, `timestamp_out_of_range` or
  /// `event_name_not_allowed`.
  final String code;

  /// The service's explanation, on one line and shortened; safe to log.
  final String? detail;
}

/// One accepted-but-changed event of an [EventBatchReceipt].
@immutable
final class EventWarning {
  /// Creates a warning.
  const EventWarning({
    required this.eventId,
    required this.code,
    this.pointers = const <String>[],
  });

  /// The `event_id` of the changed event.
  final String eventId;

  /// What was changed, for example `pii_removed`.
  final String code;

  /// JSON Pointers into the request body of the changed members, such as
  /// `/events/1/properties/contact`.
  final List<String> pointers;
}

/// Longest identifier (event ID, code) kept from a receipt item.
const int _maxIdLength = 64;

/// Longest explanation or pointer kept from a receipt item.
const int _maxTextLength = 300;

/// Reads the body of a `202` events answer leniently: members and items
/// that are missing or have the wrong shape are left out instead of
/// failing.
///
/// The `202` status alone means the service took the batch, so an answer
/// this SDK version cannot fully read must not keep the events queued and
/// resend them forever. Server text is cut to one short line, because it
/// ends up in logs.
EventBatchReceipt readEventBatchReceipt(JsonReader reader) {
  final accepted = _lenient(() => reader.integer('accepted'));
  return EventBatchReceipt(
    accepted: accepted != null && accepted >= 0 ? accepted : null,
    rejected: List<RejectedEvent>.unmodifiable(
      _items(reader, 'rejected', (item) {
        final detail = item.optionalString('detail');
        return RejectedEvent(
          eventId: _text(item.string('event_id'), _maxIdLength),
          code: _text(item.string('code'), _maxIdLength),
          detail: detail == null ? null : _text(detail, _maxTextLength),
        );
      }),
    ),
    warnings: List<EventWarning>.unmodifiable(
      _items(reader, 'warnings', (item) {
        final pointers = _lenient(() => item.stringList('pointers'));
        return EventWarning(
          eventId: _text(item.string('event_id'), _maxIdLength),
          code: _text(item.string('code'), _maxIdLength),
          pointers: List<String>.unmodifiable(
            (pointers ?? const <String>[])
                .map((pointer) => _text(pointer, _maxTextLength)),
          ),
        );
      }),
    ),
  );
}

/// The readable items of the array member [key], each made by [read].
Iterable<T> _items<T extends Object>(
  JsonReader reader,
  String key,
  T Function(JsonReader item) read,
) {
  final items = _lenient(() => reader.objectList(key));
  if (items == null) return Iterable<T>.empty();
  return items.map((item) => _lenient(() => read(item))).nonNulls;
}

/// What [read] returns, or `null` when it finds a malformed member.
T? _lenient<T extends Object>(T Function() read) {
  try {
    return read();
  } on FormatException {
    return null;
  }
}

String _text(String value, int maxLength) =>
    singleLine(value, maxLength: maxLength);
