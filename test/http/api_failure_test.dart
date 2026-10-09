import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/http/api_failure.dart';
import 'package:becklink_flutter/src/http/api_problem.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyErrorResponse by problem code', () {
    // Contract sections 10.2 and 10.3: code → (status, SDK code, retry).
    const table = <String, (int, BeckLinkErrorCode, bool)>{
      'malformed_request': (400, BeckLinkErrorCode.invalidRequest, false),
      'idempotency_key_required': (
        400,
        BeckLinkErrorCode.invalidRequest,
        false,
      ),
      'invalid_api_key': (401, BeckLinkErrorCode.invalidKey, false),
      'insufficient_scope': (403, BeckLinkErrorCode.invalidKey, false),
      'link_not_found': (404, BeckLinkErrorCode.linkNotFound, false),
      'not_found': (404, BeckLinkErrorCode.invalidRequest, false),
      'method_not_allowed': (405, BeckLinkErrorCode.invalidRequest, false),
      'request_timeout': (408, BeckLinkErrorCode.timeout, true),
      'idempotency_key_in_progress': (409, BeckLinkErrorCode.network, true),
      'payload_too_large': (413, BeckLinkErrorCode.invalidRequest, false),
      'unsupported_media_type': (415, BeckLinkErrorCode.invalidRequest, false),
      'validation_failed': (422, BeckLinkErrorCode.invalidRequest, false),
      'idempotency_key_reused': (422, BeckLinkErrorCode.invalidRequest, false),
      'rate_limited': (429, BeckLinkErrorCode.rateLimited, true),
      'internal_error': (500, BeckLinkErrorCode.network, true),
      'service_unavailable': (503, BeckLinkErrorCode.network, true),
    };

    test('covers every code the SDK knows', () {
      expect(
        table.keys.toSet(),
        ServerErrorCode.values.map((code) => code.wireValue).toSet(),
      );
    });

    for (final entry in table.entries) {
      final (status, code, retryable) = entry.value;
      test('${entry.key} → ${code.wireValue}, retryable: $retryable', () {
        final failure = classifyErrorResponse(
          statusCode: status,
          problem: ApiProblem(code: entry.key),
        );

        expect(failure.exception.code, code);
        expect(failure.retryable, retryable);
        expect(failure.rejectsKey, status == 401);
      });
    }
  });

  group('classifyErrorResponse by status', () {
    // Answers without a known problem code: a proxy, or a newer server code.
    const table = <int, (BeckLinkErrorCode, bool)>{
      400: (BeckLinkErrorCode.invalidRequest, false),
      401: (BeckLinkErrorCode.invalidKey, false),
      403: (BeckLinkErrorCode.invalidKey, false),
      404: (BeckLinkErrorCode.invalidRequest, false),
      408: (BeckLinkErrorCode.timeout, true),
      409: (BeckLinkErrorCode.invalidRequest, false),
      418: (BeckLinkErrorCode.invalidRequest, false),
      429: (BeckLinkErrorCode.rateLimited, true),
      500: (BeckLinkErrorCode.network, true),
      502: (BeckLinkErrorCode.network, true),
      503: (BeckLinkErrorCode.network, true),
      302: (BeckLinkErrorCode.network, true),
    };

    for (final entry in table.entries) {
      final (code, retryable) = entry.value;
      test('${entry.key} → ${code.wireValue}', () {
        final failure = classifyErrorResponse(
          statusCode: entry.key,
          problem: entry.key.isEven
              ? null
              : const ApiProblem(code: 'added_in_a_later_version'),
        );

        expect(failure.exception.code, code);
        expect(failure.retryable, retryable);
        expect(failure.exception.statusCode, entry.key);
      });
    }
  });

  group('exception details', () {
    test('a 401 latches the key; a 403 does not', () {
      expect(classifyErrorResponse(statusCode: 401).rejectsKey, isTrue);
      expect(classifyErrorResponse(statusCode: 403).rejectsKey, isFalse);
    });

    test('carries the request ID and the wait the service asked for', () {
      final rateLimited = classifyErrorResponse(
        statusCode: 429,
        requestId: 'req_1',
        retryAfter: const Duration(seconds: 30),
      );
      final unavailable = classifyErrorResponse(
        statusCode: 503,
        retryAfter: const Duration(seconds: 120),
      );

      expect(rateLimited.exception.requestId, 'req_1');
      expect(rateLimited.retryAfter, const Duration(seconds: 30));
      expect(unavailable.retryAfter, const Duration(seconds: 120));
    });

    test('builds the message from detail and the first three field errors', () {
      final problem = ApiProblem.tryParse(<String, Object?>{
        'code': 'validation_failed',
        'title': 'Validation failed',
        'detail': 'The request has 4 invalid fields.',
        'errors': <Object?>[
          <String, Object?>{'pointer': '/a', 'detail': 'is missing'},
          <String, Object?>{'pointer': '/b', 'code': 'too_long'},
          <String, Object?>{'pointer': '/c', 'detail': 'is not a string'},
          <String, Object?>{'pointer': '/d', 'detail': 'is wrong'},
        ],
      });
      final failure = classifyErrorResponse(statusCode: 422, problem: problem);

      expect(
        failure.exception.message,
        'The request has 4 invalid fields.; /a: is missing; /b: too_long; '
        '/c: is not a string; 1 more field errors',
      );
    });

    test('keeps server text on one line and at most 500 characters', () {
      final problem = ApiProblem(
        code: 'validation_failed',
        detail: 'line one\nFAKE LOG LINE${'x' * 600}',
      );
      final message = classifyErrorResponse(
        statusCode: 422,
        problem: problem,
      ).exception.message;

      expect(message, isNot(contains('\n')));
      expect(message.length, lessThanOrEqualTo(500));
      expect(message, endsWith('…'));
    });

    test('falls back to its own message without problem text', () {
      final failure = classifyErrorResponse(statusCode: 503);

      expect(failure.exception.message, contains('HTTP 503'));
    });
  });

  group('ApiProblem.tryParse', () {
    test('reads members leniently', () {
      final problem = ApiProblem.tryParse(<String, Object?>{
        'code': 7,
        'title': '  ',
        'detail': <String, Object?>{},
        'request_id': 'req_9',
        'errors': 'none',
      });

      expect(problem, isNotNull);
      expect(problem!.code, isNull);
      expect(problem.title, isNull);
      expect(problem.detail, isNull);
      expect(problem.requestId, 'req_9');
      expect(problem.fieldErrors, isEmpty);
    });

    test('is null for a body that is not an object', () {
      expect(ApiProblem.tryParse('<html>'), isNull);
      expect(ApiProblem.tryParse(null), isNull);
    });
  });

  group('other failures', () {
    test('no connection and attempt timeouts are retried', () {
      expect(connectionFailure().retryable, isTrue);
      expect(connectionFailure().exception.code, BeckLinkErrorCode.network);
      expect(attemptTimeout().retryable, isTrue);
      expect(attemptTimeout().exception.code, BeckLinkErrorCode.timeout);
    });

    test('an unreadable answer is retried, an incompatible one is not', () {
      expect(unreadableResponse(statusCode: 200).retryable, isTrue);
      final incompatible = incompatibleResponse(
        statusCode: 200,
        reason: 'Malformed SDK JSON at "/config": expected an object.',
      );
      expect(incompatible.retryable, isFalse);
      expect(incompatible.exception.code, BeckLinkErrorCode.network);
      expect(incompatible.exception.message, contains('/config'));
    });
  });
}
