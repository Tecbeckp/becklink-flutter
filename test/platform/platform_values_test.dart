import 'package:becklink_flutter/src/platform/native_time.dart';
import 'package:becklink_flutter/src/platform/pasteboard_click_url.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  group('pasteboard click URL (contract section 9.3)', () {
    const hosts = <String>['*.becklinks.com', 'go.acme.com'];

    test('accepts https://{host}/_c/{ULID} of an allowed host', () {
      for (final url in <String>[
        pasteboardClickUrl,
        'https://go.acme.com/_c/$clickId',
        'https://ACME.becklinks.com/_c/${clickId.toLowerCase()}',
        'https://acme.becklinks.com:443/_c/$clickId',
      ]) {
        expect(isPasteboardClickUrl(url, hosts), isTrue, reason: url);
      }
    });

    test('refuses anything else', () {
      for (final url in <String>[
        'http://acme.becklinks.com/_c/$clickId',
        'https://becklinks.com/_c/$clickId',
        'https://a.b.becklinks.com/_c/$clickId',
        'https://evilbecklinks.com/_c/$clickId',
        'https://acme.becklinks.com.evil.com/_c/$clickId',
        'https://user@acme.becklinks.com/_c/$clickId',
        'https://acme.becklinks.com:8443/_c/$clickId',
        'https://acme.becklinks.com/_c/$clickId?x=1',
        'https://acme.becklinks.com/_c/$clickId#x',
        'https://acme.becklinks.com/_c/$clickId/',
        'https://acme.becklinks.com/summer24',
        // A ULID starts with 0–7 and has no I, L, O or U.
        'https://acme.becklinks.com/_c/8${clickId.substring(1)}',
        'https://acme.becklinks.com/_c/0${'I' * 25}',
        'https://acme.becklinks.com/_c/${clickId.substring(1)}',
        'https://x.go.acme.com/_c/$clickId',
        'some text https://acme.becklinks.com/_c/$clickId',
        '',
      ]) {
        expect(isPasteboardClickUrl(url, hosts), isFalse, reason: url);
      }
    });

    test('a wildcard matches exactly one more label', () {
      expect(
          hostMatchesPattern('acme.becklinks.com', '*.becklinks.com'), isTrue);
      expect(hostMatchesPattern('becklinks.com', '*.becklinks.com'), isFalse);
      expect(
          hostMatchesPattern('a.b.becklinks.com', '*.becklinks.com'), isFalse);
      expect(hostMatchesPattern('go.acme.com', 'go.acme.com'), isTrue);
      expect(hostMatchesPattern('x.go.acme.com', 'go.acme.com'), isFalse);
    });

    test('host patterns are lowercase hosts of two or more labels', () {
      expect(isPasteboardHostPattern('*.becklinks.com'), isTrue);
      expect(isPasteboardHostPattern('go.acme.com'), isTrue);
      for (final pattern in <String>[
        '*.app',
        'localhost',
        'Go.acme.com',
        '-acme.com',
        'acme-.com',
        'acme..com',
        '*.*.becklinks.com',
        'acme.com:443',
      ]) {
        expect(isPasteboardHostPattern(pattern), isFalse, reason: pattern);
      }
    });
  });

  group('native time', () {
    test('reads positive epoch values as UTC', () {
      expect(
        dateTimeFromEpochMilliseconds(1791374400123),
        DateTime.fromMillisecondsSinceEpoch(1791374400123, isUtc: true),
      );
      expect(
        dateTimeFromEpochSeconds(1791374400),
        DateTime.fromMillisecondsSinceEpoch(1791374400000, isUtc: true),
      );
    });

    test('treats 0, negatives, wrong types and overflow as unknown', () {
      expect(dateTimeFromEpochSeconds(0), isNull);
      expect(dateTimeFromEpochMilliseconds(-1), isNull);
      expect(dateTimeFromEpochMilliseconds('1791374400123'), isNull);
      expect(dateTimeFromEpochMilliseconds(1.5), isNull);
      expect(dateTimeFromEpochSeconds(8640000000001), isNull);
    });
  });

  group('PlatformLink', () {
    test('keeps the query out of toString', () {
      final link = PlatformLink(
        url: 'https://$testHost/abc?token=secret',
        receivedAt: DateTime.utc(2026),
      );

      expect(link.toString(), isNot(contains('secret')));
      expect(link.toString(), contains(testHost));
    });

    test('is identified by URL and receive time', () {
      final at = DateTime.utc(2026);

      expect(
        PlatformLink(url: testLinkUrl, receivedAt: at),
        PlatformLink(url: testLinkUrl, receivedAt: at),
      );
      expect(
        PlatformLink(url: testLinkUrl, receivedAt: at),
        isNot(
          PlatformLink(
            url: testLinkUrl,
            receivedAt: at.add(const Duration(milliseconds: 1)),
          ),
        ),
      );
    });
  });
}
