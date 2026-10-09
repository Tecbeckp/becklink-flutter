import 'dart:convert';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinkOptions', () {
    test('builds the request body with utm null when no UTM value is set', () {
      final options = LinkOptions(
        deepLinkPath: '/referral',
        data: const <String, Object?>{'reward': 'free_month'},
        campaign: 'referral',
        expiresAt: DateTime.utc(2026, 12, 31),
      );

      expect(options.toJson(), <String, Object?>{
        'deep_link_path': '/referral',
        'data': <String, Object?>{'reward': 'free_month'},
        'campaign': 'referral',
        'utm': null,
        'expires_at': '2026-12-31T00:00:00.000Z',
      });
    });

    test('nests trimmed UTM values', () {
      final options = LinkOptions(
        deepLinkPath: '/product/123',
        source: '  app ',
        medium: 'share',
      );

      expect(options.toJson()['utm'], <String, Object?>{
        'source': 'app',
        'medium': 'share',
        'content': null,
        'term': null,
        'creative': null,
      });
    });

    test('converts expiresAt to UTC', () {
      final local = DateTime(2026, 12, 31, 23);
      final options = LinkOptions(deepLinkPath: '/', expiresAt: local);

      expect(options.expiresAt!.isUtc, isTrue);
      expect(options.expiresAt, local.toUtc());
    });

    group('refuses', () {
      void expectRefused(LinkOptions Function() build, String argument) {
        expect(
          build,
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', argument),
          ),
        );
      }

      test('a deep-link path that does not start with a slash', () {
        expectRefused(
            () => LinkOptions(deepLinkPath: 'product/1'), 'deepLinkPath');
      });

      test('a deep-link path with whitespace or control characters', () {
        expectRefused(() => LinkOptions(deepLinkPath: '/a b'), 'deepLinkPath');
        expectRefused(() => LinkOptions(deepLinkPath: '/a\tb'), 'deepLinkPath');
        expectRefused(
          () => LinkOptions(deepLinkPath: '/a b'),
          'deepLinkPath',
        );
        expectRefused(
          () => LinkOptions(deepLinkPath: '/a\u0085b'),
          'deepLinkPath',
        );
      });

      test('a deep-link path over 2,048 characters', () {
        final longest = '/${'a' * 2047}';
        expect(LinkOptions(deepLinkPath: longest).deepLinkPath, longest);
        expectRefused(
          () => LinkOptions(deepLinkPath: '$longest/'),
          'deepLinkPath',
        );
      });

      test('data over 4,096 bytes of compact UTF-8 JSON', () {
        // {"blob":"…"} is 11 bytes plus the value.
        final fits = <String, Object?>{'blob': 'x' * (4096 - 11)};
        expect(utf8.encode(jsonEncode(fits)).length, 4096);
        expect(LinkOptions(deepLinkPath: '/', data: fits).data, fits);

        expectRefused(
          () => LinkOptions(
            deepLinkPath: '/',
            data: <String, Object?>{'blob': 'x' * (4096 - 10)},
          ),
          'data',
        );
        // Multi-byte characters count as their UTF-8 bytes.
        expectRefused(
          () => LinkOptions(
            deepLinkPath: '/',
            data: <String, Object?>{'blob': 'é' * 2100},
          ),
          'data',
        );
      });

      test('data keys over 64 characters at any level', () {
        final key64 = 'k' * 64;
        expect(
          LinkOptions(
            deepLinkPath: '/',
            data: <String, Object?>{
              key64: <String, Object?>{key64: 1},
            },
          ).data,
          hasLength(1),
        );
        expectRefused(
          () => LinkOptions(
            deepLinkPath: '/',
            data: <String, Object?>{
              'list': <Object?>[
                <String, Object?>{'k' * 65: 1},
              ],
            },
          ),
          'data',
        );
      });

      test('data that is not JSON, including cycles', () {
        expectRefused(
          () => LinkOptions(
            deepLinkPath: '/',
            data: <String, Object?>{'at': DateTime.utc(2026)},
          ),
          'data',
        );
        final cycle = <String, Object?>{};
        cycle['self'] = cycle;
        expectRefused(
          () => LinkOptions(deepLinkPath: '/', data: cycle),
          'data',
        );
      });

      test('a campaign that is not a campaign key', () {
        for (final key in <String>['Referral', '-referral', 'refer ral', '']) {
          expectRefused(
            () => LinkOptions(deepLinkPath: '/', campaign: key),
            'campaign',
          );
        }
        expect(
          LinkOptions(deepLinkPath: '/', campaign: 'summer_sale-2026').campaign,
          'summer_sale-2026',
        );
      });

      test('blank or over-long UTM values', () {
        expectRefused(
          () => LinkOptions(deepLinkPath: '/', source: '   '),
          'source',
        );
        expectRefused(
          () => LinkOptions(deepLinkPath: '/', term: 't' * 256),
          'term',
        );
        expect(
          LinkOptions(deepLinkPath: '/', creative: 'c' * 255).creative,
          hasLength(255),
        );
      });
    });

    test('equality compares data deeply', () {
      LinkOptions build() => LinkOptions(
            deepLinkPath: '/p',
            data: <String, Object?>{
              'a': <Object?>[1, 2],
            },
          );

      expect(build(), build());
      expect(build().hashCode, build().hashCode);
    });

    test('leaves the path query and data values out of toString', () {
      final text = LinkOptions(
        deepLinkPath: '/invite?token=abc',
        data: const <String, Object?>{'email': 'someone@example.com'},
      ).toString();

      expect(text, isNot(contains('token=abc')));
      expect(text, isNot(contains('someone@example.com')));
    });
  });
}
