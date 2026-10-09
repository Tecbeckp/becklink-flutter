import 'package:becklink_flutter/becklink_flutter.dart';
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
  final t3 = t1.add(const Duration(seconds: 2));

  PlatformLink linkTo(String path, DateTime receivedAt) =>
      PlatformLink(url: 'https://$testHost$path', receivedAt: receivedAt);

  test('a launch link on a later launch is resolved through /v1/sdk/open',
      () async {
    final device = newDevice();
    final sdk = await device.launchRegistered(
      setUpPlatform: (platform) =>
          platform.initialLink = PlatformLink(url: testLinkUrl, receivedAt: t1),
    );
    final installId =
        device.api.to(SdkPaths.firstOpen).single.json['install_id'];

    final link = await sdk.getInitialLink();

    expect(link, isNotNull);
    expect(link!.isDeferred, isFalse);
    expect(link.linkId, linkId);
    expect(link.path, '/product/123');
    expect(link.data, <String, Object?>{'coupon': 'SUMMER10', 'color': 'blue'});
    final request = device.api.to(SdkPaths.open).single;
    expect(request.headers['idempotency-key'], isLowercaseUuid);
    expect(request.json['url'], testLinkUrl);
    expect(request.json['opened_at'], '2026-10-07T11:59:58.125Z');
    expect(request.json['tracking_enabled'], isTrue);
    expect(request.json['install_id'], installId);
    expect(request.json.obj('context')['platform'], 'android');
    expect(await sdk.onLink.first, link);
  });

  test(
      'links received while the app runs wait for the first listener, in '
      'order', () async {
    final device = newDevice();
    final sdk = await device.launchRegistered();
    expect(await sdk.getInitialLink(), isNull);

    device.platform
      ..deliverLink(linkTo('/first', t1))
      ..deliverLink(linkTo('/second', t2));
    await device.api.waitFor(SdkPaths.open, 2);
    await settle();
    final links = await sdk.onLink.take(2).toList();

    expect(
      links.map((link) => link.url.toString()),
      <String>['https://$testHost/first', 'https://$testHost/second'],
    );
  });

  test('onLink may be listened to before configure()', () async {
    final device = newDevice();
    device.api.respond(
      SdkPaths.firstOpen,
      (_) => jsonResponse(installReferrerAnswerJson()),
    );
    final sdk = await device.start();
    final received = <LinkEvent>[];
    final subscription = sdk.onLink.listen(received.add);

    await sdk.configure(apiKey: testKey);
    await sdk.getInitialLink();
    await eventually(() => received.isNotEmpty);

    expect(received.single.isDeferred, isTrue);
    await subscription.cancel();
  });

  test('each delivery reaches the app once; the same link opened again does',
      () async {
    final device = newDevice();
    final sdk = await device.launchRegistered();
    await sdk.getInitialLink();
    final received = <LinkEvent>[];
    final subscription = sdk.onLink.listen(received.add);

    final delivery = linkTo('/summer24', t1);
    device.platform
      ..deliverLink(delivery)
      // The platform reports the same delivery again.
      ..deliverLink(delivery)
      // The user opens the same link a second time.
      ..deliverLink(linkTo('/summer24', t2))
      ..deliverLink(linkTo('/sentinel', t3));
    await eventually(
      () => received.any((link) => link.url.path == '/sentinel'),
    );

    expect(
      received.map((link) => link.url.path),
      <String>['/summer24', '/summer24', '/sentinel'],
    );
    expect(device.api.to(SdkPaths.open), hasLength(3));
    await subscription.cancel();
  });

  test('a delivery reported again after a restart is ignored', () async {
    final device = newDevice();
    final launch = PlatformLink(url: testLinkUrl, receivedAt: t1);
    final first = await device.launchRegistered(
      setUpPlatform: (platform) => platform.initialLink = launch,
    );
    expect(await first.getInitialLink(), isNotNull);

    final sdk = await device.launch(
      setUpPlatform: (platform) => platform.initialLink = launch,
    );

    expect(await sdk.getInitialLink(), isNull);
    expect(device.api.to(SdkPaths.open), hasLength(1));
    expect(device.logs.text, contains('reported twice'));
  });

  test('a link the service does not know is not delivered', () async {
    final device = newDevice();
    device.api.enqueue(
      SdkPaths.open,
      (_) => problemResponse(404, 'link_not_found'),
    );
    final sdk = await device.launchRegistered();
    await sdk.getInitialLink();
    final received = <LinkEvent>[];
    final subscription = sdk.onLink.listen(received.add);

    device.platform
      ..deliverLink(linkTo('/expired', t1))
      ..deliverLink(linkTo('/sentinel', t2));
    await eventually(() => received.isNotEmpty);
    await settle();

    expect(received.single.url.path, '/sentinel');
    expect(device.api.to(SdkPaths.open), hasLength(2));
    await subscription.cancel();
  });

  test('offline, the app gets the link built on the device', () async {
    final device = newDevice();
    device.api.respond(SdkPaths.open, offline);
    final sdk = await device.launchRegistered();
    await sdk.getInitialLink();

    final next = sdk.onLink.first;
    device.platform.deliverLink(PlatformLink(url: testLinkUrl, receivedAt: t1));
    final link = await next;

    expect(link.url, Uri.parse(testLinkUrl));
    expect(link.path, '/summer24');
    expect(link.params, <String, String>{'ref': 'newsletter'});
    expect(link.data, isEmpty);
    expect(link.linkId, isNull);
    expect(link.campaign, isNull);
    expect(link.matchMethod, MatchMethod.appLink);
    expect(link.clickedAt, t1);
  });

  test(
      'other URLs never leave the device; a link of the other environment '
      'is explained in the log', () async {
    final device = newDevice();
    final sdk = await device.launchRegistered();
    await sdk.getInitialLink();
    final received = <LinkEvent>[];
    final subscription = sdk.onLink.listen(received.add);

    device.platform
      ..deliverLink(
        PlatformLink(
          url: 'myapp://oauth/callback?code=secret-token',
          receivedAt: t1,
        ),
      )
      ..deliverLink(
        PlatformLink(url: 'https://$liveHost/summer24', receivedAt: t2),
      )
      ..deliverLink(linkTo('/sentinel', t3));
    await eventually(() => received.isNotEmpty);
    await settle();

    expect(received.single.url.path, '/sentinel');
    expect(device.api.to(SdkPaths.open), hasLength(1));
    expect(device.logs.text, isNot(contains('secret-token')));
    expect(
      device.logs.at(LogLevel.error),
      contains(contains('live environment')),
    );
    await subscription.cancel();
  });

  test('the "Open in app" custom-scheme URL is resolved like its link',
      () async {
    final device = newDevice();
    final sdk = await device.launchRegistered();
    await sdk.getInitialLink();
    final received = 'myapp://becklink?url=${Uri.encodeComponent(testLinkUrl)}';

    final next = sdk.onLink.first;
    device.platform.deliverLink(PlatformLink(url: received, receivedAt: t1));
    await next;

    expect(device.api.to(SdkPaths.open).single.json['url'], received);
  });
}
