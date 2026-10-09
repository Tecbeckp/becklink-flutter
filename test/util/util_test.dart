import 'dart:async';
import 'dart:math';

import 'package:becklink_flutter/src/util/async_lock.dart';
import 'package:becklink_flutter/src/util/fnv1a.dart';
import 'package:becklink_flutter/src/util/single_line.dart';
import 'package:becklink_flutter/src/util/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  group('uuidV4', () {
    test('creates lowercase version 4 UUIDs with the RFC variant', () {
      final random = Random(7);
      final ids = <String>{for (var i = 0; i < 100; i++) uuidV4(random)};

      expect(ids, hasLength(100));
      for (final id in ids) {
        expect(id, isLowercaseUuid);
        expect(id[14], '4');
        expect('89ab', contains(id[19]));
      }
    });
  });

  group('normalizeUuid', () {
    test('lower-cases a UUID of any version', () {
      expect(
        normalizeUuid('3F6C1B9E-8D2A-1C47-9B1E-5A7D2C8E4F10'),
        '3f6c1b9e-8d2a-1c47-9b1e-5a7d2c8e4f10',
      );
    });

    test('refuses the nil UUID and anything that is not a UUID', () {
      expect(normalizeUuid('00000000-0000-0000-0000-000000000000'), isNull);
      expect(normalizeUuid('3f6c1b9e8d2a4c479b1e5a7d2c8e4f10'), isNull);
      expect(normalizeUuid('{3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10}'), isNull);
      expect(normalizeUuid(''), isNull);
    });
  });

  group('fnv1a64Hex', () {
    test('matches the FNV-1a 64-bit reference values', () {
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');
      expect(fnv1a64Hex('foobar'), '85944171f73967e8');
    });
  });

  group('singleLine', () {
    test('turns control characters into spaces and trims', () {
      expect(
        singleLine('  first\nsecond\r\n\tthird ', maxLength: 100),
        'first second third',
      );
    });

    test('shortens with an ellipsis without splitting a surrogate pair', () {
      expect(singleLine('abcdef', maxLength: 4), 'abc…');
      // 'ab' + 😀 (two UTF-16 units) + 'cd': cutting after 3 units would
      // split the emoji, so it is dropped.
      expect(singleLine('ab😀cd', maxLength: 4), 'ab…');
    });
  });

  group('AsyncLock', () {
    test('runs actions one at a time in call order', () async {
      final lock = AsyncLock();
      final log = <String>[];
      final gate = Completer<void>();

      final first = lock.synchronized(() async {
        log.add('first start');
        await gate.future;
        log.add('first end');
      });
      final second = lock.synchronized(() async => log.add('second'));
      await settle(const Duration(milliseconds: 10));
      expect(log, <String>['first start']);

      gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(log, <String>['first start', 'first end', 'second']);
    });

    test('a failing action does not block the next one', () async {
      final lock = AsyncLock();
      final failing =
          lock.synchronized<void>(() async => throw StateError('x'));

      await expectLater(failing, throwsStateError);
      expect(await lock.synchronized(() async => 42), 42);
    });
  });
}
