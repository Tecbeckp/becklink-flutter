import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  group('Attribution.fromJson', () {
    test('reads an attributed install', () {
      final attribution = Attribution.fromJson(attributionJson());

      expect(attribution.state, AttributionState.attributed);
      expect(attribution.matchMethod, MatchMethod.installReferrer);
      expect(attribution.confidence, Confidence.certain);
      expect(attribution.linkId, linkId);
      expect(attribution.campaign, Campaign.fromJson(campaignJson()));
      expect(
        attribution.installedAt,
        DateTime.utc(2026, 10, 7, 8, 46, 3, 551),
      );
    });

    test('reads an organic install with null members', () {
      final attribution = Attribution.fromJson(
        attributionJson(
          state: 'organic',
          matchMethod: null,
          confidence: null,
          id: null,
          withCampaign: false,
        ),
      );

      expect(attribution.state, AttributionState.organic);
      expect(attribution.matchMethod, isNull);
      expect(attribution.confidence, isNull);
      expect(attribution.linkId, isNull);
      expect(attribution.campaign, isNull);
    });

    test('accepts missing nullable members as null', () {
      final attribution = Attribution.fromJson(<String, Object?>{
        'state': 'reinstall',
        'installed_at': '2026-10-07T08:46:03Z',
      });

      expect(attribution.state, AttributionState.reinstall);
      expect(attribution.linkId, isNull);
    });

    test('maps an unknown state to unavailable', () {
      final attribution =
          Attribution.fromJson(attributionJson(state: 'probably'));

      expect(attribution.state, AttributionState.unavailable);
    });

    test('round-trips through toJson', () {
      final attribution = Attribution.fromJson(attributionJson());

      expect(Attribution.fromJson(attribution.toJson()), attribution);
      expect(
        Attribution.fromJson(attribution.toJson()).hashCode,
        attribution.hashCode,
      );
    });

    test('refuses a missing state or a malformed installed_at', () {
      expect(
        () => Attribution.fromJson(attributionJson()..remove('state')),
        throwsFormatException,
      );
      expect(
        () => Attribution.fromJson(
          attributionJson(installedAt: 'yesterday'),
        ),
        throwsFormatException,
      );
      expect(
        () => Attribution.fromJson(attributionJson()..['link_id'] = 7),
        throwsFormatException,
      );
    });
  });

  group('Campaign', () {
    test('round-trips through toJson with all six keys', () {
      final campaign = Campaign.fromJson(campaignJson());

      expect(campaign.toJson(), campaignJson());
      expect(Campaign.fromJson(campaign.toJson()), campaign);
    });

    test('refuses a value that is not a string', () {
      expect(
        () => Campaign.fromJson(campaignJson()..['source'] = 1),
        throwsFormatException,
      );
    });
  });

  group('enum wire values', () {
    test('every value round-trips through fromWire', () {
      for (final value in AttributionState.values) {
        expect(AttributionState.fromWire(value.wireValue), value);
      }
      for (final value in MatchMethod.values) {
        expect(MatchMethod.fromWire(value.wireValue), value);
      }
      for (final value in Confidence.values) {
        expect(Confidence.fromWire(value.wireValue), value);
      }
      for (final value in LogLevel.values) {
        expect(LogLevel.tryFromWire(value.wireValue), value);
      }
      for (final value in BeckLinkErrorCode.values) {
        expect(BeckLinkErrorCode.tryFromWire(value.wireValue), value);
      }
    });

    test('keeps the wire values of the contract', () {
      expect(
        MatchMethod.values.map((value) => value.wireValue),
        <String>[
          'universal_link',
          'app_link',
          'uri_scheme',
          'install_referrer',
          'pasteboard',
          'idfa',
          'probabilistic',
        ],
      );
      expect(
        BeckLinkErrorCode.values.map((value) => value.wireValue),
        <String>[
          'not_configured',
          'invalid_key',
          'network',
          'rate_limited',
          'tracking_disabled',
          'link_not_found',
          'timeout',
          'invalid_request',
        ],
      );
    });

    test('unknown values fall back without throwing', () {
      expect(LogLevel.tryFromWire('verbose'), isNull);
      expect(BeckLinkErrorCode.tryFromWire('teapot'), isNull);
    });
  });
}
