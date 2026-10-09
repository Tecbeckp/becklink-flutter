import 'dart:io' show HttpDate;

import 'package:becklink_flutter/src/http/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  group('RetryPolicy.backoff', () {
    const policy = RetryPolicy();

    test('doubles the ceiling from 2 s and caps it at 5 minutes', () {
      // Just below 1.0, so the wait is (almost) the ceiling itself.
      final top = FixedRandom(0.999999);
      final ceilings = <int>[
        for (var retry = 0; retry < 10; retry++)
          policy.backoff(retry, top).inMilliseconds,
      ];

      expect(ceilings.take(8), <int>[
        1999,
        3999,
        7999,
        15999,
        31999,
        63999,
        127999,
        255999,
      ]);
      // 2 s × 2^8 = 512 s is over the cap.
      expect(ceilings[8], 299999);
      expect(ceilings[9], 299999);
    });

    test('draws a full-jitter wait between zero and the ceiling', () {
      expect(policy.backoff(0, FixedRandom(0)), Duration.zero);
      expect(policy.backoff(0, FixedRandom(0.5)), const Duration(seconds: 1));
      expect(policy.backoff(1, FixedRandom(0.5)), const Duration(seconds: 2));
      expect(policy.backoff(3, FixedRandom(0.25)), const Duration(seconds: 4));
    });

    test('stays at the cap for retry numbers where 2^n overflows an int', () {
      // A 24-hour budget at the cap allows hundreds of retries; an int power
      // would wrap from retry 43 on and turn the wait negative or zero.
      for (final retry in <int>[42, 43, 62, 63, 64, 10000]) {
        expect(
          policy.backoff(retry, FixedRandom(0.5)),
          const Duration(seconds: 150),
          reason: 'retry $retry',
        );
      }
    });
  });

  group('parseRetryAfter', () {
    final now = DateTime.utc(2026, 10, 7, 12);

    test('reads delay seconds', () {
      expect(parseRetryAfter('120', now), const Duration(seconds: 120));
      expect(parseRetryAfter(' 0 ', now), Duration.zero);
    });

    test('reads an HTTP date relative to now', () {
      final date = HttpDate.format(now.add(const Duration(seconds: 90)));

      expect(parseRetryAfter(date, now), const Duration(seconds: 90));
    });

    test('treats a date in the past as no wait', () {
      final date = HttpDate.format(now.subtract(const Duration(hours: 1)));

      expect(parseRetryAfter(date, now), Duration.zero);
    });

    test('ignores missing and malformed values', () {
      expect(parseRetryAfter(null, now), isNull);
      expect(parseRetryAfter('-5', now), isNull);
      expect(parseRetryAfter('1.5', now), isNull);
      expect(parseRetryAfter('soon', now), isNull);
      expect(parseRetryAfter('Wed, 99 Oct 2026 99:99:99 GMT', now), isNull);
    });
  });
}
