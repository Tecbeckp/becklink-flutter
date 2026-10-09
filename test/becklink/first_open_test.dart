import 'dart:async';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/platform/install_id_seed_result.dart';
import 'package:becklink_flutter/src/platform/install_referrer_result.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_platform.dart';
import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/sdk_harness.dart';
import '../helpers/test_support.dart';

const String _keychainId = '3F6C1B9E-8D2A-4C47-9B1E-5A7D2C8E4F10';

void _withReferrer(FakePlatform platform) =>
    platform.referrer = InstallReferrerFound(rawReferrer: installReferrer);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => setAppLifecycle(AppLifecycleState.resumed));

  group('first run', () {
    test('Android: a Play install referrer match is the deferred link',
        () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(installReferrerAnswerJson()),
      );
      final sdk = await device.launch(setUpPlatform: _withReferrer);

      final link = await sdk.getInitialLink();
      final attribution = await sdk.getAttribution();

      expect(link, isNotNull);
      expect(link!.isDeferred, isTrue);
      expect(link.matchMethod, MatchMethod.installReferrer);
      expect(link.confidence, Confidence.certain);
      expect(link.path, '/product/123');
      expect(link.data, <String, Object?>{
        'coupon': 'SUMMER10',
        'color': 'blue',
      });
      expect(link.linkId, linkId);
      expect(link.campaign?.name, 'Summer sale 2026');
      expect(attribution.state, AttributionState.attributed);
      expect(attribution.matchMethod, MatchMethod.installReferrer);
      expect(attribution.linkId, linkId);
      // Delivered on onLink as well, once.
      expect(await sdk.onLink.first, link);

      final body = device.api.to(SdkPaths.firstOpen).single.json;
      expect(body['install_id'], isLowercaseUuid);
      expect(body['first_open_id'], isLowercaseUuid);
      expect(body['first_open_id'], isNot(body['install_id']));
      expect(body['user_id'], isNull);
      expect(body['evidence'], <String, Object?>{
        'android_install_referrer': installReferrer,
      });
      expect(body['context'], <String, Object?>{
        'platform': 'android',
        'os_version': '15',
        'app_version': '1.2.3',
        'app_build': '45',
        'device_model': 'Pixel 8',
        'locale': 'en-US',
      });
      expect(device.api.to(SdkPaths.init), isEmpty);
      expect(device.api.to(SdkPaths.open), isEmpty);
    });

    test('an install without a matching click is organic', () async {
      final device = newDevice();
      final sdk = await device.launch();

      expect(await sdk.getInitialLink(), isNull);
      final attribution = await sdk.getAttribution();
      expect(attribution.state, AttributionState.organic);
      expect(attribution.linkId, isNull);
      expect(
        device.api.to(SdkPaths.firstOpen).single.json['evidence'],
        isEmpty,
      );
    });

    test('Android: an empty referrer is not sent as evidence', () async {
      final device = newDevice();
      final sdk = await device.launch(
        setUpPlatform: (platform) =>
            platform.referrer = InstallReferrerFound(rawReferrer: ''),
      );

      await sdk.getAttribution();

      expect(
        device.api.to(SdkPaths.firstOpen).single.json['evidence'],
        isEmpty,
      );
    });

    test('iOS: the opt-in pasteboard click URL is the deferred link', () async {
      final device = newDevice(TargetPlatform.iOS);
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(pasteboardAnswerJson()),
      );
      final sdk = await device.launch(
        enablePasteboard: true,
        setUpPlatform: (platform) =>
            platform.pasteboardUrl = pasteboardClickUrl,
      );

      final link = await sdk.getInitialLink();

      expect(link!.isDeferred, isTrue);
      expect(link.matchMethod, MatchMethod.pasteboard);
      expect(
        (await sdk.getAttribution()).matchMethod,
        MatchMethod.pasteboard,
      );
      expect(device.platform.pasteboardReads, <List<String>>[
        <String>['*.becklinks.com'],
      ]);
      expect(device.platform.referrerReads, 0);
      final body = device.api.to(SdkPaths.firstOpen).single.json;
      expect(body['evidence'], <String, Object?>{
        'ios_pasteboard_url': pasteboardClickUrl,
      });
      expect(body.obj('context')['platform'], 'ios');
      // The new install ID is kept in the Keychain for a later reinstall.
      expect(
          device.platform.savedSeeds, <String>[body['install_id']! as String]);
    });

    test('iOS: the pasteboard is not read without the opt-in', () async {
      final device = newDevice(TargetPlatform.iOS);
      final sdk = await device.launch(
        setUpPlatform: (platform) =>
            platform.pasteboardUrl = pasteboardClickUrl,
      );

      await sdk.getAttribution();

      expect(device.platform.pasteboardReads, isEmpty);
      expect(
        device.api.to(SdkPaths.firstOpen).single.json['evidence'],
        isEmpty,
      );
    });

    test('iOS: a click URL of the other environment is not sent', () async {
      final device = newDevice(TargetPlatform.iOS);
      final sdk = await device.launch(
        enablePasteboard: true,
        setUpPlatform: (platform) =>
            platform.pasteboardUrl = 'https://$liveHost/_c/$clickId',
      );

      await sdk.getAttribution();

      expect(
        device.api.to(SdkPaths.firstOpen).single.json['evidence'],
        <String, Object?>{'ios_pasteboard_url': null},
      );
      expect(device.logs.text, isNot(contains(liveHost)));
    });

    test('a link that opened the app on the first run is sent as open_url',
        () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(directOpenAnswerJson()),
      );
      final sdk = await device.launch(
        setUpPlatform: (platform) {
          platform
            ..initialLink = PlatformLink(
              url: testLinkUrl,
              receivedAt: device.clock.now(),
            )
            ..referrer = InstallReferrerFound(rawReferrer: installReferrer);
        },
      );

      final link = await sdk.getInitialLink();

      expect(link!.isDeferred, isFalse);
      expect(link.matchMethod, MatchMethod.appLink);
      expect(link.linkId, linkId);
      expect(
        device.api.to(SdkPaths.firstOpen).single.json['evidence'],
        <String, Object?>{
          'open_url': testLinkUrl,
          'android_install_referrer': installReferrer,
        },
      );
      expect(device.api.to(SdkPaths.open), isEmpty);
      expect(await sdk.onLink.first, link);
    });
  });

  group('first-open timeout', () {
    test(
        'the app gets no deferred link and pending attribution, then the '
        'final one', () async {
      final device = newDevice();
      final answer = Completer<http.Response>();
      device.api.respond(SdkPaths.firstOpen, (_) => answer.future);
      final sdk = await device.start(setUpPlatform: _withReferrer);
      final attributions = <Attribution>[];
      final subscription = sdk.onAttribution.listen(attributions.add);
      await sdk.configure(
        apiKey: testKey,
        logLevel: LogLevel.debug,
        firstOpenTimeout: const Duration(milliseconds: 100),
      );

      expect(await sdk.getInitialLink(), isNull);
      final pending = await sdk.getAttribution();
      expect(pending.state, AttributionState.pending);
      expect(pending.installedAt, device.clock.now());

      answer.complete(jsonResponse(installReferrerAnswerJson()));
      await eventually(() => attributions.length == 2);

      expect(
        attributions.map((attribution) => attribution.state),
        <AttributionState>[
          AttributionState.pending,
          AttributionState.attributed,
        ],
      );
      expect(
        (await sdk.getAttribution()).state,
        AttributionState.attributed,
      );
      // A deferred link that matched after the timeout is not delivered.
      final links = <LinkEvent>[];
      final linkSubscription = sdk.onLink.listen(links.add);
      await settle();
      expect(links, isEmpty);
      expect(device.logs.text, contains('it is not delivered'));
      await linkSubscription.cancel();
      await subscription.cancel();
    });

    test('a launch link is delivered without its data when the answer is late',
        () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => Completer<http.Response>().future,
      );
      final receivedAt = device.clock.now();
      final sdk = await device.launch(
        firstOpenTimeout: const Duration(milliseconds: 100),
        setUpPlatform: (platform) => platform.initialLink = PlatformLink(
          url: testLinkUrl,
          receivedAt: receivedAt,
        ),
      );

      final link = await sdk.getInitialLink();

      expect(link, isNotNull);
      expect(link!.linkId, isNull);
      expect(link.path, '/summer24');
      expect(link.params, <String, String>{'ref': 'newsletter'});
      expect(link.clickedAt, receivedAt);
    });
  });

  group('retries', () {
    test('a retry within the process sends the same body', () async {
      final device = newDevice();
      device.api.enqueue(
        SdkPaths.firstOpen,
        (_) => problemResponse(503, 'service_unavailable'),
      );
      final sdk = await device.launch(setUpPlatform: _withReferrer);

      expect((await sdk.getAttribution()).state, AttributionState.organic);

      final requests = device.api.to(SdkPaths.firstOpen);
      expect(requests, hasLength(2));
      expect(requests.last.bodyBytes, requests.first.bodyBytes);
    });

    test(
        'after the app was killed, the next launch retries with the same '
        'first_open_id and evidence', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => Completer<http.Response>().future,
      );
      final killed = await device.launch(
        firstOpenTimeout: const Duration(milliseconds: 50),
        setUpPlatform: _withReferrer,
      );
      expect(await killed.getInitialLink(), isNull);

      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(organicAnswerJson()),
      );
      final sdk = await device.launch(
        setUpPlatform: (platform) =>
            platform.referrer = const InstallReferrerUnavailable(
          InstallReferrerFailure.serviceUnavailable,
        ),
      );

      expect((await sdk.getAttribution()).state, AttributionState.organic);
      final requests = device.api.to(SdkPaths.firstOpen);
      expect(requests, hasLength(2));
      expect(
        requests.last.json['install_id'],
        requests.first.json['install_id'],
      );
      expect(
        requests.last.json['first_open_id'],
        requests.first.json['first_open_id'],
      );
      expect(requests.last.json['evidence'], <String, Object?>{
        'android_install_referrer': installReferrer,
      });
      // Play is asked once per install, not on the retry.
      expect(device.platform.referrerReads, 0);
    });

    test('a refused key ends the first open and stops later requests',
        () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => problemResponse(401, 'invalid_api_key'),
      );
      final sdk = await device.launch();

      expect(await sdk.getInitialLink(), isNull);
      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      expect(
        device.logs.at(LogLevel.error),
        contains(contains('The first open failed')),
      );
      await expectLater(
        sdk.createLink(LinkOptions(deepLinkPath: '/referral')),
        throwsA(
          isA<BeckLinkException>()
              .having((e) => e.code, 'code', BeckLinkErrorCode.invalidKey),
        ),
      );
      expect(device.api.requests, hasLength(1));
    });
  });

  group('install identity', () {
    test(
        'iOS: a reinstall keeps the Keychain install ID with a new '
        'first_open_id', () async {
      final device = newDevice(TargetPlatform.iOS);
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(
          firstOpenAnswerJson(
            attribution: attributionJson(
              state: 'reinstall',
              matchMethod: null,
              confidence: null,
              id: null,
              withCampaign: false,
            ),
          ),
        ),
      );
      final sdk = await device.launch(
        setUpPlatform: (platform) =>
            platform.seed = const InstallIdSeedFound(_keychainId),
      );

      expect((await sdk.getAttribution()).state, AttributionState.reinstall);
      final body = device.api.to(SdkPaths.firstOpen).single.json;
      expect(body['install_id'], _keychainId.toLowerCase());
      expect(body['first_open_id'], isLowercaseUuid);
      expect(body['first_open_id'], isNot(body['install_id']));
      expect(device.platform.savedSeeds, isEmpty);
    });

    test(
        'iOS: a Keychain that cannot be read yet postpones the install to '
        'the next foreground', () async {
      final device = newDevice(TargetPlatform.iOS);
      final sdk = await device.launch(
        setUpPlatform: (platform) =>
            platform.seed = const InstallIdSeedUnavailable(),
      );

      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      expect(device.api.to(SdkPaths.firstOpen), isEmpty);

      device.platform.seed = const InstallIdSeedFound(_keychainId);
      await setAppLifecycle(AppLifecycleState.paused);
      await setAppLifecycle(AppLifecycleState.resumed);
      await device.api.waitFor(SdkPaths.firstOpen, 1);

      expect(
        device.api.to(SdkPaths.firstOpen).single.json['install_id'],
        _keychainId.toLowerCase(),
      );
    });

    test('a later launch answers from storage and starts a session', () async {
      final device = newDevice();
      device.api.respond(
        SdkPaths.firstOpen,
        (_) => jsonResponse(installReferrerAnswerJson()),
      );
      final first = await device.launch(setUpPlatform: _withReferrer);
      expect(await first.getInitialLink(), isNotNull);
      final installId =
          device.api.to(SdkPaths.firstOpen).single.json['install_id'];

      final sdk = await device.launch();

      final attribution = await sdk.getAttribution();
      expect(attribution.state, AttributionState.attributed);
      expect(attribution.linkId, linkId);
      // The deferred link is delivered once per install.
      expect(await sdk.getInitialLink(), isNull);
      await device.api.waitFor(SdkPaths.init, 1);
      final init = device.api.to(SdkPaths.init).single.json;
      expect(init['install_id'], installId);
      expect(init.keys, containsAll(<String>['user_id', 'context']));
      expect(device.api.to(SdkPaths.firstOpen), hasLength(1));
    });

    test('a new session starts after 30 minutes in the background', () async {
      final device = newDevice();
      await device.launchRegistered();
      await device.api.waitFor(SdkPaths.init, 1);

      await setAppLifecycle(AppLifecycleState.paused);
      device.clock.advance(const Duration(minutes: 10));
      await setAppLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.api.to(SdkPaths.init), hasLength(1));

      await setAppLifecycle(AppLifecycleState.paused);
      device.clock.advance(const Duration(minutes: 31));
      await setAppLifecycle(AppLifecycleState.resumed);
      await device.api.waitFor(SdkPaths.init, 2);
    });
  });

  test(
      'a headless engine reads no launch link and sends nothing until the '
      'app is visible', () async {
    await setAppLifecycle(AppLifecycleState.paused);
    final device = newDevice();
    final sdk = await device.launch(
      firstOpenTimeout: const Duration(milliseconds: 100),
      setUpPlatform: (platform) => platform.initialLink = PlatformLink(
        url: testLinkUrl,
        receivedAt: device.clock.now(),
      ),
    );

    expect(await sdk.getInitialLink(), isNull);
    expect(
      (await sdk.getAttribution()).state,
      AttributionState.unavailable,
    );
    expect(device.platform.initialLinkCalls, 0);
    expect(device.api.requests, isEmpty);

    // The app comes to the foreground after all: the launch link still
    // reaches onLink, and the install is registered.
    final link = sdk.onLink.first;
    await setAppLifecycle(AppLifecycleState.resumed);

    expect((await link).url.toString(), testLinkUrl);
    await device.api.waitFor(SdkPaths.firstOpen, 1);
  });
}
