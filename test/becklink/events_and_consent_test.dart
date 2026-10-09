import 'dart:async';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/sdk_harness.dart';
import '../helpers/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => setAppLifecycle(AppLifecycleState.resumed));

  group('track', () {
    test('checks its arguments', () async {
      final device = newDevice();
      final sdk = await device.launch();

      await expectLater(sdk.track('Add To Cart'), throwsArgumentError);
      await expectLater(
        sdk.track('purchase', revenue: 9.99),
        throwsArgumentError,
      );
      await expectLater(
        sdk.track(
          'purchase',
          properties: <String, Object?>{
            'cart': <String, Object?>{'items': 2},
          },
        ),
        throwsArgumentError,
      );
      await expectLater(sdk.setUserId(''), throwsArgumentError);
    });

    test('queues the event and flush() sends it with the user ID', () async {
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();
      final installId =
          device.api.to(SdkPaths.firstOpen).single.json['install_id'];

      await sdk.setUserId('user_8841');
      await sdk.track(
        'purchase',
        properties: <String, Object?>{'sku': 'A1', 'note': null},
        revenue: 9.99,
        currency: 'usd',
      );
      await sdk.clearUserId();
      await sdk.track('app_review');
      await sdk.flush();

      final body = device.api.to(SdkPaths.events).single.json;
      expect(body['install_id'], installId);
      expect(body.obj('context')['platform'], 'android');
      final events = body.objects('events');
      expect(events, hasLength(2));
      expect(events.first, <String, Object?>{
        'event_id': events.first['event_id'],
        'name': 'purchase',
        'timestamp': '2026-10-07T12:00:00.000Z',
        'properties': <String, Object?>{'sku': 'A1'},
        'revenue': 9.99,
        'currency': 'USD',
        'user_id': 'user_8841',
      });
      expect(events.first['event_id'], isLowercaseUuid);
      expect(events.last['user_id'], isNull);
    });

    test('waits for the first open before sending events', () async {
      final device = newDevice();
      final answer = Completer<void>();
      device.api.respond(SdkPaths.firstOpen, (_) async {
        await answer.future;
        return jsonResponse(organicAnswerJson());
      });
      final sdk = await device.launch(
        firstOpenTimeout: const Duration(milliseconds: 50),
      );
      await sdk.getInitialLink();

      await sdk.track('tutorial_done');
      await sdk.flush();
      expect(device.api.to(SdkPaths.events), isEmpty);

      answer.complete();
      await device.api.waitFor(SdkPaths.events, 1);
    });

    test('20 queued events are sent without flush()', () async {
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 20; i++) sdk.track('level_$i'),
      ]);
      await device.api.waitFor(SdkPaths.events, 1);

      expect(
        device.api.to(SdkPaths.events).single.json.list('events'),
        hasLength(20),
      );
    });

    test('queued events are sent when the app goes to the background',
        () async {
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();
      await sdk.track('checkout_started');

      await setAppLifecycle(AppLifecycleState.paused);
      await device.api.waitFor(SdkPaths.events, 1);
    });

    test('events survive a restart and are sent by the next process', () async {
      final device = newDevice();
      final first = await device.launch();
      await first.getAttribution();
      device.api.respond(
        SdkPaths.events,
        (_) => problemResponse(
          503,
          'service_unavailable',
          headers: <String, String>{'retry-after': '3600'},
        ),
      );
      await first.track('purchase');
      await first.flush();
      expect(device.api.to(SdkPaths.events), hasLength(1));

      device.api.respond(
        SdkPaths.events,
        (_) => jsonResponse(eventsReceiptJson(accepted: 1), status: 202),
      );
      final sdk = await device.launch();
      await sdk.getAttribution();
      await sdk.flush();

      final requests = device.api.to(SdkPaths.events);
      expect(requests, hasLength(2));
      expect(
        requests.last.json.objects('events').single['event_id'],
        requests.first.json.objects('events').single['event_id'],
      );
    });
  });

  group('tracking consent', () {
    test('turning tracking off deletes the queue and the install identity',
        () async {
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();
      final installId =
          device.api.to(SdkPaths.firstOpen).single.json['install_id'];
      await sdk.track('purchase');
      await sdk.track('app_review');
      final attributions = <Attribution>[];
      final subscription = sdk.onAttribution.listen(attributions.add);

      await sdk.setTrackingEnabled(false);

      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      await eventually(
        () => attributions.any(
          (attribution) => attribution.state == AttributionState.unavailable,
        ),
      );
      // track() drops events silently while tracking is off.
      await sdk.track('dropped');
      await sdk.flush();
      expect(device.api.to(SdkPaths.events), isEmpty);
      // The Keychain copy is replaced, so the old ID cannot come back.
      await eventually(() => device.platform.savedSeeds.length == 2);
      expect(device.platform.savedSeeds.last, isLowercaseUuid);
      expect(device.platform.savedSeeds.last, isNot(installId));

      await subscription.cancel();
      await device.stop();
      final state = await device.storedState();
      expect(state.identity, isNull);
      expect(state.trackingEnabled, isFalse);
      final queue = await device.storedQueue();
      expect(queue.length, 0);
      await queue.close();
    });

    test('links still resolve without identifiers; on again is a new install',
        () async {
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();
      final firstInstall = device.api.to(SdkPaths.firstOpen).single.json;
      await sdk.setTrackingEnabled(false);

      final next = sdk.onLink.first;
      device.platform.deliverLink(
        PlatformLink(url: testLinkUrl, receivedAt: device.clock.now()),
      );
      expect((await next).linkId, linkId);
      final open = device.api.to(SdkPaths.open).single.json;
      expect(open['tracking_enabled'], isFalse);
      expect(open.keys, isNot(contains('install_id')));
      expect(open.keys, isNot(contains('user_id')));

      await sdk.setTrackingEnabled(true);
      await device.api.waitFor(SdkPaths.firstOpen, 2);

      final secondInstall = device.api.to(SdkPaths.firstOpen).last.json;
      expect(secondInstall['install_id'], isNot(firstInstall['install_id']));
      expect(
        secondInstall['first_open_id'],
        isNot(firstInstall['first_open_id']),
      );
    });

    test('turned off right after configure(), nothing identifies the install',
        () async {
      final device = newDevice();
      final storage = Completer<void>();
      final sdk = await device.launch(
        setUpPlatform: (platform) {
          platform
            ..storageGate = storage
            ..initialLink = PlatformLink(
              url: testLinkUrl,
              receivedAt: device.clock.now(),
            );
        },
      );

      final turnedOff = sdk.setTrackingEnabled(false);
      storage.complete();
      await turnedOff;
      final link = await sdk.getInitialLink();

      expect(link?.linkId, linkId);
      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      expect(device.api.to(SdkPaths.firstOpen), isEmpty);
      expect(device.api.to(SdkPaths.init), isEmpty);
      expect(device.platform.savedSeeds, isEmpty);
      final open = device.api.to(SdkPaths.open).single.json;
      expect(open['tracking_enabled'], isFalse);
      expect(open.keys, isNot(contains('install_id')));
    });

    test('the choice is kept across restarts', () async {
      final device = newDevice();
      final first = await device.launch();
      await first.getAttribution();
      await first.setTrackingEnabled(false);

      final sdk = await device.launch();

      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      expect(device.api.to(SdkPaths.firstOpen), hasLength(1));
      expect(device.api.to(SdkPaths.init), isEmpty);
    });
  });

  group('debugResetInstall', () {
    test('forgets the install so the next launch is a new install', () async {
      // Tests run in debug mode; profile and release builds throw an
      // UnsupportedError instead, which kDebugMode decides at compile time.
      expect(kDebugMode, isTrue);
      final device = newDevice();
      final sdk = await device.launch();
      await sdk.getAttribution();
      final first = device.api.to(SdkPaths.firstOpen).single.json;
      await sdk.setUserId('user_8841');
      await sdk.track('purchase');

      await sdk.debugResetInstall();

      expect(
        (await sdk.getAttribution()).state,
        AttributionState.unavailable,
      );
      expect(device.platform.savedSeeds.last, isLowercaseUuid);
      expect(device.platform.savedSeeds.last, isNot(first['install_id']));
      await sdk.flush();
      expect(device.api.to(SdkPaths.events), isEmpty);

      await device.stop();
      final state = await device.storedState();
      expect(state.identity, isNull);
      expect(state.userId, isNull);
      expect(state.trackingEnabled, isNull);
      expect(state.remoteConfig, isNull);

      final next = await device.launch();
      await next.getAttribution();
      final second = device.api.to(SdkPaths.firstOpen).last.json;
      expect(second['install_id'], isNot(first['install_id']));
      expect(second['first_open_id'], isNot(first['first_open_id']));
    });
  });
}
