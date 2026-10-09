import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../logging/sdk_logger.dart';
import '../util/uuid.dart';
import 'event_batch_outcome.dart';
import 'json_document.dart';
import 'queued_event.dart';
import 'storage_directory.dart';

/// Limits of the [EventQueue].
@immutable
final class EventQueueLimits {
  /// Creates limits; the defaults are the Phase 7 values.
  const EventQueueLimits({
    this.maxEvents = 500,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
    this.batchSize = 50,
    this.maxBatchBytes = 500 * 1024,
    this.flushThreshold = 20,
  })  : assert(maxEvents > 0, 'maxEvents must be positive'),
        assert(maxBatchBytes <= maxBytes, 'a batch must fit in the queue'),
        assert(batchSize > 0, 'batchSize must be positive'),
        assert(flushThreshold > 0, 'flushThreshold must be positive');

  /// Most events kept; when full, the oldest are dropped first.
  final int maxEvents;

  /// Most bytes kept, counted as the compact UTF-8 JSON of each event; when
  /// full, the oldest are dropped first.
  final int maxBytes;

  /// Age at which an event is dropped unsent, because the service rejects
  /// events older than 7 days (§17).
  final Duration maxAge;

  /// Most events in one `POST /v1/sdk/events` request (contract 8.4).
  final int batchSize;

  /// Most event bytes in one request. Below the endpoint's 512 KiB body
  /// limit (contract section 5), leaving room for `install_id`, `context`
  /// and the JSON punctuation around the events.
  final int maxBatchBytes;

  /// Queue length at which the queue asks for a flush
  /// ([EventQueue.onThresholdReached]).
  final int flushThreshold;
}

/// A snapshot of the queue for the Debug screen.
@immutable
final class EventQueueStats {
  /// Creates a snapshot.
  const EventQueueStats({
    required this.length,
    required this.bytes,
    required this.droppedForSpace,
    required this.droppedExpired,
    required this.droppedRejected,
  });

  /// Events waiting to be sent.
  final int length;

  /// Size of the waiting events in compact UTF-8 JSON.
  final int bytes;

  /// Events dropped in this process because the queue was full.
  final int droppedForSpace;

  /// Events dropped in this process because they got too old to send.
  final int droppedExpired;

  /// Events dropped in this process because the service rejected them, or
  /// refused their whole batch.
  final int droppedRejected;

  @override
  String toString() => 'EventQueueStats(length: $length, bytes: $bytes, '
      'droppedForSpace: $droppedForSpace, droppedExpired: $droppedExpired, '
      'droppedRejected: $droppedRejected)';
}

/// What one [EventQueue.flush] achieved.
@immutable
final class EventFlushResult {
  /// Creates a result.
  const EventFlushResult({
    required this.delivered,
    required this.dropped,
    required this.remaining,
    required this.completed,
  });

  /// Events the service accepted (duplicates included) and that left the
  /// queue.
  final int delivered;

  /// Events dropped during the flush: rejected, refused or expired.
  final int dropped;

  /// Events still queued when the flush ended.
  final int remaining;

  /// Whether the flush emptied the queue; `false` when a batch was deferred
  /// or the queue was closed, so the caller tries again later.
  final bool completed;
}

/// The persistent offline queue of custom events (EVT-001, requirements
/// §29.1, Phase 7 prompt): stored in `events.json`, capped by
/// [EventQueueLimits], sent in batches, and emptied only by the service's
/// answer.
///
/// All changes happen synchronously in memory, in call order, and are then
/// written to disk one write at a time, so concurrent `track()` calls never
/// corrupt the file. Events leave the queue only when the service answered
/// for their batch ([EventBatchDelivered] or [EventBatchRefused]); a batch
/// that could not be delivered stays and is sent again, with the same
/// `event_id`s, so the service stores each event once. Never logs property
/// values or user IDs. Use one queue per directory in a process. Internal
/// to the SDK.
final class EventQueue {
  EventQueue._(
    this._document,
    this._logger,
    this._now,
    this._random,
    this.limits,
  );

