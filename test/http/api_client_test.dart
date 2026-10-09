import 'dart:async';
import 'dart:io' show HttpDate, gzip;

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/http/api_client.dart';
import 'package:becklink_flutter/src/http/api_client_closed_exception.dart';
import 'package:becklink_flutter/src/http/api_endpoint.dart';
import 'package:becklink_flutter/src/http/api_response.dart';
import 'package:becklink_flutter/src/http/retry_policy.dart';
import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/remote_config.dart';
import 'package:becklink_flutter/src/sdk_info.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_support.dart';

const Map<String, Object?> _body = <String, Object?>{
  'install_id': '3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10',
  'user_id': null,
};

const Map<String, Object?> _openBody = <String, Object?>{
  'url': testLinkUrl,
  'tracking_enabled': false,
};

http.Response _ok([int status = 200]) =>
    jsonResponse(<String, Object?>{'ok': true}, status: status);

TypeMatcher<BeckLinkException> _beckLinkError(
  BeckLinkErrorCode code, {
  int? statusCode,
  Duration? retryAfter,
}) {
  var matcher = isA<BeckLinkException>().having((e) => e.code, 'code', code);
  if (statusCode != null) {
    matcher = matcher.having((e) => e.statusCode, 'statusCode', statusCode);
  }
  if (retryAfter != null) {
    matcher = matcher.having((e) => e.retryAfter, 'retryAfter', retryAfter);
  }
  return matcher;
}

/// An [ApiClient] on the fake SDK API, in virtual time, with a jitter
/// source that always draws [jitter]: the n-th retry waits
/// `jitter × 2 s × 2^n` (capped at 5 minutes).
final class _Rig {
  _Rig(this.async, {double jitter = 0.5, bool compressEvents = false}) {
    client = ApiClient(
      apiKey: testKey,
      logger: SdkLogger(level: LogLevel.debug, sink: logs.add),
      httpClient: api.client,
      baseUrl: fakeBaseUrl,
      now: () => start.add(async.elapsed),
      random: FixedRandom(jitter),
      compressEvents: compressEvents,
    );
  }

  final FakeAsync async;
  final DateTime start = DateTime.utc(2026, 10, 7, 12);
  final FakeSdkApi api = FakeSdkApi();
  final LogCapture logs = LogCapture();
  late final ApiClient client;

