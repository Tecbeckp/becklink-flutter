// The direct-link flow on a real device or emulator, with the plugin's
// Kotlin or Swift layer registered. Run from example/:
//
//   flutter test integration_test/direct_link_test.dart
//
// What it checks, and where it has to stop:
//
// - configure() returns at once: storage, native calls and the network run
//   in the background (§29; the 20 ms budget applies to release builds, this
//   debug run only checks that nothing waits for them).
// - A link the native link channel delivers reaches onLink. A test cannot
//   make the operating system open an App Link or Universal Link, so the
//   test hands the framework the message the native layer would send on
//   `app.becklink.flutter/links` (doc/platform-channel.md, "Link payload").
//   The key is well-formed but unknown and the SDK only talks to the
//   production API over HTTPS (no mock server can stand in for it on a
//   device), so the service refuses the key, or cannot be reached offline,
//   and the app gets the event the SDK builds on the device (contract
//   section 7.3 "Offline": the link's own path, no data, no link ID).
// - The example app routes a link with deep-link path /product/123 to the
//   product screen. That path only comes from the service's answer, so the
//   event is handed to ExampleApp through its `links` stream.

import 'dart:async';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter_example/src/app.dart';
import 'package:becklink_flutter_example/src/demo_state.dart';
import 'package:becklink_flutter_example/src/sdk_log_buffer.dart';
import 'package:becklink_flutter_example/src/sdk_setup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Well-formed, but no project has it.
const String _unknownTestKey = 'pk_test_integration0000000000';

/// The event channel of links received while the app runs.
const String _linkChannel = 'app.becklink.flutter/links';

const String _linkHost = 'example-test.becklinks.com';

/// Sends the link payload the native layer sends for one URL delivery.
Future<void> _deliverFromNative(
  WidgetTester tester,
  String url,
  DateTime receivedAt,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _linkChannel,
    const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
      'url': url,
      'received_at_ms': receivedAt.millisecondsSinceEpoch,
    }),
    (_) {},
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('configure() returns at once and onLink delivers a link the '
      'native layer hands over, once', (tester) async {
    final watch = Stopwatch()..start();
    await BeckLink.instance.configure(
      apiKey: _unknownTestKey,
      firstOpenTimeout: const Duration(seconds: 1),
    );
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 250)));

    // flush() waits until storage is open, which is when the SDK starts
    // listening to the native link channel.
    await BeckLink.instance.flush();

    const url = 'https://$_linkHost/abc123?ref=integration';
    final receivedAt = DateTime.now().toUtc();
    final first = BeckLink.instance.onLink.first.timeout(
      const Duration(seconds: 30),
    );
    await _deliverFromNative(tester, url, receivedAt);
    final event = await first;

    expect(event.url, Uri.parse(url));
    expect(event.path, '/abc123');
    expect(event.params, <String, String>{'ref': 'integration'});
    expect(event.isDeferred, isFalse);
    expect(event.linkId, isNull, reason: 'built on the device');
    expect(
      event.clickedAt.millisecondsSinceEpoch,
      receivedAt.millisecondsSinceEpoch,
    );

    // The same delivery reported again is dropped; the next link arrives.
    final next = BeckLink.instance.onLink.first.timeout(
      const Duration(seconds: 30),
    );
    await _deliverFromNative(tester, url, receivedAt);
    await _deliverFromNative(
      tester,
      'https://$_linkHost/sentinel',
      receivedAt.add(const Duration(seconds: 1)),
    );
    expect((await next).path, '/sentinel');
  });

  testWidgets('the example app routes /product/123 to the product screen and '
      'keeps unknown paths on the home screen', (tester) async {
    final links = StreamController<LinkEvent>();
    final demo = DemoState(
      setup: const SdkConfigured(environment: 'test'),
      logs: SdkLogBuffer(),
      initialLogLevel: LogLevel.error,
    );
    await tester.pumpWidget(ExampleApp(demo: demo, links: links.stream));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Beck Link example'), findsOneWidget);

    LinkEvent linkTo(String path) => LinkEvent(
      url: Uri.parse('https://$_linkHost/abc123'),
      path: path,
      isDeferred: false,
      matchMethod: MatchMethod.appLink,
      confidence: Confidence.certain,
      clickedAt: DateTime.now(),
      linkId: '01K6ZQ3M8X4T2V9B7C5D1E0FGH',
      data: const <String, Object?>{'coupon': 'SUMMER10'},
    );

    links.add(linkTo('/product/123'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Product 123'), findsOneWidget);
    expect(find.text('Opened from a link'), findsOneWidget);

    // The Debug screen is never reachable from a link.
    links.add(linkTo('/debug'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Beck Link example'), findsOneWidget);
    expect(
      find.textContaining('a page this app does not have'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    demo.dispose();
    await links.close();
  });
}
