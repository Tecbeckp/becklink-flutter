import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:becklink_flutter/src/storage/event_batch_outcome.dart';
import 'package:becklink_flutter/src/storage/event_queue.dart';
import 'package:becklink_flutter/src/storage/memory_storage_directory.dart';
import 'package:becklink_flutter/src/storage/queued_event.dart';
import 'package:becklink_flutter/src/storage/storage_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

const _eventA = '0b6f6c3e-2d0a-4c1e-9f7a-1a2b3c4d5e6f';
const _eventB = '1c7a7d4f-3e1b-4d2f-8a8b-2b3c4d5e6f70';

/// A sender that records each batch and answers with what [answer] says
/// (by default: delivered, nothing rejected).
final class _RecordingSender {
  _RecordingSender([this.answer]);

  final FutureOr<EventBatchOutcome> Function(List<QueuedEvent> batch)? answer;
  final List<List<QueuedEvent>> batches = <List<QueuedEvent>>[];

  Future<EventBatchOutcome> call(List<QueuedEvent> batch) async {
    batches.add(batch);
    final reply = answer;
    if (reply != null) return reply(batch);
    return const EventBatchDelivered(EventBatchReceipt());
  }

  List<String> namesOf(int batch) =>
      batches[batch].map((event) => event.name).toList();
}

/// Memory storage whose writes wait for [gate] and count how many run at
/// the same time.
final class _GatedDirectory implements StorageDirectory {
  final MemoryStorageDirectory _inner = MemoryStorageDirectory();
  Completer<void> gate = Completer<void>()..complete();
  final List<String> written = <String>[];
  int _running = 0;
  int maxConcurrentWrites = 0;
  Completer<void> writeStarted = Completer<void>();

  @override
  Future<String?> read(String name, {required int maxBytes}) =>
      _inner.read(name, maxBytes: maxBytes);

  @override
  Future<void> write(String name, String contents) async {
    _running++;
    maxConcurrentWrites = max(maxConcurrentWrites, _running);
    if (!writeStarted.isCompleted) writeStarted.complete();
    await gate.future;
    written.add(contents);
    await _inner.write(name, contents);
    _running--;
  }

  @override
  Future<void> delete(String name) => _inner.delete(name);
}