  /// Starts a call that reads the status code of the answer.
  _Call<int> call(
    ApiEndpoint endpoint, {
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) =>
      callWith(
        endpoint,
        (response) => response.statusCode,
        body: body,
        idempotencyKey: idempotencyKey,
      );

  /// Starts a call that reads the answer with [read].
  _Call<T> callWith<T>(
    ApiEndpoint endpoint,
    ResponseReader<T> read, {
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) {
    final call = _Call<T>();
    unawaited(
      client
          .post(
            endpoint,
            body: body ?? (endpoint == ApiEndpoint.open ? _openBody : _body),
            read: read,
            idempotencyKey: idempotencyKey,
          )
          .then<void>(call._succeed, onError: call._fail),
    );
    async.flushMicrotasks();
    return call;
  }

  int requestsTo(String path) => api.to(path).length;
}

/// The outcome of one [ApiClient.post] in virtual time.
final class _Call<T> {
  bool _done = false;
  T? _value;
  Object? _error;

  bool get isDone => _done;

  T get value {
    if (!_done) fail('The call has not finished');
    if (_error != null) fail('The call failed: $_error');
    return _value as T;
  }

  Object? get error {
    if (!_done) fail('The call has not finished');
    return _error;
  }

  void _succeed(T value) {
    _done = true;
    _value = value;
  }

  void _fail(Object error) {
    _done = true;
    _error = error;
  }
}

void main() {
  group('requests', () {
    test('carry the contract headers and the JSON body', () {
      fakeAsync((async) {
        final rig = _Rig(async);

        expect(rig.call(ApiEndpoint.init).value, 200);
        final request = rig.api.requests.single;
        expect(request.path, SdkPaths.init);
        expect(
            request.headers, containsPair('authorization', 'Bearer $testKey'));
        expect(
            request.headers, containsPair('content-type', 'application/json'));
        expect(
          request.headers,
          containsPair('accept', 'application/json, application/problem+json'),
        );
        expect(
          request.headers,
          containsPair('user-agent', 'becklink_flutter/$sdkVersion'),
        );
        expect(request.headers, containsPair('x-sdk-name', 'becklink_flutter'));
        expect(request.headers, containsPair('x-sdk-version', sdkVersion));
        expect(request.headers.keys, isNot(contains('idempotency-key')));
        expect(request.headers.keys, isNot(contains('content-encoding')));
        expect(request.json, _body);
      });
    });

    test('to open and links carry an Idempotency-Key, the same on every retry',
        () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..enqueue(
              SdkPaths.open, (_) => problemResponse(503, 'service_unavailable'))
          ..respond(SdkPaths.open, (_) => _ok());

        final call = rig.call(ApiEndpoint.open);
        async.elapse(const Duration(seconds: 5));

        expect(call.value, 200);
        final requests = rig.api.to(SdkPaths.open);
        expect(requests, hasLength(2));
        expect(requests.first.headers['idempotency-key'], isLowercaseUuid);
        expect(
          requests.last.headers['idempotency-key'],
          requests.first.headers['idempotency-key'],
        );
        expect(requests.last.bodyBytes, requests.first.bodyBytes);
      });
    });

    test('use the Idempotency-Key the caller passes', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.links, (_) => _ok(201));

        rig.call(ApiEndpoint.links, idempotencyKey: 'share-42');

        expect(
          rig.api.requests.single.headers['idempotency-key'],
          'share-42',
        );
      });
    });

    test('refuse an Idempotency-Key where the body carries a natural key', () {
      fakeAsync((async) {
        final rig = _Rig(async);

        final call = rig.call(ApiEndpoint.firstOpen, idempotencyKey: 'k');

        expect(call.error, isArgumentError);
        expect(rig.api.requests, isEmpty);
      });
    });

    test('gzip event batches only', () {
      fakeAsync((async) {
        final rig = _Rig(async, compressEvents: true);
        final batch = <String, Object?>{
          ..._body,
          'events': <Object?>[
            <String, Object?>{'name': 'purchase'},
          ],
        };

        rig.call(ApiEndpoint.events, body: batch);
        rig.call(ApiEndpoint.init);

        final events = rig.api.to(SdkPaths.events).single;
        expect(events.headers['content-encoding'], 'gzip');
        expect(gzip.decode(events.bodyBytes), isNotEmpty);
        expect(events.json, batch);
        expect(
          rig.api.to(SdkPaths.init).single.headers.keys,
          isNot(contains('content-encoding')),
        );
      });
    });

    test('over the endpoint limit are refused before anything is sent', () {
      fakeAsync((async) {
        final rig = _Rig(async);

        final call = rig.call(
          ApiEndpoint.init,
          body: <String, Object?>{'blob': 'x' * (8 * 1024)},
        );

        expect(call.error, _beckLinkError(BeckLinkErrorCode.invalidRequest));
        expect(rig.api.requests, isEmpty);
      });
    });

    test('with values that are not JSON are a programming error', () {
      fakeAsync((async) {
        final rig = _Rig(async);

        final call = rig.call(
          ApiEndpoint.init,
          body: <String, Object?>{'at': DateTime.utc(2026)},
        );

        expect(call.error, isArgumentError);
        expect(rig.api.requests, isEmpty);
      });
    });
  });

  group('retries', () {
    test('wait a full-jitter exponential backoff between attempts', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..enqueue(
              SdkPaths.init, (_) => problemResponse(503, 'service_unavailable'))
          ..enqueue(
              SdkPaths.init, (_) => problemResponse(500, 'internal_error'))
          ..respond(SdkPaths.init, (_) => _ok());

        final call = rig.call(ApiEndpoint.init);
        expect(rig.requestsTo(SdkPaths.init), 1);

        // Retry 0 waits 0.5 × 2 s.
        async.elapse(const Duration(milliseconds: 999));
        expect(rig.requestsTo(SdkPaths.init), 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(rig.requestsTo(SdkPaths.init), 2);

        // Retry 1 waits 0.5 × 4 s.
        async.elapse(const Duration(milliseconds: 1999));
        expect(rig.requestsTo(SdkPaths.init), 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(rig.requestsTo(SdkPaths.init), 3);

        expect(call.value, 200);
      });
    });

    test('stop at the endpoint budget: 3 attempts for init, 5 for open', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..respond(
              SdkPaths.init, (_) => problemResponse(503, 'service_unavailable'))
          ..respond(
              SdkPaths.open, (_) => problemResponse(500, 'internal_error'));

        final init = rig.call(ApiEndpoint.init);
        final open = rig.call(ApiEndpoint.open);
        async.elapse(const Duration(minutes: 10));

        expect(
          init.error,
          _beckLinkError(BeckLinkErrorCode.network, statusCode: 503),
        );
        expect(rig.requestsTo(SdkPaths.init), 3);
        expect(
          open.error,
          _beckLinkError(BeckLinkErrorCode.network, statusCode: 500),
        );
        expect(rig.requestsTo(SdkPaths.open), 5);
      });
    });

    test('retry a lost connection', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..enqueue(SdkPaths.init, offline)
          ..respond(SdkPaths.init, (_) => _ok());

        final call = rig.call(ApiEndpoint.init);
        async.elapse(const Duration(seconds: 2));

        expect(call.value, 200);
        expect(rig.requestsTo(SdkPaths.init), 2);
      });
    });

    final notRetried = <(int, String, BeckLinkErrorCode)>[
      (400, 'malformed_request', BeckLinkErrorCode.invalidRequest),
      (401, 'invalid_api_key', BeckLinkErrorCode.invalidKey),
      (403, 'insufficient_scope', BeckLinkErrorCode.invalidKey),
      (404, 'link_not_found', BeckLinkErrorCode.linkNotFound),
      (409, 'conflict', BeckLinkErrorCode.invalidRequest),
      (413, 'payload_too_large', BeckLinkErrorCode.invalidRequest),
      (415, 'unsupported_media_type', BeckLinkErrorCode.invalidRequest),
      (422, 'validation_failed', BeckLinkErrorCode.invalidRequest),
    ];
    for (final (status, code, expected) in notRetried) {
      test('never retry $status $code', () {
        fakeAsync((async) {
          final rig = _Rig(async);
          rig.api.respond(SdkPaths.open, (_) => problemResponse(status, code));

          final call = rig.call(ApiEndpoint.open);
          async.elapse(const Duration(minutes: 10));

          expect(call.error, _beckLinkError(expected, statusCode: status));
          expect(rig.requestsTo(SdkPaths.open), 1);
        });
      });
    }

    final retried = <(int, String)>[
      (408, 'request_timeout'),
      (409, 'idempotency_key_in_progress'),
      (429, 'rate_limited'),
    ];
    for (final (status, code) in retried) {
      test('retry $status $code', () {
        fakeAsync((async) {
          final rig = _Rig(async);
          rig.api
            ..enqueue(SdkPaths.open, (_) => problemResponse(status, code))
            ..respond(SdkPaths.open, (_) => _ok());

          final call = rig.call(ApiEndpoint.open);
          async.elapse(const Duration(seconds: 5));

          expect(call.value, 200);
          expect(rig.requestsTo(SdkPaths.open), 2);
        });
      });
    }

    test('wait at least the Retry-After seconds', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..enqueue(
            SdkPaths.init,
            (_) => problemResponse(
              429,
              'rate_limited',
              headers: <String, String>{'retry-after': '10'},
            ),
          )
          ..respond(SdkPaths.init, (_) => _ok());

        final call = rig.call(ApiEndpoint.init);
        async.elapse(const Duration(milliseconds: 9999));
        expect(rig.requestsTo(SdkPaths.init), 1);
        async.elapse(const Duration(milliseconds: 1));

        expect(rig.requestsTo(SdkPaths.init), 2);
        expect(call.value, 200);
      });
    });

    test('read Retry-After as an HTTP date', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        final until = HttpDate.format(
          rig.start.add(const Duration(seconds: 20)),
        );
        rig.api
          ..enqueue(
            SdkPaths.init,
            (_) => problemResponse(
              503,
              'service_unavailable',
              headers: <String, String>{'retry-after': until},
            ),
          )
          ..respond(SdkPaths.init, (_) => _ok());

        rig.call(ApiEndpoint.init);
        async.elapse(const Duration(milliseconds: 19999));
        expect(rig.requestsTo(SdkPaths.init), 1);
        async.elapse(const Duration(milliseconds: 1));

        expect(rig.requestsTo(SdkPaths.init), 2);
      });
    });

    test('give up at once when Retry-After is longer than the backoff cap', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..respond(
            SdkPaths.init,
            (_) => problemResponse(
              429,
              'rate_limited',
              headers: <String, String>{'retry-after': '301'},
            ),
          )
          ..respond(
            SdkPaths.open,
            (_) => problemResponse(
              503,
              'service_unavailable',
              headers: <String, String>{'retry-after': '3600'},
            ),
          );

        final init = rig.call(ApiEndpoint.init);
        final open = rig.call(ApiEndpoint.open);

        expect(
          init.error,
          _beckLinkError(
            BeckLinkErrorCode.rateLimited,
            retryAfter: const Duration(seconds: 301),
          ),
        );
        expect(
          open.error,
          _beckLinkError(
            BeckLinkErrorCode.network,
            retryAfter: const Duration(hours: 1),
          ),
        );
        expect(rig.api.requests, hasLength(2));
      });
    });

    test('end an attempt that gets no answer after its timeout', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.init, hang);

        final call = rig.call(ApiEndpoint.init);
        // 10 s attempts with waits of 1 s and 2 s between them.
        async.elapse(const Duration(seconds: 32));
        expect(call.isDone, isFalse);
        expect(rig.requestsTo(SdkPaths.init), 3);
        async.elapse(const Duration(seconds: 1));

        expect(call.error, _beckLinkError(BeckLinkErrorCode.timeout));
      });
    });

    test('keep createLink within its 30 s deadline', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.links, hang);

        final call = rig.call(ApiEndpoint.links);
        // A 15 s attempt, a 1 s wait, then an attempt shortened to the
        // 14 s left; a third attempt would not fit.
        async.elapse(const Duration(milliseconds: 29999));
        expect(call.isDone, isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(call.error, _beckLinkError(BeckLinkErrorCode.timeout));
        expect(rig.requestsTo(SdkPaths.links), 2);
      });
    });

    test('keep retrying a first open for up to 24 hours, then give up', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.firstOpen, offline);

        final call = rig.call(ApiEndpoint.firstOpen);
        // At the cap each wait is 0.5 × 5 min; the last attempt starts at
        // most one wait before the deadline.
        async.elapse(const Duration(hours: 24) - const Duration(seconds: 151));
        expect(call.isDone, isFalse);
        async.elapse(const Duration(seconds: 151));

        expect(call.error, _beckLinkError(BeckLinkErrorCode.network));
        // Hundreds of attempts, never a tight loop: about one per 150 s.
        final attempts = rig.requestsTo(SdkPaths.firstOpen);
        expect(attempts, greaterThan(500));
        expect(attempts, lessThan(600));
      });
    });
  });

  group('answers', () {
    test('map a problem to its code with the request ID', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..enqueue(
            SdkPaths.links,
            (_) => problemResponse(
              422,
              'validation_failed',
              detail: 'Unknown campaign key.',
              headers: <String, String>{'x-request-id': 'req_header'},
            ),
          )
          ..enqueue(
            SdkPaths.links,
            (_) => problemResponse(
              422,
              'validation_failed',
              requestId: 'req_body',
            ),
          );

        final fromHeader = rig.call(ApiEndpoint.links);
        final fromBody = rig.call(ApiEndpoint.links);

        expect(
          fromHeader.error,
          _beckLinkError(BeckLinkErrorCode.invalidRequest, statusCode: 422)
              .having((e) => e.requestId, 'requestId', 'req_header')
              .having((e) => e.message, 'message', 'Unknown campaign key.'),
        );
        expect(
          fromBody.error,
          isA<BeckLinkException>()
              .having((e) => e.requestId, 'requestId', 'req_body'),
        );
      });
    });

    test('treat a 2xx HTML page (captive portal) as unreadable and retry', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(
          SdkPaths.init,
          (_) => http.Response(
            '<html>Sign in to Wi-Fi</html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          ),
        );

        final call = rig.call(ApiEndpoint.init);
        async.elapse(const Duration(minutes: 1));

        expect(call.error, _beckLinkError(BeckLinkErrorCode.network));
        expect(rig.requestsTo(SdkPaths.init), 3);
      });
    });

    test('refuse a body over 1 MiB without reading it to the end', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(
          SdkPaths.init,
          (_) => http.Response.bytes(
            List<int>.filled(ApiClient.maxResponseBytes + 1, 0x20),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        );

        final call = rig.call(ApiEndpoint.init);
        async.elapse(const Duration(minutes: 1));

        expect(call.error, _beckLinkError(BeckLinkErrorCode.network));
      });
    });

    test('do not retry a 2xx answer whose shape this SDK cannot read', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(
          SdkPaths.init,
          (_) => jsonResponse(<String, Object?>{'config': 'oops'}),
        );

        final call = rig.callWith(
          ApiEndpoint.init,
          (response) => readRemoteConfig(response.body.object('config')),
        );
        async.elapse(const Duration(minutes: 1));

        expect(
          call.error,
          _beckLinkError(BeckLinkErrorCode.network).having(
            (e) => e.message,
            'message',
            contains('/config'),
          ),
        );
        expect(rig.requestsTo(SdkPaths.init), 1);
      });
    });

    test('report a replayed idempotent answer', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(
          SdkPaths.links,
          (_) => jsonResponse(
            createdLinkJson(),
            status: 201,
            headers: <String, String>{'idempotent-replayed': 'true'},
          ),
        );

        final call = rig.callWith(
          ApiEndpoint.links,
          (response) => response.replayed,
        );

        expect(call.value, isTrue);
      });
    });
  });

  group('a refused key', () {
    test('after a 401, no call reaches the network', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(
          SdkPaths.init,
          (_) => problemResponse(401, 'invalid_api_key'),
        );

        final first = rig.call(ApiEndpoint.init);
        final second = rig.call(ApiEndpoint.links);
        async.elapse(const Duration(minutes: 1));

        expect(
          first.error,
          _beckLinkError(BeckLinkErrorCode.invalidKey, statusCode: 401),
        );
        expect(
          second.error,
          _beckLinkError(BeckLinkErrorCode.invalidKey, statusCode: 401),
        );
        expect(rig.client.isKeyRejected, isTrue);
        expect(rig.api.requests, hasLength(1));
      });
    });

    test('a 403 (missing scope) does not stop later calls', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api
          ..respond(
            SdkPaths.links,
            (_) => problemResponse(403, 'insufficient_scope'),
          )
          ..respond(SdkPaths.init, (_) => _ok());

        final links = rig.call(ApiEndpoint.links);
        final init = rig.call(ApiEndpoint.init);

        expect(links.error, _beckLinkError(BeckLinkErrorCode.invalidKey));
        expect(init.value, 200);
        expect(rig.client.isKeyRejected, isFalse);
      });
    });
  });

  group('close', () {
    test('ends a request in flight', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.firstOpen, hang);

        final call = rig.call(ApiEndpoint.firstOpen);
        rig.client.close();
        async.flushMicrotasks();

        expect(call.error, isA<ApiClientClosedException>());
      });
    });

    test('ends a retry wait', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.api.respond(SdkPaths.firstOpen, offline);

        final call = rig.call(ApiEndpoint.firstOpen);
        expect(call.isDone, isFalse);
        rig.client.close();
        async.flushMicrotasks();

        expect(call.error, isA<ApiClientClosedException>());
        expect(rig.requestsTo(SdkPaths.firstOpen), 1);
      });
    });

    test('refuses later calls', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.client.close();

        expect(
          rig.call(ApiEndpoint.init).error,
          isA<ApiClientClosedException>(),
        );
        expect(rig.client.isClosed, isTrue);
        expect(rig.api.requests, isEmpty);
      });
    });
  });

  group('construction', () {
    ApiClient build({String apiKey = testKey, Uri? baseUrl}) => ApiClient(
          apiKey: apiKey,
          logger: SdkLogger(level: LogLevel.none),
          httpClient: MockClient((_) async => _ok()),
          baseUrl: baseUrl,
          retryPolicy: const RetryPolicy(),
        );

    test('accepts HTTPS anywhere and HTTP only on this machine', () {
      for (final url in <String>[
        'https://api.becklinks.com',
        'http://localhost:4100',
        'http://127.0.0.1:4100',
        'http://10.0.2.2:4100',
        'http://[::1]:4100',
      ]) {
        expect(build(baseUrl: Uri.parse(url)).isClosed, isFalse, reason: url);
      }
    });

    test('refuses plain HTTP elsewhere and URLs that are not an origin', () {
      for (final url in <String>[
        'http://api.becklinks.com',
        'https://api.becklinks.com/v1',
        'https://api.becklinks.com?debug=1',
        'https://user@api.becklinks.com',
        'ftp://api.becklinks.com',
      ]) {
        expect(
          () => build(baseUrl: Uri.parse(url)),
          throwsArgumentError,
          reason: url,
        );
      }
    });

    test('refuses an API key that cannot go into a header, without echoing it',
        () {
      expect(
        () => build(apiKey: 'pk_test_ with space'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'description',
            isNot(contains('with space')),
          ),
        ),
      );
    });
  });
}