  /// Name of the document in the storage directory.
  static const String documentName = 'events.json';

  /// Layout version of the document this SDK writes (see
  /// [JsonDocument.schemaVersion]).
  static const int schemaVersion = 1;

  /// Opens the queue stored in [directory], or an empty one when there is
  /// none or it cannot be read. Drops events that expired or no longer fit
  /// [limits].
  ///
  /// [now] and [random] replace the clock and the event ID generator in
  /// tests; production uses [Random.secure].
  static Future<EventQueue> open({
    required StorageDirectory directory,
    required SdkLogger logger,
    EventQueueLimits limits = const EventQueueLimits(),
    DateTime Function()? now,
    Random? random,
  }) async {
    final document = JsonDocument(
      name: documentName,
      schemaVersion: schemaVersion,
      directory: directory,
      logger: logger,
    );
    final queue = EventQueue._(
      document,
      logger,
      now ?? DateTime.now,
      random ?? Random.secure(),
      limits,
    );
    final reader = await document.load();
    var changed = reader != null && queue._restore(reader);
    if (queue._dropExpired() > 0) changed = true;
    if (queue._dropOldestOverLimits() > 0) changed = true;
    if (changed) await queue._save();
    return queue;
  }

  /// The limits this queue enforces.
  final EventQueueLimits limits;

  final JsonDocument _document;
  final SdkLogger _logger;
  final DateTime Function() _now;
  final Random _random;

  /// Oldest first.
  final List<QueuedEvent> _events = <QueuedEvent>[];
  final StreamController<void> _thresholdReached =
      StreamController<void>.broadcast();

  int _bytes = 0;
  int _droppedForSpace = 0;
  int _droppedExpired = 0;
  int _droppedRejected = 0;
  Future<EventFlushResult>? _flushing;
  bool _closed = false;

  /// Events waiting to be sent.
  int get length => _events.length;

  /// A snapshot for the Debug screen.
  EventQueueStats get stats => EventQueueStats(
        length: _events.length,
        bytes: _bytes,
        droppedForSpace: _droppedForSpace,
        droppedExpired: _droppedExpired,
        droppedRejected: _droppedRejected,
      );

  /// Fires when an [enqueue] brings the queue to
  /// [EventQueueLimits.flushThreshold] events (requirements §29 step 7,
  /// "20 queued events par ... flush").
  ///
  /// Fires on reaching the threshold, not for every event above it, so an
  /// offline app does not try to send on every `track()`; the interval
  /// timer retries those.
  Stream<void> get onThresholdReached => _thresholdReached.stream;

  /// Adds an event with a new `event_id` and the current time as its
  /// timestamp, and completes once it is on disk (or the write failed and
  /// was logged; the event then stays queued in memory).
  ///
  /// The caller checks consent first and validates the content against the
  /// contract (`track()`). The event is queued when this method is called,
  /// before it returns, so a [clear] called afterwards removes it. When the
  /// queue is full, the oldest events are dropped and counted
  /// ([EventQueueStats.droppedForSpace]).
  ///
  /// Throws an [ArgumentError] when the content cannot be stored (see
  /// [QueuedEvent.new]) or the event alone is larger than
  /// [EventQueueLimits.maxBatchBytes], and a [StateError] after [close].
  Future<QueuedEvent> enqueue({
    required String name,
    Map<String, Object?>? properties,
    num? revenue,
    String? currency,
    String? userId,
  }) async {
    _checkOpen();
    final event = QueuedEvent(
      eventId: uuidV4(_random),
      name: name,
      timestamp: _now(),
      properties: properties,
      revenue: revenue,
      currency: currency,
      userId: userId,
    );
    if (event.sizeInBytes > limits.maxBatchBytes) {
      throw ArgumentError(
        'is ${event.sizeInBytes} bytes as JSON; one event may be at most '
            '${limits.maxBatchBytes} bytes',
        'event',
      );
    }
    final wasBelowThreshold = _events.length < limits.flushThreshold;
    _append(event);
    _dropOldestOverLimits();
    if (wasBelowThreshold && _events.length >= limits.flushThreshold) {
      _thresholdReached.add(null);
    }
    await _save();
    return event;
  }

