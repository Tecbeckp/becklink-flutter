import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/json/malformed_json_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  group('LinkEvent.fromJson', () {
    test('reads the contract example of a deferred match', () {
      final event = LinkEvent.fromJson(
        linkEventJson(isDeferred: true, matchMethod: 'install_referrer'),
      );

      expect(event.url, Uri.parse(testLinkUrl));
      expect(event.path, '/product/123');
      expect(event.params, <String, String>{'ref': 'newsletter'});
      expect(
        event.data,
        <String, Object?>{'coupon': 'SUMMER10', 'color': 'blue'},
      );
      expect(event.isDeferred, isTrue);
      expect(event.matchMethod, MatchMethod.installReferrer);
      expect(event.confidence, Confidence.certain);
      expect(event.linkId, linkId);
      expect(event.campaign?.name, 'Summer sale 2026');
      expect(event.campaign?.term, isNull);
      expect(event.clickedAt, DateTime.utc(2026, 10, 7, 8, 41, 17, 204));
      expect(event.clickedAt.isUtc, isTrue);
    });

    test('round-trips through toJson', () {
      final event = LinkEvent.fromJson(
        linkEventJson(
          data: <String, Object?>{
            'nested': <String, Object?>{
              'list': <Object?>[1, 2.5, 'three', null, true],
            },
          },
        ),
      );

      expect(LinkEvent.fromJson(event.toJson()), event);
      expect(LinkEvent.fromJson(event.toJson()).hashCode, event.hashCode);
    });

    test('reads a link without campaign or link data', () {
      final event = LinkEvent.fromJson(
        linkEventJson(
          withCampaign: false,
          data: const <String, Object?>{},
          params: const <String, Object?>{},
        ),
      );

      expect(event.campaign, isNull);
      expect(event.data, isEmpty);
      expect(event.params, isEmpty);
    });

    test('maps unknown enum values to the weakest evidence', () {
      final event = LinkEvent.fromJson(
        linkEventJson(matchMethod: 'quantum', confidence: 'maybe'),
      );

      expect(event.matchMethod, MatchMethod.probabilistic);
      expect(event.confidence, Confidence.low);
    });

    test('ignores members it does not know', () {
      final json = linkEventJson()..['added_later'] = <String, Object?>{};

      expect(LinkEvent.fromJson(json).path, '/product/123');
    });

    test('refuses a missing member and names only its JSON Pointer', () {
      final json = linkEventJson()..remove('path');

      expect(
        () => LinkEvent.fromJson(json),
        throwsA(
          isA<MalformedJsonException>()
              .having((error) => error.pointer, 'pointer', '/path'),
        ),
      );
    });

    test('refuses members of the wrong type', () {
      final cases = <String, Object?>{
        'url': 'not a uri without scheme',
        'is_deferred': 'true',
        'match_method': 1,
        'link_id': 42,
        'params': <String, Object?>{'ref': 1},
        'data': <Object?>[],
        'campaign': 'summer',
      };
      for (final entry in cases.entries) {
        final json = linkEventJson()..[entry.key] = entry.value;
        expect(
          () => LinkEvent.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: entry.key,
        );
      }
    });

    test('refuses a timestamp without a zone', () {
      final json = linkEventJson(clickedAt: '2026-10-07T08:41:17.204');

      expect(
        () => LinkEvent.fromJson(json),
        throwsA(
          isA<MalformedJsonException>()
              .having((error) => error.pointer, 'pointer', '/clicked_at'),
        ),
      );
    });

    test('converts a timestamp with an offset to UTC', () {
      final event = LinkEvent.fromJson(
        linkEventJson(clickedAt: '2026-10-07T10:41:17.204+02:00'),
      );

      expect(event.clickedAt, DateTime.utc(2026, 10, 7, 8, 41, 17, 204));
    });

    test('never puts a received value into the error message', () {
      final json = linkEventJson()..['path'] = 42;

      expect(
        () => LinkEvent.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('/path'), isNot(contains('42'))),
          ),
        ),
      );
    });
  });

  group('LinkEvent', () {
    LinkEvent build({Map<String, Object?>? data}) => LinkEvent(
          url: Uri.parse('https://$testHost/abc?email=a@b.co'),
          path: '/product/123?secret=1',
          isDeferred: false,
          matchMethod: MatchMethod.appLink,
          confidence: Confidence.certain,
          clickedAt: DateTime.utc(2026),
          params: const <String, String>{'email': 'a@b.co'},
          data: data ?? const <String, Object?>{'token': 'hidden'},
        );

    test('keeps params and data unmodifiable, at every level', () {
      final source = <String, Object?>{
        'list': <Object?>[1],
        'map': <String, Object?>{'a': 1},
      };
      final event = build(data: source);
      source['list'] = 'changed';

      expect(event.data['list'], <Object?>[1]);
      expect(() => event.data['x'] = 1, throwsUnsupportedError);
      expect(
        () => (event.data['list']! as List<Object?>).add(2),
        throwsUnsupportedError,
      );
      expect(
        () => (event.data['map']! as Map<String, Object?>)['b'] = 2,
        throwsUnsupportedError,
      );
      expect(() => event.params['x'] = 'y', throwsUnsupportedError);
    });

    test('refuses data that is not JSON', () {
      expect(
        () => build(data: <String, Object?>{'when': DateTime(2026)}),
        throwsArgumentError,
      );
      expect(
        () => build(data: <String, Object?>{'nan': double.nan}),
        throwsArgumentError,
      );
    });

    test('converts clickedAt to UTC', () {
      final local = DateTime(2026, 10, 7, 12);
      final event = LinkEvent(
        url: Uri.parse('https://$testHost/abc'),
        path: '/',
        isDeferred: false,
        matchMethod: MatchMethod.appLink,
        confidence: Confidence.certain,
        clickedAt: local,
      );

      expect(event.clickedAt.isUtc, isTrue);
      expect(event.clickedAt, local.toUtc());
    });

    test('leaves query strings and values out of toString', () {
      final text = build().toString();

      expect(text, isNot(contains('a@b.co')));
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('hidden')));
      expect(text, contains('/product/123'));
    });
  });
}
