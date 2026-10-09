import 'dart:async';

import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:becklink_flutter/src/platform/device_context.dart';
import 'package:becklink_flutter/src/platform/install_id_seed_result.dart';
import 'package:becklink_flutter/src/platform/install_referrer_result.dart';
import 'package:becklink_flutter/src/platform/method_channel_becklink_platform.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_support.dart';

const MethodChannel _methods = MethodChannel(methodChannelName);
const MethodChannel _linkControl = MethodChannel(linkChannelName);
const StandardMethodCodec _codec = StandardMethodCodec();

/// The native side of the method channel: answers by method name and
/// records every call. An answer may be a value, a [PlatformException] to
/// throw, or [_never] for a call that never completes. Methods without an
/// answer are not implemented.
final class _Native {
  _Native(this.answers);

  final Map<String, Object?> answers;
  final List<MethodCall> calls = <MethodCall>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (!answers.containsKey(call.method)) {
      throw MissingPluginException('No implementation for ${call.method}');
    }
    final answer = answers[call.method];
    if (answer is PlatformException) throw answer;
    if (identical(answer, _never)) return Completer<Object?>().future;
    return answer;
  }
}

final Object _never = Object();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late LogCapture logs;
  late MethodChannelBeckLinkPlatform platform;
  final fallbackNow = DateTime.utc(2026, 10, 7, 12);

  setUp(() {
    logs = LogCapture();
    platform = MethodChannelBeckLinkPlatform(
      logger: SdkLogger(level: LogLevel.debug, sink: logs.add),
      timeouts: const PlatformTimeouts(
        lookup: Duration(milliseconds: 50),
        installReferrer: Duration(milliseconds: 50),
        pasteboard: Duration(milliseconds: 50),
      ),
      now: () => fallbackNow,
    );
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(_methods, null)
      ..setMockMethodCallHandler(_linkControl, null);
  });

  _Native native(Map<String, Object?> answers) {
    final fake = _Native(answers);
    messenger.setMockMethodCallHandler(_methods, fake.handle);
    return fake;
  }

  group('getInitialLink', () {
    test('reads the link payload with its native receive time', () async {
      native(<String, Object?>{
        'getInitialLink': <String, Object?>{
          'url': testLinkUrl,
          'received_at_ms': 1791374400000,
        },
      });

      final link = await platform.getInitialLink();

      expect(link, isNotNull);
      expect(link!.url, testLinkUrl);
      expect(
        link.receivedAt,
        DateTime.fromMillisecondsSinceEpoch(1791374400000, isUtc: true),
      );
    });

    test('uses the Dart clock when the receive time is missing', () async {
      native(<String, Object?>{
        'getInitialLink': <String, Object?>{'url': testLinkUrl},
      });

      expect((await platform.getInitialLink())!.receivedAt, fallbackNow);
    });

    test('is null for no link, a malformed answer or no plugin', () async {
      native(<String, Object?>{'getInitialLink': null});
      expect(await platform.getInitialLink(), isNull);

      native(<String, Object?>{'getInitialLink': 'https://not.a.map'});
      expect(await platform.getInitialLink(), isNull);
      expect(logs.at(LogLevel.error).last, contains('getInitialLink'));

      messenger.setMockMethodCallHandler(_methods, null);
      expect(await platform.getInitialLink(), isNull);
    });

    test('refuses an empty or over-long URL', () async {
      native(<String, Object?>{
        'getInitialLink': <String, Object?>{
          'url': 'https://$testHost/${'a' * maxPlatformUrlLength}',
          'received_at_ms': 1,
        },
      });

      expect(await platform.getInitialLink(), isNull);
    });
  });

  group('fallbacks', () {
    test('a missing plugin is logged once and every call falls back', () async {
      // No handler: the channel answers MissingPluginException.
      expect(await platform.getStorageDirectory(), isNull);
      expect(await platform.getInstallIdSeed(), const InstallIdSeedAbsent());
      expect(await platform.saveInstallIdSeed(_seed), isFalse);
      expect(
        await platform.getInstallReferrer(),
        const InstallReferrerUnavailable(InstallReferrerFailure.notApplicable),
      );
      expect(
        await platform.readPasteboardUrl(
          allowedHosts: <String>['*.becklinks.com'],
        ),
        isNull,
      );
      expect(await platform.getDeviceContext(), DeviceContext.unknown);

      expect(logs.at(LogLevel.error), hasLength(1));
      expect(logs.at(LogLevel.error).single, contains('not registered'));
    });

    test('a native error falls back and logs only its code', () async {
      native(<String, Object?>{
        'getInstallIdSeed': PlatformException(
          code: 'keychain_unavailable',
          message: 'OSStatus -25308 for 3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10',
        ),
        'getInstallReferrer': PlatformException(code: 'boom'),
        'getStorageDirectory': PlatformException(code: 'storage_unavailable'),
      });

      expect(
        await platform.getInstallIdSeed(),
        const InstallIdSeedUnavailable(),
      );
      expect(
        await platform.getInstallReferrer(),
        const InstallReferrerUnavailable(InstallReferrerFailure.platformError),
      );
      expect(await platform.getStorageDirectory(), isNull);
      expect(logs.text, contains('keychain_unavailable'));
      expect(logs.text, isNot(contains('3f6c1b9e')));
    });

    test('a call without an answer ends at its deadline', () async {
      native(<String, Object?>{
        'getInitialLink': _never,
        'getInstallIdSeed': _never,
        'getInstallReferrer': _never,
        'readPasteboardUrl': _never,
        'getDeviceContext': _never,
      });

      expect(await platform.getInitialLink(), isNull);
      expect(
        await platform.getInstallIdSeed(),
        const InstallIdSeedUnavailable(),
      );
      final referrer = await platform.getInstallReferrer();
      expect(
        referrer,
        const InstallReferrerUnavailable(InstallReferrerFailure.timeout),
      );
      expect(
        (referrer as InstallReferrerUnavailable).reason.isRetryable,
        isTrue,
      );
      expect(
        await platform.readPasteboardUrl(
          allowedHosts: <String>['*.becklinks.com'],
        ),
        isNull,
      );
      expect(await platform.getDeviceContext(), DeviceContext.unknown);
      expect(logs.at(LogLevel.error), everyElement(contains('no answer')));
    });
  });

  group('storage directory', () {
    test('accepts an absolute path only', () async {
      native(<String, Object?>{
        'getStorageDirectory': '/data/user/0/app/no_backup/becklink',
      });
      expect(
        await platform.getStorageDirectory(),
        '/data/user/0/app/no_backup/becklink',
      );

      native(<String, Object?>{'getStorageDirectory': 'relative/becklink'});
      expect(await platform.getStorageDirectory(), isNull);
    });
  });

  group('install ID seed', () {
    test('maps the three Keychain outcomes', () async {
      native(<String, Object?>{'getInstallIdSeed': _seed});
      expect(
        await platform.getInstallIdSeed(),
        const InstallIdSeedFound(_seed),
      );

      native(<String, Object?>{'getInstallIdSeed': null});
      expect(await platform.getInstallIdSeed(), const InstallIdSeedAbsent());

      native(<String, Object?>{'getInstallIdSeed': 42});
      expect(
        await platform.getInstallIdSeed(),
        const InstallIdSeedUnavailable(),
      );
    });

    test('saves a normalized UUID and reports whether it was stored', () async {
      final fake = native(<String, Object?>{'saveInstallIdSeed': true});

      expect(await platform.saveInstallIdSeed(_seed.toUpperCase()), isTrue);
      expect(fake.calls.single.arguments, <String, Object?>{
        'install_id': _seed,
      });

      native(<String, Object?>{'saveInstallIdSeed': 'yes'});
      expect(await platform.saveInstallIdSeed(_seed), isFalse);
    });

    test(
        'refuses a value that is not a UUID before calling, without '
        'echoing it', () async {
      final fake = native(<String, Object?>{'saveInstallIdSeed': true});

      await expectLater(
        platform.saveInstallIdSeed('user@example.com'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'description',
            isNot(contains('user@example.com')),
          ),
        ),
      );
      expect(fake.calls, isEmpty);
    });
  });

  group('install referrer', () {
    test('reads a referrer with Play timestamps (0 is unknown)', () async {
      native(<String, Object?>{
        'getInstallReferrer': <String, Object?>{
          'status': 'ok',
          'raw_referrer': installReferrer,
          'click_timestamp_seconds': 1791374400,
          'install_begin_timestamp_seconds': 0,
        },
      });

      expect(
        await platform.getInstallReferrer(),
        InstallReferrerFound(
          rawReferrer: installReferrer,
          clickedAt: DateTime.fromMillisecondsSinceEpoch(
            1791374400000,
            isUtc: true,
          ),
        ),
      );
    });

    final statuses = <String, (InstallReferrerFailure, bool)>{
      'service_unavailable': (InstallReferrerFailure.serviceUnavailable, true),
      'feature_not_supported': (
        InstallReferrerFailure.featureNotSupported,
        false,
      ),
      'developer_error': (InstallReferrerFailure.developerError, false),
      'permission_error': (InstallReferrerFailure.permissionError, false),
    };
    for (final entry in statuses.entries) {
      test('maps status ${entry.key}', () async {
        native(<String, Object?>{
          'getInstallReferrer': <String, Object?>{'status': entry.key},
        });

        final result = await platform.getInstallReferrer();

        expect(result, InstallReferrerUnavailable(entry.value.$1));
        expect(
          (result as InstallReferrerUnavailable).reason.isRetryable,
          entry.value.$2,
        );
      });
    }

    test('treats null (iOS) as not applicable and unknown answers as errors',
        () async {
      native(<String, Object?>{'getInstallReferrer': null});
      expect(
        await platform.getInstallReferrer(),
        const InstallReferrerUnavailable(InstallReferrerFailure.notApplicable),
      );

      native(<String, Object?>{
        'getInstallReferrer': <String, Object?>{'status': 'teleported'},
      });
      expect(
        await platform.getInstallReferrer(),
        const InstallReferrerUnavailable(InstallReferrerFailure.platformError),
      );

      native(<String, Object?>{
        'getInstallReferrer': <String, Object?>{'status': 'ok'},
      });
      expect(
        await platform.getInstallReferrer(),
        const InstallReferrerUnavailable(InstallReferrerFailure.platformError),
      );
    });

    test('never puts the referrer into toString', () {
      expect(
        InstallReferrerFound(rawReferrer: installReferrer).toString(),
        isNot(contains(clickId)),
      );
    });
  });

  group('pasteboard', () {
    test('passes the host patterns and returns a click URL', () async {
      final fake = native(<String, Object?>{
        'readPasteboardUrl': pasteboardClickUrl,
      });

      final url = await platform.readPasteboardUrl(
        allowedHosts: <String>['*.becklinks.com', 'go.acme.com'],
      );

      expect(url, pasteboardClickUrl);
      expect(fake.calls.single.arguments, <String, Object?>{
        'allowed_hosts': <String>['*.becklinks.com', 'go.acme.com'],
      });
    });

    test('discards native text that is not a click URL, without logging it',
        () async {
      native(<String, Object?>{
        'readPasteboardUrl': 'https://evil.example.com/_c/$clickId',
      });

      expect(
        await platform.readPasteboardUrl(
          allowedHosts: <String>['*.becklinks.com'],
        ),
        isNull,
      );
      expect(logs.at(LogLevel.error).single, contains('discarded'));
      expect(logs.text, isNot(contains('evil.example.com')));
    });

    test('refuses host patterns that are not hosts, before calling', () async {
      final fake = native(<String, Object?>{'readPasteboardUrl': null});

      for (final hosts in <List<String>>[
        <String>[],
        <String>['*.app'],
        <String>['Acme.com'],
        <String>['*.*.becklinks.com'],
        List<String>.generate(101, (i) => 'h$i.example.com'),
      ]) {
        await expectLater(
          platform.readPasteboardUrl(allowedHosts: hosts),
          throwsArgumentError,
        );
      }
      expect(fake.calls, isEmpty);
    });
  });

  group('device context', () {
    test('cleans the native values to the contract limits', () async {
      native(<String, Object?>{
        'getDeviceContext': <String, Object?>{
          'os_version': ' 18.6\n',
          'app_version': 'v' * 70,
          'app_build': '',
          'device_model': 'iPhone16,2',
          'locale': 'en_US',
        },
      });

      final context = await platform.getDeviceContext();

      expect(context.osVersion, '18.6');
      expect(context.appVersion, 'v' * 64);
      expect(context.appBuild, isNull);
      expect(context.deviceModel, 'iPhone16,2');
      expect(context.locale, 'en-US');
    });

    test('uses "unknown" for missing required values and drops a bad locale',
        () async {
      native(<String, Object?>{
        'getDeviceContext': <String, Object?>{'locale': 'not a locale!'},
      });

      final context = await platform.getDeviceContext();

      expect(context.osVersion, DeviceContext.unknownValue);
      expect(context.appVersion, DeviceContext.unknownValue);
      expect(context.locale, isNull);
    });

    test('falls back to unknown for an answer that is not a map', () async {
      native(<String, Object?>{'getDeviceContext': 'Pixel'});

      expect(await platform.getDeviceContext(), DeviceContext.unknown);
    });
  });

  group('link stream', () {
    Future<void> sendFromNative(ByteData? message) =>
        messenger.handlePlatformMessage(linkChannelName, message, (_) {});

    ByteData linkEvent(String url, int receivedAtMs) =>
        _codec.encodeSuccessEnvelope(<String, Object?>{
          'url': url,
          'received_at_ms': receivedAtMs,
        });

    test('starts on listen, delivers payloads and stops on cancel', () async {
      final control = <String>[];
      messenger.setMockMethodCallHandler(_linkControl, (call) async {
        control.add(call.method);
        return null;
      });
      final received = <PlatformLink>[];

      final subscription = platform.links.listen(received.add);
      await settle(const Duration(milliseconds: 10));
      await sendFromNative(linkEvent(testLinkUrl, 1791374400000));
      await sendFromNative(linkEvent('myapp://oauth?code=1', 1791374400001));
      await settle(const Duration(milliseconds: 10));
      await subscription.cancel();
      await settle(const Duration(milliseconds: 10));

      expect(control, <String>['listen', 'cancel']);
      expect(received.map((link) => link.url), <String>[
        testLinkUrl,
        'myapp://oauth?code=1',
      ]);
      expect(
        received.first.receivedAt,
        DateTime.fromMillisecondsSinceEpoch(1791374400000, isUtc: true),
      );
    });

    test('never errs or ends on bad native events', () async {
      messenger.setMockMethodCallHandler(_linkControl, (_) async => null);
      final received = <PlatformLink>[];
      var errors = 0;
      var done = false;

      final subscription = platform.links.listen(
        received.add,
        onError: (Object _) => errors++,
        onDone: () => done = true,
      );
      await settle(const Duration(milliseconds: 10));
      await sendFromNative(
        _codec.encodeErrorEnvelope(code: 'native_bug', message: 'x'),
      );
      await sendFromNative(_codec.encodeSuccessEnvelope('not a payload'));
      await sendFromNative(null);
      await sendFromNative(linkEvent(testLinkUrl, 1));
      await settle(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(received, hasLength(1));
      expect(errors, 0);
      expect(done, isFalse);
      expect(logs.text, contains('native_bug'));
    });
  });

  test('isDebugBuild follows the Dart build mode', () {
    expect(platform.isDebugBuild, kDebugMode);
  });
}

const String _seed = '3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10';
