import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/sdk_harness.dart';
import '../helpers/test_support.dart';

Matcher _failsWith(BeckLinkErrorCode code) => throwsA(
      isA<BeckLinkException>().having((e) => e.code, 'code', code),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => setAppLifecycle(AppLifecycleState.resumed));

  test('creates a link and returns its URL', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.getAttribution();
    final installId =
        device.api.to(SdkPaths.firstOpen).single.json['install_id'];

    final url = await sdk.createLink(
      LinkOptions(
        deepLinkPath: '/product/123',
        data: const <String, Object?>{'product_id': '123'},
        campaign: 'summer_sale',
        source: 'app',
        medium: 'share',
        expiresAt: device.clock.now().add(const Duration(days: 30)),
      ),
    );

    expect(url, 'https://$testHost/k7Qm2Xa');
    final request = device.api.to(SdkPaths.links).single;
    expect(request.headers['idempotency-key'], isLowercaseUuid);
    expect(request.json, <String, Object?>{
      'deep_link_path': '/product/123',
      'data': <String, Object?>{'product_id': '123'},
      'campaign': 'summer_sale',
      'utm': <String, Object?>{
        'source': 'app',
        'medium': 'share',
        'content': null,
        'term': null,
        'creative': null,
      },
      'expires_at': '2026-11-06T12:00:00.000Z',
      'install_id': installId,
    });
  });

  test('a referral link carries the signed-in user unless data names one',
      () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.setUserId('user_8841');

    await sdk.createLink(LinkOptions(deepLinkPath: '/referral'));
    await sdk.createLink(
      LinkOptions(
        deepLinkPath: '/referral',
        data: const <String, Object?>{'referrer_user_id': 'team_account'},
      ),
    );

    final requests = device.api.to(SdkPaths.links);
    expect(requests.first.json['data'], <String, Object?>{
      'referrer_user_id': 'user_8841',
    });
    expect(requests.last.json['data'], <String, Object?>{
      'referrer_user_id': 'team_account',
    });
  });

  test('with tracking off, the link names neither install nor user', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.getAttribution();
    await sdk.setUserId('user_8841');
    await sdk.setTrackingEnabled(false);

    await sdk.createLink(LinkOptions(deepLinkPath: '/referral'));

    final body = device.api.to(SdkPaths.links).single.json;
    expect(body.keys, isNot(contains('install_id')));
    expect(body['data'], isEmpty);
  });

  test('refuses an expiry that is not in the future, before sending', () async {
    final device = newDevice();
    final sdk = await device.launch();

    await expectLater(
      sdk.createLink(
        LinkOptions(deepLinkPath: '/sale', expiresAt: device.clock.now()),
      ),
      throwsArgumentError,
    );
    expect(device.api.to(SdkPaths.links), isEmpty);
  });

  test('refuses data that grows over 4 KB with referrer_user_id', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.setUserId('user_8841');
    // {"blob":"…"} is exactly 4,096 bytes: valid on its own.
    final options = LinkOptions(
      deepLinkPath: '/referral',
      data: <String, Object?>{'blob': 'x' * (4096 - 11)},
    );

    await expectLater(sdk.createLink(options), throwsArgumentError);
    expect(device.api.to(SdkPaths.links), isEmpty);
  });

  group('reports why a link could not be created', () {
    test('an invalid request, with the service explanation', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.links,
        (_) => problemResponse(
          422,
          'validation_failed',
          detail: 'Unknown campaign key.',
        ),
      );
      final sdk = await device.launch();

      await expectLater(
        sdk.createLink(LinkOptions(deepLinkPath: '/p', campaign: 'nope')),
        throwsA(
          isA<BeckLinkException>()
              .having((e) => e.code, 'code', BeckLinkErrorCode.invalidRequest)
              .having((e) => e.message, 'message', 'Unknown campaign key.')
              .having((e) => e.statusCode, 'statusCode', 422),
        ),
      );
      expect(device.api.to(SdkPaths.links), hasLength(1));
    });

    test('a missing scope', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.links,
        (_) => problemResponse(403, 'insufficient_scope'),
      );
      final sdk = await device.launch();

      await expectLater(
        sdk.createLink(LinkOptions(deepLinkPath: '/p')),
        _failsWith(BeckLinkErrorCode.invalidKey),
      );
    });

    test('a rate limit, with the wait the service asked for', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.links,
        (_) => problemResponse(
          429,
          'rate_limited',
          headers: <String, String>{'retry-after': '120'},
        ),
      );
      final sdk = await device.launch();

      await expectLater(
        sdk.createLink(LinkOptions(deepLinkPath: '/p')),
        throwsA(
          isA<BeckLinkException>()
              .having((e) => e.code, 'code', BeckLinkErrorCode.rateLimited)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 120),
              ),
        ),
      );
    });

    test('no connection, after three attempts', () async {
      final device = newDevice();
      device.api.respond(SdkPaths.links, offline);
      final sdk = await device.launch();

      await expectLater(
        sdk.createLink(LinkOptions(deepLinkPath: '/p')),
        _failsWith(BeckLinkErrorCode.network),
      );
      expect(device.api.to(SdkPaths.links), hasLength(3));
    });
  });
}