void main() {
  late MemoryStorageDirectory directory;
  late TestClock clock;
  late LogCapture logs;
  final queues = <EventQueue>[];

  setUp(() {
    directory = MemoryStorageDirectory();
    clock = TestClock();
    logs = LogCapture();
  });

  tearDown(() async {
    for (final queue in queues) {
      await queue.close();
    }
    queues.clear();
  });

  Future<EventQueue> open({
    StorageDirectory? from,
    EventQueueLimits limits = const EventQueueLimits(),
  }) async {
    final queue = await EventQueue.open(
      directory: from ?? directory,
      logger: SdkLogger(level: LogLevel.debug, sink: logs.add),
      limits: limits,
      now: clock.now,
      random: Random(5),
    );
    queues.add(queue);
    return queue;
  }

  Future<void> enqueueNamed(EventQueue queue, int count, {String? prefix}) =>
      Future.wait(<Future<QueuedEvent>>[
        for (var i = 0; i < count; i++)
          queue.enqueue(name: '${prefix ?? 'e'}$i'),
      ]);

  Map<String, Object?> storedDocument() => jsonDecode(
        directory.documents[EventQueue.documentName]!,
      ) as Map<String, Object?>;

  group('enqueue', () {
    test('stores the contract event shape and survives a restart', () async {
      final queue = await open();
      final event = await queue.enqueue(
        name: 'purchase',
        properties: <String, Object?>{'sku': 'A1', 'quantity': 2},
        revenue: 9.99,
        currency: 'USD',
        userId: 'user_8841',
      );

      expect(event.eventId, isLowercaseUuid);
      expect(event.timestamp, clock.now());
      expect(event.toJson(), <String, Object?>{
        'event_id': event.eventId,
        'name': 'purchase',
        'timestamp': '2026-10-07T12:00:00.000Z',
        'properties': <String, Object?>{'sku': 'A1', 'quantity': 2},
        'revenue': 9.99,
        'currency': 'USD',
        'user_id': 'user_8841',
      });

      await queue.close();
      final reopened = await open();
      expect(reopened.length, 1);
      final sender = _RecordingSender();
      await reopened.flush(sender.call);
      expect(sender.batches.single.single, event);
    });

    test('keeps at most 500 events, dropping the oldest', () async {
      final queue = await open();

      await enqueueNamed(queue, 501);

      expect(queue.length, 500);
      expect(queue.stats.droppedForSpace, 1);
      final sender = _RecordingSender();
      await queue.flush(sender.call);
      expect(sender.batches.first.first.name, 'e1');
      expect(sender.batches.last.last.name, 'e500');
    });

    test('keeps at most 2 MiB of events, dropping the oldest', () async {
      final queue = await open();
      final properties = <String, Object?>{'blob': 'x' * 200000};

      final first = await queue.enqueue(name: 'big', properties: properties);
      for (var i = 1; i < 12; i++) {
        await queue.enqueue(name: 'big', properties: properties);
      }

      final fitting = (2 * 1024 * 1024) ~/ first.sizeInBytes;
      expect(fitting, lessThan(12));
      expect(queue.length, fitting);
      expect(queue.stats.bytes, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(queue.stats.droppedForSpace, 12 - fitting);
    });

    test('refuses a single event larger than one batch may be', () async {
      final queue = await open();

      await expectLater(
        queue.enqueue(
          name: 'huge',
          properties: <String, Object?>{'blob': 'x' * (500 * 1024)},
        ),
        throwsArgumentError,
      );
      expect(queue.length, 0);
    });

    test('signals the flush threshold once, when it is reached', () async {
      final queue = await open();
      var signals = 0;
      final subscription = queue.onThresholdReached.listen((_) => signals++);

      await enqueueNamed(queue, 19);
      await settle(const Duration(milliseconds: 10));
      expect(signals, 0);
      await queue.enqueue(name: 'twentieth');
      await queue.enqueue(name: 'twenty_first');
      await settle(const Duration(milliseconds: 10));

      expect(signals, 1);
      await subscription.cancel();
    });
  });

  group('expiry', () {
    test('drops events that turned 7 days old while the app was closed',
        () async {
      final queue = await open();
      await queue.enqueue(name: 'old');
      clock.advance(const Duration(days: 1));
      await queue.enqueue(name: 'recent');
      await queue.close();

      clock.advance(const Duration(days: 6));
      final reopened = await open();

      expect(reopened.length, 1);
      expect(reopened.stats.droppedExpired, 1);
      expect(storedDocument().objects('events').single['name'], 'recent');
    });

    test('drops expired events before each batch', () async {
      final queue = await open();
      await queue.enqueue(name: 'old');
      clock.advance(const Duration(days: 7) - const Duration(milliseconds: 1));
      await queue.enqueue(name: 'new');
      final sender = _RecordingSender();
      clock.advance(const Duration(milliseconds: 1));

      final result = await queue.flush(sender.call);

      expect(sender.namesOf(0), <String>['new']);
      expect(result.dropped, 1);
      expect(result.delivered, 1);
    });
  });

  group('flush', () {
    test('sends batches of at most 50 events, oldest first', () async {
      final queue = await open();
      await enqueueNamed(queue, 120);
      final sender = _RecordingSender();

      final result = await queue.flush(sender.call);

      expect(
        sender.batches.map((batch) => batch.length),
        <int>[50, 50, 20],
      );
      expect(sender.namesOf(0).first, 'e0');
      expect(result.delivered, 120);
      expect(result.completed, isTrue);
      expect(queue.length, 0);
      expect(storedDocument().list('events'), isEmpty);
    });

    test('keeps each batch within 500 KiB of events', () async {
      final queue = await open();
      for (var i = 0; i < 5; i++) {
        await queue.enqueue(
          name: 'big$i',
          properties: <String, Object?>{'blob': 'x' * 200000},
        );
      }
      final sender = _RecordingSender();

      await queue.flush(sender.call);

      expect(sender.batches.map((batch) => batch.length), <int>[2, 2, 1]);
    });

    test('keeps a deferred batch and resends the same events later', () async {
      final queue = await open();
      await enqueueNamed(queue, 3);
      final failing = _RecordingSender((_) => const EventBatchDeferred());

      final result = await queue.flush(failing.call);

      expect(result.completed, isFalse);
      expect(result.remaining, 3);
      expect(queue.length, 3);
      final retry = _RecordingSender();
      await queue.flush(retry.call);
      expect(
        retry.batches.single.map((event) => event.eventId),
        failing.batches.single.map((event) => event.eventId),
      );
    });

    test(
        'removes a delivered batch, counting the events the service '
        'rejected', () async {
      final queue = await open();
      final kept = await queue.enqueue(name: 'kept');
      final rejected = await queue.enqueue(name: 'rejected');
      final sender = _RecordingSender(
        (_) => EventBatchDelivered(
          EventBatchReceipt(
            accepted: 1,
            rejected: <RejectedEvent>[
              RejectedEvent(
                eventId: rejected.eventId.toUpperCase(),
                code: 'timestamp_out_of_range',
                detail: 'The event is older than 7 days.',
              ),
            ],
            warnings: <EventWarning>[
              EventWarning(
                eventId: kept.eventId,
                code: 'pii_removed',
                pointers: const <String>['/events/0/properties/contact'],
              ),
            ],
          ),
        ),
      );

      final result = await queue.flush(sender.call);

      expect(result.delivered, 1);
      expect(result.dropped, 1);
      expect(queue.length, 0);
      expect(queue.stats.droppedRejected, 1);
      expect(logs.at(LogLevel.error).single, contains('"rejected"'));
      expect(logs.at(LogLevel.info), contains(contains('pii_removed')));
    });

    test('drops a batch the service refused so it cannot block the queue',
        () async {
      final queue = await open();
      await enqueueNamed(queue, 60);
      var calls = 0;
      final sender = _RecordingSender(
        (_) => calls++ == 0
            ? const EventBatchRefused('The request body is too large.')
            : const EventBatchDelivered(EventBatchReceipt()),
      );

      final result = await queue.flush(sender.call);

      expect(result.dropped, 50);
      expect(result.delivered, 10);
      expect(queue.length, 0);
      expect(logs.at(LogLevel.error).single, contains('refused a batch of 50'));
    });

    test('a second flush while one runs joins it', () async {
      final queue = await open();
      await enqueueNamed(queue, 2);
      final release = Completer<void>();
      final slow = _RecordingSender((_) async {
        await release.future;
        return const EventBatchDelivered(EventBatchReceipt());
      });
      final other = _RecordingSender();

      final first = queue.flush(slow.call);
      final second = queue.flush(other.call);
      release.complete();

      expect(identical(await first, await second), isTrue);
      expect(other.batches, isEmpty);
      expect(slow.batches, hasLength(1));
    });

    test('events enqueued during a send go out with the same flush', () async {
      final queue = await open();
      await queue.enqueue(name: 'before');
      final release = Completer<void>();
      final sender = _RecordingSender((batch) async {
        if (batch.first.name == 'before') await release.future;
        return const EventBatchDelivered(EventBatchReceipt());
      });

      final flushing = queue.flush(sender.call);
      await settle(const Duration(milliseconds: 10));
      await queue.enqueue(name: 'during');
      release.complete();
      final result = await flushing;

      expect(result.delivered, 2);
      expect(sender.namesOf(1), <String>['during']);
    });
  });

  group('clear', () {
    test('deletes every event on disk, for tracking off', () async {
      final queue = await open();
      await enqueueNamed(queue, 3);

      await queue.clear();

      expect(queue.length, 0);
      expect(storedDocument().list('events'), isEmpty);
      final reopened = await open();
      expect(reopened.length, 0);
    });

    test('does not put back a batch that was in flight', () async {
      final queue = await open();
      await enqueueNamed(queue, 2, prefix: 'old');
      final release = Completer<void>();
      final sender = _RecordingSender((batch) async {
        if (batch.first.name.startsWith('old')) await release.future;
        return const EventBatchDeferred();
      });

      final flushing = queue.flush(sender.call);
      await settle(const Duration(milliseconds: 10));
      await queue.clear();
      await queue.enqueue(name: 'new');
      release.complete();
      await flushing;

      expect(queue.length, 1);
      final next = _RecordingSender();
      await queue.flush(next.call);
      expect(next.namesOf(0), <String>['new']);
    });
  });

  group('damaged storage', () {
    test('a document that is not JSON is reset', () async {
      directory = MemoryStorageDirectory(<String, String>{
        EventQueue.documentName: '{"events": [',
      });

      final queue = await open();

      expect(queue.length, 0);
      expect(directory.documents, isEmpty);
      expect(logs.at(LogLevel.error).single, contains('was reset'));
    });

    test('unreadable events are dropped, readable ones kept once', () async {
      Map<String, Object?> event(String id, String name) => <String, Object?>{
            'event_id': id,
            'name': name,
            'timestamp': '2026-10-07T11:00:00.000Z',
            'properties': null,
            'revenue': null,
            'currency': null,
            'user_id': null,
          };
      directory = MemoryStorageDirectory(<String, String>{
        EventQueue.documentName: jsonEncode(<String, Object?>{
          'schema_version': 1,
          'events': <Object?>[
            event(_eventA, 'a'),
            event('not-a-uuid', 'broken'),
            <String, Object?>{'name': 'no id'},
            event(_eventB, 'b'),
            event(_eventA.toUpperCase(), 'a again'),
          ],
        }),
      });

      final queue = await open();

      expect(queue.length, 2);
      expect(
        logs.at(LogLevel.error).single,
        contains('2 stored event(s) were unreadable'),
      );
      expect(
        storedDocument().objects('events').map((event) => event['name']),
        <String>['a', 'b'],
      );
    });

    test('an events member that is not a list is reset', () async {
      directory = MemoryStorageDirectory(<String, String>{
        EventQueue.documentName: '{"schema_version": 1, "events": {}}',
      });

      final queue = await open();

      expect(queue.length, 0);
      expect(storedDocument().list('events'), isEmpty);
    });
  });

  group('writes', () {
    test('run one at a time, and waiting changes join one write', () async {
      final gated = _GatedDirectory();
      final queue = await open(from: gated);
      gated
        ..gate = Completer<void>()
        ..writeStarted = Completer<void>();

      final first = <Future<QueuedEvent>>[
        queue.enqueue(name: 'one'),
        queue.enqueue(name: 'two'),
      ];
      await gated.writeStarted.future;
      final later = <Future<QueuedEvent>>[
        queue.enqueue(name: 'three'),
        queue.enqueue(name: 'four'),
        queue.enqueue(name: 'five'),
      ];
      gated.gate.complete();
      await Future.wait(<Future<QueuedEvent>>[...first, ...later]);

      expect(gated.maxConcurrentWrites, 1);
      expect(gated.written, hasLength(2));
      final last = jsonDecode(gated.written.last) as Map<String, Object?>;
      expect(last.list('events'), hasLength(5));
    });

    test('after close, the queue refuses calls', () async {
      final queue = await open();
      await queue.close();

      await expectLater(queue.enqueue(name: 'late'), throwsStateError);
      expect(
        () => queue.flush(_RecordingSender().call),
        throwsStateError,
      );
    });
  });
}
