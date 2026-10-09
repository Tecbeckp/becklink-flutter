import 'dart:math';

import 'package:becklink_flutter/src/core/event_delivery.dart';
import 'package:becklink_flutter/src/http/api_client.dart';
import 'package:becklink_flutter/src/http/retry_policy.dart';
import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:becklink_flutter/src/storage/event_queue.dart';
import 'package:becklink_flutter/src/storage/memory_storage_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_support.dart';

const String _installId = '3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10';
const Map<String, Object?> _context = <String, Object?>{
  'platform': 'android',
  'os_version': '15',
  'app_version': '1.2.3',
};

void main() {
  late FakeSdkApi api;
  late TestClock clock;
  late LogCapture logs;
  late SdkLogger logger;
  late EventQueue queue;
  late ApiClient client;
  late EventDelivery delivery;
  String? installId;

  ApiClient newClient() => ApiClient(
        apiKey: testKey,
        logger: logger,
        httpClient: api.client,
        baseUrl: fakeBaseUrl,
        now: clock.now,
        retryPolicy: const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          maxDelay: Duration(milliseconds: 5),
        ),
        compressEvents: false,
      );

  setUp(() async {
    api = FakeSdkApi();
    clock = TestClock();
    logs = LogCapture();
    logger = SdkLogger(level: LogLevel.debug, sink: logs.add);
    installId = _installId;
    queue = await EventQueue.open(
      directory: MemoryStorageDirectory(),
      logger: logger,
      now: clock.now,
      random: Random(11),
    );
    client = newClient();
    delivery = EventDelivery(
      queue: queue,
      logger: logger,
      api: () => client,
      sendingInstallId: () => installId,
      requestContext: () async => _context,
      now: clock.now,
    );
  });

  tearDown(() async {
    await delivery.stop();
    await queue.close();
    client.close();
    await api.close();
  });

  test('sends the queue every flush interval', () async {
    delivery.start(const Duration(milliseconds: 30));
    final sent = api.next(SdkPaths.events);
    await queue.enqueue(name: 'purchase', revenue: 9.99, currency: 'USD');

    final request = await sent;

    expect(request.json['install_id'], _installId);
    expect(request.json['context'], _context);
    final event = request.json.objects('events').single;
    expect(event['name'], 'purchase');
    expect(event['event_id'], isLowercaseUuid);
    expect(event['revenue'], 9.99);
    await eventually(() => queue.length == 0);
  });

  test('a new interval from remote config takes effect', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    final sent = api.next(SdkPaths.events);

    delivery.updateInterval(const Duration(milliseconds: 20));

    expect((await sent).json.list('events'), hasLength(1));
  });

  test('sends at 20 queued events without waiting for the interval', () async {
    delivery.start(const Duration(hours: 1));
    final sent = api.next(SdkPaths.events);

    await Future.wait(<Future<Object?>>[
      for (var i = 0; i < 20; i++) queue.enqueue(name: 'e$i'),
    ]);

    expect((await sent).json.list('events'), hasLength(20));
  });

  test('sends when the app goes to the background', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'checkout_started');
    final sent = api.next(SdkPaths.events);

    delivery.onBackground();

    expect((await sent).json.list('events'), hasLength(1));
  });

  test('sends nothing while sending is not allowed yet', () async {
    // First open not completed, tracking off, or the key refused.
    installId = null;
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');

    delivery.trigger('test');
    await delivery.flushNow();
    await settle();
    expect(api.requests, isEmpty);

    installId = _installId;
    delivery.trigger('test');
    await api.waitFor(SdkPaths.events, 1);
  });

  test('after the client gave up, waits for the next foreground', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    // The service stays unreachable past the client's 24-hour budget.
    api.enqueue(SdkPaths.events, (_) {
      clock.advance(const Duration(hours: 25));
      throw http.ClientException('Network is unreachable');
    });

    await delivery.flushNow();
    delivery.trigger('interval');
    await settle();
    expect(api.to(SdkPaths.events), hasLength(1));
    expect(queue.length, 1);

    delivery.onForeground();
    await api.waitFor(SdkPaths.events, 2);
    await eventually(() => queue.length == 0);
  });

  test('a 429 pauses sending for the Retry-After the service named', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    api.enqueue(
      SdkPaths.events,
      (_) => problemResponse(
        429,
        'rate_limited',
        headers: <String, String>{'retry-after': '600'},
      ),
    );

    await delivery.flushNow();
    delivery.trigger('interval');
    await delivery.flushNow();
    await settle();
    expect(api.to(SdkPaths.events), hasLength(1));

    clock.advance(const Duration(seconds: 601));
    delivery.trigger('interval');
    await api.waitFor(SdkPaths.events, 2);
  });

  test('a refused batch is dropped and logged', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    api.enqueue(
      SdkPaths.events,
      (_) => problemResponse(
        422,
        'validation_failed',
        detail: 'events/0/timestamp is out of range.',
      ),
    );

    await delivery.flushNow();

    expect(queue.length, 0);
    expect(queue.stats.droppedRejected, 1);
    expect(logs.at(LogLevel.error).single, contains('out of range'));
  });

  test('a refused key keeps the events and is logged as an error', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    api.respond(
      SdkPaths.events,
      (_) => problemResponse(401, 'invalid_api_key'),
    );

    await delivery.flushNow();
    delivery.trigger('interval');
    await settle();

    expect(queue.length, 1);
    expect(api.requests, hasLength(1));
    expect(logs.at(LogLevel.error).single, contains('refused the API key'));
  });

  test('a client closed by reconfiguration defers without an error', () async {
    delivery.start(const Duration(hours: 1));
    await queue.enqueue(name: 'e');
    client.close();

    await delivery.flushNow();
    expect(queue.length, 1);
    expect(logs.at(LogLevel.error), isEmpty);

    client = newClient();
    await delivery.flushNow();
    expect(queue.length, 0);
  });

  test('stop ends the interval timer', () async {
    delivery.start(const Duration(milliseconds: 20));
    await delivery.stop();
    await queue.enqueue(name: 'e');

    await settle(const Duration(milliseconds: 80));

    expect(api.requests, isEmpty);
  });
}
