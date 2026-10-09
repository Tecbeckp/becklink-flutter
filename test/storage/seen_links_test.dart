import 'package:becklink_flutter/src/json/json_reader.dart';
import 'package:becklink_flutter/src/json/malformed_json_exception.dart';
import 'package:becklink_flutter/src/storage/seen_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 7, 12);
  const delivery = 'https://acme-test.becklinks.com/summer24?email=a@b.co\n1';

  group('SeenLinks', () {
    test('reports a delivery as new once', () {
      final seen = SeenLinks();

      expect(seen.record(delivery, t0), isTrue);
      expect(
          seen.record(delivery, t0.add(const Duration(minutes: 5))), isFalse);
      expect(seen.record('$delivery-other', t0), isTrue);
      expect(seen.length, 2);
    });

    test('forgets a delivery 24 hours after it was first seen', () {
      final seen = SeenLinks()..record(delivery, t0);

      // Seeing it again does not extend its lifetime.
      expect(seen.record(delivery, t0.add(const Duration(hours: 23))), isFalse);
      expect(
        seen.record(delivery, t0.add(const Duration(hours: 24))),
        isTrue,
      );
    });

    test('expires entries when the clock was set back by a day', () {
      final seen = SeenLinks()..record(delivery, t0);

      expect(
        seen.record(delivery, t0.subtract(const Duration(hours: 24))),
        isTrue,
      );
    });

    test('keeps the 50 most recently seen deliveries', () {
      final seen = SeenLinks();
      for (var i = 0; i < 50; i++) {
        seen.record('link $i', t0);
      }
      // Seen again, so it is the most recent and survives the eviction.
      seen
        ..record('link 0', t0)
        ..record('link 50', t0);

      expect(seen.length, 50);
      expect(seen.record('link 0', t0), isFalse);
      expect(seen.record('link 1', t0), isTrue, reason: 'evicted');
    });

    test('stores digests, never the URL', () {
      final seen = SeenLinks()..record(delivery, t0);
      final stored = seen.toJson();

      expect(stored, hasLength(1));
      expect(stored.single['digest'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(stored.single['first_seen_at'], '2026-10-07T12:00:00.000Z');
      expect(stored.toString(), isNot(contains('becklink')));
      expect(stored.toString(), isNot(contains('a@b.co')));
    });

    test('restores what it stored, in recency order', () {
      final original = SeenLinks()
        ..record('a', t0)
        ..record('b', t0)
        ..record('a', t0);
      final restored = SeenLinks()
        ..restore(<JsonReader>[
          for (final entry in original.toJson()) JsonReader(entry),
        ]);

      expect(restored.toJson(), original.toJson());
      expect(restored.record('a', t0), isFalse);
      expect(restored.record('b', t0), isFalse);
    });

    test('contains answers without recording and honours the lifetime', () {
      final seen = SeenLinks(lifetime: const Duration(seconds: 10));

      expect(seen.contains('a', t0), isFalse);
      expect(seen.length, 0);
      seen.record('a', t0);
      expect(seen.contains('a', t0.add(const Duration(seconds: 9))), isTrue);
      expect(seen.contains('a', t0.add(const Duration(seconds: 10))), isFalse);
    });

    test('refuses a stored entry that is not a digest', () {
      expect(
        () => SeenLinks().restore(<JsonReader>[
          JsonReader(<String, Object?>{
            'digest': 'https://acme.becklinks.com/x',
            'first_seen_at': '2026-10-07T12:00:00Z',
          }),
        ]),
        throwsA(isA<MalformedJsonException>()),
      );
    });
  });
}
