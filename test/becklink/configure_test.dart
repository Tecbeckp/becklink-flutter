import 'dart:async';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_sdk_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/sdk_harness.dart';
import '../helpers/test_support.dart';

final Matcher _notConfigured = throwsA(
  isA<BeckLinkException>()
      .having((e) => e.code, 'code', BeckLinkErrorCode.notConfigured),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => setAppLifecycle(AppLifecycleState.resumed));

  test('every method but the two streams needs configure() first', () async {
    final device = newDevice();
    final sdk = await device.start();

    expect(sdk.onLink, isA<Stream<LinkEvent>>());
    expect(sdk.onAttribution, isA<Stream<Attribution>>());
    await expectLater(sdk.getInitialLink(), _notConfigured);
    await expectLater(sdk.getAttribution(), _notConfigured);
    await expectLater(sdk.track('purchase'), _notConfigured);
    await expectLater(sdk.setUserId('user_8841'), _notConfigured);
    await expectLater(sdk.clearUserId(), _notConfigured);
    await expectLater(
      sdk.createLink(LinkOptions(deepLinkPath: '/referral')),
      _notConfigured,
    );
    await expectLater(sdk.setTrackingEnabled(false), _notConfigured);
    await expectLater(sdk.flush(), _notConfigured);
    await expectLater(sdk.debugResetInstall(), _notConfigured);
    expect(() => sdk.setLogLevel(LogLevel.info), _notConfigured);
    expect(device.api.requests, isEmpty);
  });

  test('a secret key is refused before anything is sent', () async {
    final device = newDevice();
    final sdk = await device.start();

    await expectLater(
      sdk.configure(apiKey: 'sk_live_SuperSecret1234567890'),
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
    );
    await settle();

    await expectLater(sdk.getInitialLink(), _notConfigured);
    expect(device.api.requests, isEmpty);
    expect(device.platform.initialLinkCalls, 0);
    expect(device.logs.text, isNot(contains('SuperSecret')));
  });

  test('a malformed key and an out-of-range timeout are refused', () async {
    final device = newDevice();
    final sdk = await device.start();

    await expectLater(
      sdk.configure(apiKey: 'pk_prod_0123456789abcdef'),
      throwsA(
        isA<BeckLinkException>()
            .having((e) => e.code, 'code', BeckLinkErrorCode.invalidKey),
      ),
    );
    await expectLater(
      sdk.configure(
        apiKey: testKey,
        firstOpenTimeout: const Duration(seconds: 31),
      ),
      throwsArgumentError,
    );
    await expectLater(sdk.flush(), _notConfigured);
  });

  test('configure() returns before the native layer or the service answered',
      () async {
    final device = newDevice();
    final storage = Completer<void>();
    final sdk = await device.start(
      setUpPlatform: (platform) => platform.storageGate = storage,
    );

    await sdk.configure(apiKey: testKey);

    expect(device.platform.initialLinkCalls, 0);
    expect(device.api.requests, isEmpty);
    storage.complete();
    expect((await sdk.getAttribution()).state, AttributionState.organic);
    expect(device.api.to(SdkPaths.firstOpen), hasLength(1));
  });

  test(
      'configure() again with the same arguments changes nothing; a new key '
      'is used from then on', () async {
    final device = newDevice();
    device.api.enqueue(
      SdkPaths.firstOpen,
      (_) => Completer<http.Response>().future,
    );
    final sdk = await device.launch();
    await device.api.waitFor(SdkPaths.firstOpen, 1);

    await sdk.configure(
      apiKey: testKey,
      logLevel: LogLevel.debug,
      firstOpenTimeout: const Duration(seconds: 5),
    );
    expect(device.logs.text, isNot(contains('Configuration updated')));

    await sdk.configure(
      apiKey: otherTestKey,
      logLevel: LogLevel.debug,
      firstOpenTimeout: const Duration(seconds: 5),
    );
    await device.api.waitFor(SdkPaths.firstOpen, 2);

    final requests = device.api.to(SdkPaths.firstOpen);
    expect(requests.first.headers['authorization'], 'Bearer $testKey');
    expect(requests.last.headers['authorization'], 'Bearer $otherTestKey');
    // The first open moved to the new key with the same IDs.
    expect(
      requests.last.json['first_open_id'],
      requests.first.json['first_open_id'],
    );
    expect((await sdk.getAttribution()).state, AttributionState.organic);
  });

  test('a failed configure() keeps the earlier configuration', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.getAttribution();

    await expectLater(
      sdk.configure(apiKey: 'not-a-key'),
      throwsA(isA<BeckLinkException>()),
    );
    await sdk.createLink(LinkOptions(deepLinkPath: '/referral'));

    expect(
      device.api.to(SdkPaths.links).single.headers['authorization'],
      'Bearer $testKey',
    );
  });

  test('the log never contains the API key or the user ID', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.getAttribution();

    await sdk.setUserId('user_8841');
    await sdk.track('purchase', properties: <String, Object?>{'sku': 'A1'});
    await sdk.flush();
    await sdk.createLink(LinkOptions(deepLinkPath: '/referral'));

    expect(device.logs.lines, isNotEmpty);
    expect(device.logs.text, isNot(contains(testKey.substring(8))));
    expect(device.logs.text, isNot(contains('user_8841')));
  });

  test('setLogLevel changes what the SDK logs', () async {
    final device = newDevice();
    final sdk = await device.launch();
    await sdk.getAttribution();

    sdk.setLogLevel(LogLevel.none);
    final before = device.logs.lines.length;
    await sdk.track('purchase');
    await sdk.flush();

    expect(device.logs.lines, hasLength(before));
  });

  test('on a desktop platform the SDK resolves no links and sends no data',
      () async {
    final device = newDevice(TargetPlatform.linux);
    final sdk = await device.launch(
      setUpPlatform: (platform) => platform.initialLink = PlatformLink(
        url: testLinkUrl,
        receivedAt: device.clock.now(),
      ),
    );

    final link = await sdk.getInitialLink();

    expect(link, isNotNull, reason: 'built on the device');
    expect(link!.linkId, isNull);
    expect(device.api.requests, isEmpty);
    expect(
      device.logs.at(LogLevel.error),
      contains(contains('supports Android and iOS')),
    );
  });
}
