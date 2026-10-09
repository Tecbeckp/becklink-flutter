import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/core/event_input.dart';
import 'package:becklink_flutter/src/core/sdk_options.dart';
import 'package:becklink_flutter/src/core/user_id.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

Matcher _argumentErrorWithout(String secret) => throwsA(
      isA<ArgumentError>().having(
        (error) => error.toString(),
        'description',
        isNot(contains(secret)),
      ),
    );

void main() {
  group('publishable key', () {
    test('decides the environment', () {
      expect(parsePublishableKey(testKey), SdkEnvironment.test);
      expect(parsePublishableKey(liveKey), SdkEnvironment.live);
      expect(parsePublishableKey('pk_test_${'a' * 8}'), SdkEnvironment.test);
      expect(
        parsePublishableKey('pk_live_${'A1_-' * 64}'),
        SdkEnvironment.live,
      );
    });

    test('refuses a secret key with its own message, never echoing it', () {
      for (final key in <String>[
        'sk_live_SuperSecret123456',
        ' sk_test_SuperSecret123456',
        'SK_LIVE_SuperSecret123456',
      ]) {
        expect(
          () => parsePublishableKey(key),
          throwsA(
            isA<BeckLinkException>()
                .having((e) => e.code, 'code', BeckLinkErrorCode.invalidKey)
                .having((e) => e.message, 'message', contains('secret key'))
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('SuperSecret')),
                ),
          ),
          reason: key,
        );
      }
    });

    test('refuses anything that is not a publishable key', () {
      for (final key in <String>[
        '',
        'pk_test_short',
        'pk_prod_0123456789abcdef',
        'pk_test_0123456789.abcdef',
        'pk_test_${'a' * 257}',
        'PK_TEST_0123456789abcdef',
        'pk_test_0123456789abcdef ',
      ]) {
        expect(
          () => parsePublishableKey(key),
          throwsA(
            isA<BeckLinkException>()
                .having((e) => e.code, 'code', BeckLinkErrorCode.invalidKey),
          ),
          reason: key,
        );
      }
    });
  });

  group('SdkOptions.parse', () {
    SdkOptions parse({Duration timeout = const Duration(seconds: 3)}) =>
        SdkOptions.parse(
          apiKey: testKey,
          logLevel: LogLevel.error,
          enablePasteboard: false,
          firstOpenTimeout: timeout,
        );

    test('accepts a first-open timeout from zero to 30 seconds', () {
      expect(parse(timeout: Duration.zero).firstOpenTimeout, Duration.zero);
      expect(
        parse(timeout: const Duration(seconds: 30)).firstOpenTimeout,
        const Duration(seconds: 30),
      );
      expect(
        () => parse(timeout: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => parse(timeout: const Duration(seconds: 30, milliseconds: 1)),
        throwsArgumentError,
      );
    });

    test('compares by value and never shows the key', () {
      expect(parse(), parse());
      expect(parse().toString(), isNot(contains(testKey)));
      expect(parse().toString(), contains('test'));
    });
  });

  group('track() input (contract section 8.4)', () {
    test('accepts names of lower-case letters, digits and _', () {
      for (final name in <String>['purchase', 'add_to_cart', 'level_2', 'a']) {
        expect(checkEventInput(name).name, name);
      }
      expect(checkEventInput('e' * 64).name, hasLength(64));
    });

    test('refuses other names', () {
      for (final name in <String>[
        '',
        'Purchase',
        'add-to-cart',
        'add to cart',
        'e' * 65,
        'café',
      ]) {
        expect(() => checkEventInput(name), throwsArgumentError, reason: name);
      }
    });

    test('drops null properties and keeps a flat map', () {
      final input = checkEventInput(
        'purchase',
        properties: <String, Object?>{
          'sku': 'A1',
          'quantity': 2,
          'gift': false,
          'note': null,
        },
      );

      expect(input.properties, <String, Object?>{
        'sku': 'A1',
        'quantity': 2,
        'gift': false,
      });
      expect(
        checkEventInput(
          'purchase',
          properties: <String, Object?>{'note': null},
        ).properties,
        isNull,
      );
    });

    test(
        'refuses nested values, non-finite numbers and bad keys, without '
        'naming them', () {
      final bad = <Map<String, Object?>>[
        <String, Object?>{
          'secret_key': <String, Object?>{'a': 1},
        },
        <String, Object?>{
          'secret_key': <Object?>[1],
        },
        <String, Object?>{'secret_key': double.nan},
        <String, Object?>{'': 'secret_value'},
        <String, Object?>{'k' * 65: 'secret_value'},
        <String, Object?>{'secret\nkey': 'secret_value'},
      ];
      for (final properties in bad) {
        expect(
          () => checkEventInput('e', properties: properties),
          _argumentErrorWithout('secret_value'),
          reason: properties.keys.toString(),
        );
      }
    });

    test('allows at most 50 properties and 8 KB', () {
      Map<String, Object?> keys(int count) =>
          <String, Object?>{for (var i = 0; i < count; i++) 'k$i': i};

      expect(
        checkEventInput('e', properties: keys(50)).properties,
        hasLength(50),
      );
      expect(
        () => checkEventInput('e', properties: keys(51)),
        throwsArgumentError,
      );
      expect(
        () => checkEventInput(
          'e',
          properties: <String, Object?>{'blob': 'x' * 8200},
        ),
        throwsArgumentError,
      );
    });

    test(
        'needs revenue and currency together and sends the currency '
        'upper-case', () {
      final input = checkEventInput('purchase', revenue: 9.99, currency: 'usd');

      expect(input.revenue, 9.99);
      expect(input.currency, 'USD');
      expect(
        () => checkEventInput('purchase', revenue: 9.99),
        throwsArgumentError,
      );
      expect(
        () => checkEventInput('purchase', currency: 'USD'),
        throwsArgumentError,
      );
      expect(
        () => checkEventInput('purchase', revenue: 1, currency: 'US'),
        throwsArgumentError,
      );
    });

    test('keeps revenue within ±1,000,000,000 and finite', () {
      expect(
        checkEventInput('refund', revenue: -1000000000, currency: 'EUR')
            .revenue,
        -1000000000,
      );
      for (final revenue in <num>[1000000000.01, double.infinity, double.nan]) {
        expect(
          () => checkEventInput('e', revenue: revenue, currency: 'EUR'),
          throwsArgumentError,
          reason: '$revenue',
        );
      }
    });
  });

  group('user ID (contract section 2)', () {
    test('accepts 1 to 256 characters, counted as code points', () {
      expect(checkUserId('u'), 'u');
      expect(checkUserId('u' * 256), hasLength(256));
      expect(checkUserId('😀' * 256).runes.length, 256);
    });

    test('refuses empty, over-long and control characters, without echoing',
        () {
      expect(() => checkUserId(''), throwsArgumentError);
      expect(() => checkUserId('u' * 257), _argumentErrorWithout('uuuuu'));
      expect(
        () => checkUserId('jane@example.com\n'),
        _argumentErrorWithout('jane@example.com'),
      );
    });
  });
}
