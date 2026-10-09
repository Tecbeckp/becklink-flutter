import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'dart:math';

import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:becklink_flutter/src/models/remote_config.dart';
import 'package:becklink_flutter/src/storage/first_open_record.dart';
import 'package:becklink_flutter/src/storage/memory_storage_directory.dart';
import 'package:becklink_flutter/src/storage/sdk_state_store.dart';
import 'package:becklink_flutter/src/storage/storage_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_support.dart';

class _MockStorageDirectory extends Mock implements StorageDirectory {}

const String _keychainId = '3F6C1B9E-8D2A-4C47-9B1E-5A7D2C8E4F10';

void main() {
  late MemoryStorageDirectory directory;
  late LogCapture logs;
  late TestClock clock;

  setUp(() {
    directory = MemoryStorageDirectory();
    logs = LogCapture();
    clock = TestClock();
  });

  Future<SdkStateStore> open([StorageDirectory? from]) => SdkStateStore.open(
        directory: from ?? directory,
        logger: SdkLogger(level: LogLevel.debug, sink: logs.add),
        now: clock.now,
        random: Random(3),
      );

  Map<String, Object?> stored() => jsonDecode(
        directory.documents[SdkStateStore.documentName]!,
      ) as Map<String, Object?>;

  group('install identity', () {
    test('is created once, with new random IDs, and kept', () async {
      final store = await open();
      expect(store.identity, isNull);

      final identity = await store.ensureIdentity();
      expect(identity.installId, isLowercaseUuid);
      expect(identity.firstOpenId, isLowercaseUuid);
      expect(identity.firstOpenId, isNot(identity.installId));
      expect(identity.createdAt, clock.now());
      expect(await store.ensureIdentity(), identity);

      final reopened = await open();
      expect(reopened.identity, identity);
    });

    test('takes the Keychain install ID (normalized) for a reinstall',
        () async {
      final store = await open();

      final identity = await store.ensureIdentity(
        platformInstallId: _keychainId,
      );

      expect(identity.installId, _keychainId.toLowerCase());
      expect(identity.firstOpenId, isNot(identity.installId));
    });

    test('replaces a Keychain value that is not a UUID, without logging it',
        () async {
      final store = await open();

      final identity = await store.ensureIdentity(
        platformInstallId: 'not-a-uuid-secret',
      );

      expect(identity.installId, isLowercaseUuid);
      expect(logs.at(LogLevel.error), hasLength(1));
      expect(logs.text, isNot(contains('not-a-uuid-secret')));
    });

    test('keeps the stored identity over a different Keychain value', () async {
      final store = await open();
      final first = await store.ensureIdentity();

      final again = await store.ensureIdentity(platformInstallId: _keychainId);

      expect(again, first);
    });

    test('is deleted with its first-open progress', () async {
      final store = await open();
      await store.ensureIdentity();
      await store.beginFirstOpen(<String, Object?>{'open_url': null});

      await store.deleteIdentity();

      expect(store.identity, isNull);
      expect(store.firstOpen, const FirstOpenNotStarted());
      expect(stored()['identity'], isNull);
      // The next identity is a new install.
      final next = await store.ensureIdentity();
      expect(next.installId, isLowercaseUuid);
    });
  });

  group('first open', () {
    test('keeps stored non-null evidence over later evidence', () async {
      final store = await open();
      await store.ensureIdentity();
      final firstEvidence = await store.beginFirstOpen(<String, Object?>{
        'ios_pasteboard_url': pasteboardClickUrl,
        'open_url': null,
      });
      expect(firstEvidence['ios_pasteboard_url'], pasteboardClickUrl);

      clock.advance(const Duration(minutes: 3));
      final retried = await store.beginFirstOpen(<String, Object?>{
        'ios_pasteboard_url': null,
        'open_url': testLinkUrl,
      });

      expect(retried, <String, Object?>{
        'ios_pasteboard_url': pasteboardClickUrl,
        'open_url': testLinkUrl,
      });
      final record = store.firstOpen as FirstOpenInFlight;
      // The first attempt's start time is kept.
      expect(
          record.startedAt, clock.now().subtract(const Duration(minutes: 3)));
    });

    test('survives a restart while in flight, with the same IDs', () async {
      final store = await open();
      final identity = await store.ensureIdentity();
      await store.beginFirstOpen(<String, Object?>{
        'android_install_referrer': installReferrer,
      });

      final reopened = await open();

      expect(reopened.identity, identity);
      expect(
        (reopened.firstOpen as FirstOpenInFlight).evidence,
        <String, Object?>{'android_install_referrer': installReferrer},
      );
    });

    test('stores the first answer only and drops the evidence', () async {
      final store = await open();
      final identity = await store.ensureIdentity();
      await store.beginFirstOpen(<String, Object?>{'open_url': null});

      await store.completeFirstOpen(
        <String, Object?>{'attribution': attributionJson()},
        firstOpenId: identity.firstOpenId,
      );
      await store.completeFirstOpen(
        <String, Object?>{'attribution': attributionJson(state: 'organic')},
        firstOpenId: identity.firstOpenId,
      );

      final record = store.firstOpen as FirstOpenCompleted;
      expect(record.result['attribution'], attributionJson());
      final storedRecord = stored().obj('identity').obj('first_open');
      expect(storedRecord['state'], 'completed');
      expect(storedRecord.keys, isNot(contains('evidence')));
      await expectLater(
        store.beginFirstOpen(const <String, Object?>{}),
        throwsStateError,
      );
    });

    test('ignores an answer for an identity that was deleted meanwhile',
        () async {
      final store = await open();
      final old = await store.ensureIdentity();
      await store.beginFirstOpen(const <String, Object?>{});
      await store.deleteIdentity();
      await store.ensureIdentity();
      await store.beginFirstOpen(const <String, Object?>{});

      await store.completeFirstOpen(
        <String, Object?>{'attribution': attributionJson()},
        firstOpenId: old.firstOpenId,
      );

      expect(store.firstOpen, isA<FirstOpenInFlight>());
    });

    test('needs an identity and a begun first open', () async {
      final store = await open();
      await expectLater(
        store.beginFirstOpen(const <String, Object?>{}),
        throwsStateError,
      );
      final identity = await store.ensureIdentity();
      await expectLater(
        store.completeFirstOpen(
          const <String, Object?>{},
          firstOpenId: identity.firstOpenId,
        ),
        throwsStateError,
      );
    });
  });

  group('settings', () {
    test('user ID, tracking choice and remote config survive a restart',
        () async {
      final store = await open();
      expect(store.trackingEnabled, isNull, reason: 'no choice made yet');
      expect(store.effectiveRemoteConfig, RemoteConfig.defaults);

      await store.setUserId('user_8841');
      await store.setTrackingEnabled(false);
      await store.saveRemoteConfig(
        RemoteConfig.fromJson(configJson(flushIntervalSeconds: 60)),
      );

      final reopened = await open();
      expect(reopened.userId, 'user_8841');
      expect(reopened.trackingEnabled, isFalse);
      expect(
        reopened.effectiveRemoteConfig.flushInterval,
        const Duration(seconds: 60),
      );
    });

    test('resetInstall forgets the install but not delivered links', () async {
      final store = await open();
      await store.ensureIdentity();
      await store.setUserId('user_8841');
      await store.setTrackingEnabled(true);
      await store.saveRemoteConfig(RemoteConfig.fromJson(configJson()));
      expect(await store.markLinkSeen('delivery'), isTrue);

      await store.resetInstall();

      expect(store.identity, isNull);
      expect(store.userId, isNull);
      expect(store.trackingEnabled, isNull);
      expect(store.remoteConfig, isNull);
      expect(await store.markLinkSeen('delivery'), isFalse);
    });

    test('remembers delivered links across a restart', () async {
      final store = await open();
      expect(await store.markLinkSeen('$testLinkUrl\n1'), isTrue);

      final reopened = await open();

      expect(await reopened.markLinkSeen('$testLinkUrl\n1'), isFalse);
      expect(
        directory.documents[SdkStateStore.documentName],
        isNot(contains('newsletter')),
      );
    });
  });

  group('damaged storage', () {
    test('a document that is not JSON is deleted and the SDK starts over',
        () async {
      directory = MemoryStorageDirectory(<String, String>{
        SdkStateStore.documentName: '{"identity": user_8841@example.com',
      });

      final store = await open();

      expect(store.identity, isNull);
      expect(directory.documents, isEmpty);
      expect(logs.at(LogLevel.error).single, contains('was reset'));
      expect(logs.text, isNot(contains('user_8841@example.com')));
    });

    test('a document without schema_version is reset', () async {
      directory = MemoryStorageDirectory(<String, String>{
        SdkStateStore.documentName: '{"user_id": "u1"}',
      });

      final store = await open();

      expect(store.userId, isNull);
    });

    test('a damaged section is reset alone; the install ID is kept', () async {
      final store = await open();
      final identity = await store.ensureIdentity();
      await store.setUserId('user_8841');
      final document = stored()..['remote_config'] = 'broken';
      directory = MemoryStorageDirectory(<String, String>{
        SdkStateStore.documentName: jsonEncode(document),
      });

      final reopened = await open();

      expect(reopened.identity, identity);
      expect(reopened.userId, 'user_8841');
      expect(reopened.remoteConfig, isNull);
      expect(logs.at(LogLevel.error).single, contains('/remote_config'));
      // Rewritten without the damaged part.
      expect(stored()['remote_config'], isNull);
    });

    test('damaged first-open progress keeps the identity', () async {
      final store = await open();
      final identity = await store.ensureIdentity();
      final document = stored();
      document.obj('identity')['first_open'] = <String, Object?>{
        'state': 'teleported',
      };
      directory = MemoryStorageDirectory(<String, String>{
        SdkStateStore.documentName: jsonEncode(document),
      });

      final reopened = await open();

      expect(reopened.identity, identity);
      expect(reopened.firstOpen, const FirstOpenNotStarted());
    });

    test('a document from a newer SDK is read as far as it is understood',
        () async {
      final store = await open();
      await store.setUserId('user_8841');
      final document = stored()
        ..['schema_version'] = 2
        ..['added_later'] = <String, Object?>{};
      directory = MemoryStorageDirectory(<String, String>{
        SdkStateStore.documentName: jsonEncode(document),
      });

      final reopened = await open();

      expect(reopened.userId, 'user_8841');
      expect(logs.at(LogLevel.info), contains(contains('newer SDK')));
    });

    test('a document that cannot be read is never overwritten', () async {
      final locked = _MockStorageDirectory();
      when(() => locked.read(any(), maxBytes: any(named: 'maxBytes')))
          .thenThrow(const FileSystemException('Data protection is on'));

      final store = await open(locked);
      await store.ensureIdentity();
      await store.setUserId('user_8841');

      expect(store.identity, isNotNull, reason: 'kept in memory');
      verifyNever(() => locked.write(any(), any()));
      verifyNever(() => locked.delete(any()));
    });

    test('a failed write is logged and the change still applies', () async {
      final full = _MockStorageDirectory();
      when(() => full.read(any(), maxBytes: any(named: 'maxBytes')))
          .thenAnswer((_) async => null);
      when(() => full.write(any(), any()))
          .thenThrow(const FileSystemException('No space left on device'));

      final store = await open(full);
      await store.setUserId('user_8841');

      expect(store.userId, 'user_8841');
      expect(logs.at(LogLevel.error).single, contains('Could not save'));
      expect(logs.text, isNot(contains('user_8841')));
    });
  });
}
