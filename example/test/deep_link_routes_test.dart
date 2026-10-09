import 'package:becklink_flutter_example/src/deep_link_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('appLocationForDeepLink', () {
    test('opens the known screens', () {
      expect(appLocationForDeepLink('/'), '/');
      expect(appLocationForDeepLink('/referral'), '/referral');
      expect(appLocationForDeepLink('/referral/'), '/referral');
      expect(appLocationForDeepLink('/product/123'), '/product/123');
      expect(appLocationForDeepLink('/product/123/'), '/product/123');
      expect(appLocationForDeepLink('/product/sku_A-1'), '/product/sku_A-1');
    });

    test("drops the path's own query string", () {
      expect(appLocationForDeepLink('/product/123?coupon=X'), '/product/123');
      expect(appLocationForDeepLink('/?tab=sale'), '/');
    });

    test('accepts product IDs of up to 64 characters', () {
      final longest = 'a' * 64;

      expect(appLocationForDeepLink('/product/$longest'), '/product/$longest');
      expect(appLocationForDeepLink('/product/${longest}a'), isNull);
    });

    test('never opens the Debug screen, which can reset the install', () {
      expect(appLocationForDeepLink('/debug'), isNull);
      expect(appLocationForDeepLink('/product/../debug'), isNull);
    });

    test('refuses unknown paths and malformed product IDs', () {
      for (final path in <String>[
        '/unknown',
        '/product',
        '/product/',
        '/product/1/reviews',
        '/PRODUCT/1',
        '/referral/friend',
        '/product/a.b',
        // An encoded slash must not smuggle in another segment.
        '/product/1%2Fdebug',
      ]) {
        expect(appLocationForDeepLink(path), isNull, reason: path);
      }
    });

    test('refuses anything that is not a path', () {
      for (final path in <String>[
        '',
        'product/123',
        'https://evil.example.com/product/123',
        '//evil.example.com/product/123',
        'javascript:alert(1)',
      ]) {
        expect(appLocationForDeepLink(path), isNull, reason: path);
      }
    });

    test('refuses an invalid percent-encoding', () {
      expect(appLocationForDeepLink('/product/%E0'), isNull);
    });
  });
}