  /// Sends the queue in batches through [send] until it is empty, a batch is
  /// deferred, or the queue is closed.
  ///
  /// Expired events are dropped before each batch. While a flush runs, a
  /// second call returns the running flush instead of sending the same
  /// events twice (its [send] is not used). Events queued during the flush
  /// are sent by it as well. The queue is not locked while [send] waits for
  /// the network, so [enqueue] and [clear] keep working. Throws a
  /// [StateError] after [close].
  Future<EventFlushResult> flush(EventBatchSender send) {
    _checkOpen();
    return _flushing ??= _flushAll(send).whenComplete(() => _flushing = null);
  }

  /// Deletes every queued event, for `setTrackingEnabled(false)` (PRV-002,
  /// §29: queued events are deleted), and completes once the empty queue is
  /// on disk.
  ///
  /// Always rewrites the document, even when the queue looks empty, so no
  /// event an earlier failed write left on disk survives. If the document
  /// cannot be written (logged), the caller clears again on the next launch
  /// while tracking stays off. A batch in flight is not recalled, but its
  /// events are not put back. Throws a [StateError] after [close].
  Future<void> clear() async {
    _checkOpen();
    _events.clear();
    _bytes = 0;
    await _save();
  }

  /// Stops accepting calls, closes [onThresholdReached] and completes once
  /// pending writes are done. A running flush stops after its current batch.
  /// Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _thresholdReached.close();
    await _document.whenIdle();
  }

  void _checkOpen() {
    if (_closed) throw StateError('The event queue is closed.');
  }

  Future<EventFlushResult> _flushAll(EventBatchSender send) async {
    var delivered = 0;
    var dropped = 0;
    EventFlushResult result({required bool completed}) => EventFlushResult(
          delivered: delivered,
          dropped: dropped,
          remaining: _events.length,
          completed: completed,
        );

    while (!_closed) {
      final expired = _dropExpired();
      if (expired > 0) {
        dropped += expired;
        await _save();
      }
      if (_events.isEmpty) return result(completed: true);
      final batch = _nextBatch();
      final outcome = await send(batch);
      switch (outcome) {
        case EventBatchDelivered(:final receipt):
          final rejected = _rejectedCount(batch, receipt);
          _remove(batch);
          _droppedRejected += rejected;
          dropped += rejected;
          delivered += batch.length - rejected;
          _logReceipt(batch, receipt);
        case EventBatchRefused(:final reason):
          _remove(batch);
          _droppedRejected += batch.length;
          dropped += batch.length;
          _logger.error(
            'The Beck Link API refused a batch of ${batch.length} events; '
            'they were dropped: $reason',
          );
        case EventBatchDeferred():
          return result(completed: false);
      }
      await _save();
    }
    return result(completed: false);
  }

  /// The oldest events that fit one request: at most
  /// [EventQueueLimits.batchSize] events and
  /// [EventQueueLimits.maxBatchBytes] bytes, but always at least one event,
  /// so an oversized one (stored under other limits) is refused by the
  /// service and dropped instead of blocking the queue.
  List<QueuedEvent> _nextBatch() {
    final batch = <QueuedEvent>[];
    var bytes = 0;
    for (final event in _events) {
      if (batch.length == limits.batchSize ||
          (batch.isNotEmpty &&
              bytes + event.sizeInBytes > limits.maxBatchBytes)) {
        break;
      }
      batch.add(event);
      bytes += event.sizeInBytes;
    }
    return List<QueuedEvent>.unmodifiable(batch);
  }

  void _append(QueuedEvent event) {
    _events.add(event);
    _bytes += event.sizeInBytes;
  }

  /// Removes the events of [batch] that are still queued; [clear] or the
  /// size limit may have removed some while the batch was in flight.
  void _remove(List<QueuedEvent> batch) {
    final ids = <String>{for (final event in batch) event.eventId};
    _events.removeWhere((event) {
      if (!ids.contains(event.eventId)) return false;
      _bytes -= event.sizeInBytes;
      return true;
    });
  }

  /// Drops the oldest events until both size limits hold, and returns how
  /// many.
  int _dropOldestOverLimits() {
    var dropped = 0;
    while (_events.isNotEmpty &&
        (_events.length > limits.maxEvents || _bytes > limits.maxBytes)) {
      _bytes -= _events.removeAt(0).sizeInBytes;
      dropped++;
    }
    if (dropped > 0) {
      _droppedForSpace += dropped;
      _logger.info('The event queue is full; dropped the $dropped oldest '
          'event(s)');
    }
    return dropped;
  }

  /// Drops events that reached [EventQueueLimits.maxAge], and returns how
  /// many.
  int _dropExpired() {
    final now = _now();
    final before = _events.length;
    _events.removeWhere((event) {
      if (now.difference(event.timestamp) < limits.maxAge) return false;
      _bytes -= event.sizeInBytes;
      return true;
    });
    final dropped = before - _events.length;
    if (dropped > 0) {
      _droppedExpired += dropped;
      _logger.info('Dropped $dropped event(s) older than '
          '${limits.maxAge.inDays} days; the service would reject them');
    }
    return dropped;
  }

  /// How many events of [batch] the [receipt] reports as rejected.
  static int _rejectedCount(
      List<QueuedEvent> batch, EventBatchReceipt receipt) {
    final ids = <String>{for (final event in batch) event.eventId};
    return receipt.rejected
        .map((rejected) => rejected.eventId.toLowerCase())
        .where(ids.contains)
        .toSet()
        .length;
  }

  /// Logs rejected events at error level and changed events at info level
  /// (contract section 8.4), with event names and codes but never property
  /// values.
  void _logReceipt(List<QueuedEvent> batch, EventBatchReceipt receipt) {
    final names = <String, String>{
      for (final event in batch) event.eventId: event.name,
    };
    String describe(String eventId) =>
        '"${names[eventId.toLowerCase()] ?? 'unknown'}" ($eventId)';
    for (final rejected in receipt.rejected) {
      final detail = rejected.detail;
      _logger.error(
        'Event ${describe(rejected.eventId)} was rejected: ${rejected.code}'
        '${detail == null ? '' : ': $detail'}',
      );
    }
    for (final warning in receipt.warnings) {
      final where =
          warning.pointers.isEmpty ? '' : ' at ${warning.pointers.join(', ')}';
      _logger.info(
        'Event ${describe(warning.eventId)} was changed: ${warning.code}'
        '$where',
      );
    }
    _logger.debug('Sent a batch of ${batch.length} events');
  }

  Future<void> _save() => _document.save(
        () => <String, Object?>{
          'events': <Map<String, Object?>>[
            for (final event in _events) event.toJson(),
          ],
        },
      );

  /// Loads the stored events, oldest first, and returns whether some were
  /// unreadable and left out, so the caller rewrites the document.
  bool _restore(JsonReader reader) {
    final List<JsonReader> items;
    try {
      items = reader.objectList('events');
    } on FormatException {
      _logger.error('The stored event queue was unreadable and was reset');
      return true;
    }
    final ids = <String>{};
    var unreadable = 0;
    for (final item in items) {
      try {
        final event = readQueuedEvent(item);
        // A duplicate would be stored once by the service anyway; keeping
        // one copy keeps the counts right.
        if (ids.add(event.eventId)) _append(event);
      } on FormatException {
        unreadable++;
      }
    }
    if (unreadable == 0) return false;
    _logger.error('$unreadable stored event(s) were unreadable and were '
        'dropped');
    return true;
  }
}
