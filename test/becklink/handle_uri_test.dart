import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/platform/install_referrer_result.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/sdk_harness.dart';
import '../helpers/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => setAppLifecycle(AppLifecycleState.resumed));

  final t1 = DateTime.utc(2026, 10, 7, 11, 59, 58, 125);
  final t2 = t1.add(const Duration(seconds: 1));

  const testUrl = 'https://$testHost/summer24';
  const liveUrl = 'https://$liveHost/summer24';

  group('isBeckLinkUri', () {
    // [url, accepted by a test key, accepted by a live key]
    final table = <(String, bool, bool)>[
      (testUrl, true, false),
      ('$testUrl?ref=newsletter', true, false),
      (liveUrl, false, true),
      ('https://ACME-TEST.BeckLinks.com/summer24', true, false),
      ('https://other.example.com/summer24', false, false),
      ('https://$testHost.evil.com/summer24', false, false),
      ('https://evil.com/?x=$testHost', false, false),
      ('https://evil.com/summer24?u=https://$testHost/summer24', false, false),
      ('https://$testHost@evil.com/summer24', false, false),
      ('https://$testHost:8443/summer24', false, false),
      ('https://user:pw@$testHost/summer24', false, false),
      ('http://$testHost/summer24', false, false),
      ('https://www.becklinks.com/summer24', false, false),
      ('https://becklinks.com/summer24', false, false),
      ('https://a.b.becklinks.com/summer24', false, false),
      ('https://$testHost/', false, false),
      ('acmeshop://becklink?url=${Uri.encodeComponent(testUrl)}', true, false),
      ('acmeshop://becklink?url=${Uri.encodeComponent(liveUrl)}', false, true),
      ('acmeshop://becklink?url=https%3A%2F%2Fevil.com%2Fx', false, false),
      ('acmeshop://other?url=${Uri.encodeComponent(testUrl)}', false, false),
      ('acmeshop://becklink', false, false),
      ('acmeshop://product/123', false, false),
      ('com.acme.app:/oauth2redirect?code=abc', false, false),
    ];

    for (final (url, forTest, forLive) in table) {
      test('$url: test key $forTest, live key $forLive', () async {
        final uri = Uri.parse(url);
        final testDevice = newDevice();
        final testSdk = await testDevice.launch();
        expect(testSdk.isBeckLinkUri(uri), forTest);

        final liveDevice = newDevice();
        final liveSdk = await liveDevice.launch(apiKey: liveKey);
        expect(liveSdk.isBeckLinkUri(uri), forLive);
      });
    }

    test('before configure() any platform host counts, other hosts do not',
        () async {
      final device = newDevice();
      final sdk = await device.start();

      expect(sdk.isBeckLinkUri(Uri.parse(testUrl)), isTrue);
      expect(sdk.isBeckLinkUri(Uri.parse(liveUrl)), isTrue);
      expect(
        sdk.isBeckLinkUri(
          Uri.parse('acmeshop://becklink?url=${Uri.encodeComponent(testUrl)}'),
        ),
        isTrue,
      );
      expect(sdk.isBeckLinkUri(Uri.parse('https://evil.com/?x=$testHost')),
          isFalse);
      expect(sdk.isBeckLinkUri(Uri.parse('https://$testHost.evil.com/a')),
          isFalse);
    });

    test('a cached custom link host counts once storage is open', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(
          firstOpenAnswerJson(
            config: configJson(linkHosts: <String>[testHost, 'go.acme.dev']),
          ),
        ),
      );
      final first = await device.launch();
      await first.getAttribution();
      final sdk = await device.launch();
      await sdk.getDiagnostics();

      expect(sdk.isBeckLinkUri(Uri.parse('https://go.acme.dev/promo')), isTrue);
      expect(sdk.isBeckLinkUri(Uri.parse('https://evil.dev/promo')), isFalse);
    });
  });

  group('handleUri', () {
    test('delivers one LinkEvent and returns true', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      final taken = await sdk.handleUri(Uri.parse(testLinkUrl));
      await eventually(() => received.isNotEmpty);
      await settle();

      expect(taken, isTrue);
      expect(received, hasLength(1));
      expect(received.single.linkId, linkId);
      expect(received.single.isDeferred, isFalse);
      expect(device.api.to(SdkPaths.open).single.json['url'], testLinkUrl);
      await subscription.cancel();
    });

    test('returns false for foreign URIs and sends nothing', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      for (final url in <String>[
        'https://example.com/path?token=secret',
        'https://evil.com/?x=$testHost',
        'https://$testHost.evil.com/summer24',
        liveUrl, // the other environment
        'acmeshop://product/123',
        'com.acme.app:/oauth2redirect?code=abc',
      ]) {
        expect(await sdk.handleUri(Uri.parse(url)), isFalse, reason: url);
      }
      await settle();

      expect(received, isEmpty);
      expect(device.api.to(SdkPaths.open), isEmpty);
      expect(device.logs.lines.join('\n'), isNot(contains('secret')));
      await subscription.cancel();
    });

    test(
        'the same URI twice within the window is delivered once, a later '
        'one again', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      final uri = Uri.parse(testLinkUrl);
      await sdk.handleUri(uri);
      await sdk.handleUri(uri);
      await eventually(() => received.isNotEmpty);
      await settle();
      expect(received, hasLength(1));

      device.clock.advance(const Duration(seconds: 11));
      await sdk.handleUri(uri);
      await eventually(() => received.length == 2);
      await subscription.cancel();
    });

    test('platform first, then handleUri: delivered once', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      device.platform
          .deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t1));
      await eventually(() => received.isNotEmpty);
      final taken = await sdk.handleUri(Uri.parse(testLinkUrl));
      await settle();

      expect(taken, isTrue);
      expect(received, hasLength(1));
      expect(device.api.to(SdkPaths.open), hasLength(1));
      await subscription.cancel();
    });

    test('handleUri first, then platform: delivered once', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      await sdk.handleUri(Uri.parse(testLinkUrl));
      await eventually(() => received.isNotEmpty);
      device.platform
          .deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t2));
      await settle();

      expect(received, hasLength(1));
      expect(device.api.to(SdkPaths.open), hasLength(1));
      await subscription.cancel();
    });

    test('the platform path still delivers a repeated open of its own',
        () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      device.platform
        ..deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t1))
        ..deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t2));
      await eventually(() => received.length == 2);
      await subscription.cancel();
    });

    test('an uppercase host is the same URL as the platform reported',
        () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      device.platform.deliverLink(
        PlatformLink(
            url: 'https://ACME-TEST.becklinks.com/summer24', receivedAt: t1),
      );
      await eventually(() => received.isNotEmpty);
      await sdk.handleUri(Uri.parse(testUrl));
      await settle();

      expect(received, hasLength(1));
      await subscription.cancel();
    });

    test(
        'works while configure() is still starting and waits for the launch '
        'link', () async {
      final device = newDevice();
      final sdk = await device.launchRegistered(
        setUpPlatform: (platform) =>
            platform.initialLink = PlatformLink(url: testUrl, receivedAt: t1),
      );
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      // No await in between: storage is not open yet.
      final taken = sdk.handleUri(Uri.parse('https://$testHost/second'));
      expect(await taken, isTrue);
      await eventually(() => received.length == 2);

      expect(received.map((link) => link.url.path),
          <String>['/summer24', '/second']);
      await subscription.cancel();
    });

    test('before configure() a Beck Link URI waits, a foreign one is false',
        () async {
      final device = newDevice();
      final sdk = await device.start();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      expect(await sdk.handleUri(Uri.parse('https://example.com/x')), isFalse);
      expect(await sdk.handleUri(Uri.parse(testUrl)), isTrue);
      expect(received, isEmpty);

      await sdk.configure(apiKey: testKey);
      await eventually(() => received.isNotEmpty);

      expect(received.single.url.path, '/summer24');
      await subscription.cancel();
    });

    test('with tracking off the link is resolved without identifiers',
        () async {
      final device = newDevice();
      final sdk = await device.launchRegistered();
      await sdk.setTrackingEnabled(false);
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      expect(await sdk.handleUri(Uri.parse(testUrl)), isTrue);
      await eventually(() => received.isNotEmpty);

      final request = device.api.to(SdkPaths.open).single;
      expect(request.json['tracking_enabled'], isFalse);
      expect(request.json.containsKey('install_id'), isFalse);
      await subscription.cancel();
    });
  });

  group('handlePlatformLinks: false', () {
    test('ignores the launch link and later native links', () async {
      final device = newDevice();
      final first = await device.launch();
      await first.getAttribution();
      final sdk = await device.launch(
        handlePlatformLinks: false,
        setUpPlatform: (platform) => platform.initialLink =
            PlatformLink(url: testLinkUrl, receivedAt: t1),
      );
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      expect(await sdk.getInitialLink(), isNull);
      device.platform
          .deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t2));
      await settle(const Duration(milliseconds: 150));

      expect(received, isEmpty);
      expect(device.platform.initialLinkCalls, 0);
      expect(device.api.to(SdkPaths.open), isEmpty);
      await subscription.cancel();
    });

    test('still handles handleUri, once, even when the platform saw it too',
        () async {
      final device = newDevice();
      final first = await device.launch();
      await first.getAttribution();
      final sdk = await device.launch(handlePlatformLinks: false);
      await sdk.getInitialLink();
      final received = <LinkEvent>[];
      final subscription = sdk.onLink.listen(received.add);

      device.platform
          .deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t1));
      expect(await sdk.handleUri(Uri.parse(testLinkUrl)), isTrue);
      await eventually(() => received.isNotEmpty);
      await settle(const Duration(milliseconds: 150));

      expect(received, hasLength(1));
      expect(device.api.to(SdkPaths.open), hasLength(1));
      await subscription.cancel();
    });

    test('the first open and a deferred link are unchanged', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(installReferrerAnswerJson()),
      );
      final sdk = await device.launch(
        handlePlatformLinks: false,
        setUpPlatform: (platform) => platform.referrer =
            InstallReferrerFound(rawReferrer: installReferrer),
      );

      final link = await sdk.getInitialLink();

      expect(link, isNotNull);
      expect(link!.isDeferred, isTrue);
      expect(
        device.api.to(SdkPaths.firstOpen).single.json.obj('evidence'),
        <String, Object?>{'android_install_referrer': installReferrer},
      );
    });
  });
}
