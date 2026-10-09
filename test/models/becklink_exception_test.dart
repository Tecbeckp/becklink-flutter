import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BeckLinkException', () {
    test('named constructors carry their stable codes', () {
      expect(
        const BeckLinkException.notConfigured().code,
        BeckLinkErrorCode.notConfigured,
      );
      expect(
        const BeckLinkException.invalidKey().code,
        BeckLinkErrorCode.invalidKey,
      );
      expect(const BeckLinkException.network().code, BeckLinkErrorCode.network);
      expect(
        const BeckLinkException.rateLimited().statusCode,
        429,
      );
      expect(
        const BeckLinkException.trackingDisabled().code,
        BeckLinkErrorCode.trackingDisabled,
      );
      expect(const BeckLinkException.linkNotFound().statusCode, 404);
      expect(const BeckLinkException.timeout().code, BeckLinkErrorCode.timeout);
      expect(
        const BeckLinkException.invalidRequest().code,
        BeckLinkErrorCode.invalidRequest,
      );
    });

    test('compares by value', () {
      expect(
        const BeckLinkException.rateLimited(
          retryAfter: Duration(seconds: 30),
          requestId: 'req_1',
        ),
        const BeckLinkException.rateLimited(
          retryAfter: Duration(seconds: 30),
          requestId: 'req_1',
        ),
      );
      expect(
        const BeckLinkException.rateLimited(retryAfter: Duration(seconds: 30)),
        isNot(
          const BeckLinkException.rateLimited(
            retryAfter: Duration(seconds: 31),
          ),
        ),
      );
    });

    test('describes code, status, wait and request ID', () {
      const exception = BeckLinkException.rateLimited(
        retryAfter: Duration(seconds: 30),
        requestId: 'req_1',
      );

      expect(
        exception.toString(),
        'BeckLinkException(rate_limited, status: 429, retryAfter: 30s, '
        'requestId: req_1): ${exception.message}',
      );
    });
  });
}
