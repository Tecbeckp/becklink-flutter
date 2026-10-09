import 'package:becklink_flutter/src/json/json_reader.dart';
import 'package:becklink_flutter/src/json/json_value.dart';
import 'package:becklink_flutter/src/json/malformed_json_exception.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _malformedAt(String pointer) => throwsA(
      isA<MalformedJsonException>()
          .having((error) => error.pointer, 'pointer', pointer),
    );

void main() {
  group('JsonReader', () {
    test('reads nested members and reports their JSON Pointers', () {
      final reader = JsonReader.root(<String, Object?>{
        'outer': <String, Object?>{
          'list': <Object?>[
            <String, Object?>{'name': 'a'},
            <String, Object?>{'name': 7},
          ],
        },
      });
      final items = reader.object('outer').objectList('list');

      expect(items.first.string('name'), 'a');
      expect(
          () => items.last.string('name'), _malformedAt('/outer/list/1/name'));
    });

    test('escapes ~ and / in pointers (RFC 6901)', () {
      final reader = JsonReader(<String, Object?>{'a/b~c': 1});

      expect(() => reader.string('a/b~c'), _malformedAt('/a~1b~0c'));
    });

    test('refuses a root that is not an object', () {
      expect(() => JsonReader.root(<Object?>[]), _malformedAt(''));
      expect(() => JsonReader.root('text'), _malformedAt(''));
    });

    test('treats a missing optional member as null but refuses a wrong type',
        () {
      final reader = JsonReader(<String, Object?>{'n': null, 'wrong': 1});

      expect(reader.optionalString('missing'), isNull);
      expect(reader.optionalString('n'), isNull);
      expect(reader.optionalObject('n'), isNull);
      expect(reader.optionalTimestamp('missing'), isNull);
      expect(() => reader.optionalString('wrong'), _malformedAt('/wrong'));
      expect(() => reader.optionalBoolean('wrong'), _malformedAt('/wrong'));
    });

    test('accepts integral doubles as integers only', () {
      final reader = JsonReader(<String, Object?>{
        'int': 3,
        'double': 3.0,
        'fraction': 3.5,
        'infinite': double.infinity,
      });

      expect(reader.integer('int'), 3);
      expect(reader.integer('double'), 3);
      expect(() => reader.integer('fraction'), _malformedAt('/fraction'));
      expect(() => reader.integer('infinite'), _malformedAt('/infinite'));
      expect(
        () => reader.optionalNumber('infinite'),
        _malformedAt('/infinite'),
      );
    });

    test('requires a zone on timestamps and returns UTC', () {
      final reader = JsonReader(<String, Object?>{
        'utc': '2026-10-07T12:00:00Z',
        'offset': '2026-10-07T14:00:00+02:00',
        'local': '2026-10-07T12:00:00',
      });

      expect(reader.timestamp('utc'), DateTime.utc(2026, 10, 7, 12));
      expect(reader.timestamp('offset'), DateTime.utc(2026, 10, 7, 12));
      expect(() => reader.timestamp('local'), _malformedAt('/local'));
    });

    test('accepts maps of any static type with string keys', () {
      final reader = JsonReader(<String, Object?>{
        'map': <Object?, Object?>{'a': 'b'},
        'bad': <Object?, Object?>{1: 'b'},
      });

      expect(reader.stringMap('map'), <String, String>{'a': 'b'});
      expect(() => reader.object('bad'), _malformedAt('/bad'));
    });

    test('returns deep, unmodifiable copies of JSON objects', () {
      final source = <String, Object?>{
        'data': <String, Object?>{
          'list': <Object?>[1],
        },
      };
      final copy = JsonReader(source).jsonObject('data');
      (source['data']! as Map<String, Object?>)['list'] = 'changed';

      expect(copy, <String, Object?>{
        'list': <Object?>[1],
      });
      expect(() => copy['x'] = 1, throwsUnsupportedError);
    });
  });

  group('JSON values', () {
    test('isJsonValue accepts JSON and nothing else', () {
      expect(
        isJsonValue(<String, Object?>{
          'a': <Object?>[null, true, 1, 1.5, 'x'],
        }),
        isTrue,
      );
      expect(isJsonValue(double.nan), isFalse);
      expect(isJsonValue(<Object?, Object?>{1: 'a'}), isFalse);
      expect(isJsonValue(<Object?>[Object()]), isFalse);
    });

    test('jsonEquals ignores map order and compares lists in order', () {
      expect(
        jsonEquals(
          <String, Object?>{'a': 1, 'b': 2},
          <String, Object?>{'b': 2, 'a': 1},
        ),
        isTrue,
      );
      expect(jsonEquals(<Object?>[1, 2], <Object?>[2, 1]), isFalse);
      expect(
        jsonHash(<String, Object?>{'a': 1, 'b': 2}),
        jsonHash(<String, Object?>{'b': 2, 'a': 1}),
      );
    });
  });
}
