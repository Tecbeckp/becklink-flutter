import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:becklink_flutter/src/core/link_url_rules.dart';
import 'package:becklink_flutter/src/core/sdk_options.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  final testRules = LinkUrlRules(environment: SdkEnvironment.test);
  final liveRules = LinkUrlRules(environment: SdkEnvironment.live);

  group('classify (contract section 9.1)', () {
    test('accepts an https link of the key environment', () {
      final url = testRules.classify(testLinkUrl);

      expect(url, isNotNull);
      expect(url!.form, LinkUrlForm.https);
      expect(url.received, testLinkUrl);
      expect(url.link.path, '/summer24');
      expect(url.fitsRequest, isTrue);
      expect(liveRules.classify('https://$liveHost/summer24'), isNotNull);
    });

    test('refuses a link of the other environment, and can tell why', () {
      const liveLink = 'https://$liveHost/summer24';

      expect(testRules.classify(liveLink), isNull);
      expect(testRules.isOtherEnvironmentLink(liveLink), isTrue);
      expect(liveRules.classify(testLinkUrl), isNull);
      expect(liveRules.isOtherEnvironmentLink(testLinkUrl), isTrue);
      expect(
          testRules.isOtherEnvironmentLink('https://example.com/x'), isFalse);
    });

    test('refuses reserved slugs and slugs ending in -test', () {
      for (final slug in <String>[
        'www',
        'app',
        'api',
        'docs',
        'status',
        'admin',
        'mail',
        'help',
        'cdn',
        'static',
        'assets',
        'acme-test',
      ]) {
        expect(
          liveRules.classify('https://$slug.becklinks.com/abc'),
          isNull,
          reason: slug,
        );
        expect(
          testRules.classify('https://$slug-test.becklinks.com/abc'),
          isNull,
          reason: '$slug-test',
        );
      }
    });

    test('limits a slug so that its test host is still one DNS label', () {
      final longest = 'a' * 58;

      expect(
          liveRules.classify('https://$longest.becklinks.com/abc'), isNotNull);
      expect(testRules.classify('https://$longest-test.becklinks.com/abc'),
          isNotNull);
      expect(
          liveRules.classify('https://${longest}a.becklinks.com/abc'), isNull);
    });

    test('refuses everything that is not exactly a link URL', () {
      for (final url in <String>[
        'http://$testHost/summer24',
        'https://a.$testHost/summer24',
        'https://becklinks.com/summer24',
        'https://$testHost:8443/summer24',
        'https://user@$testHost/summer24',
        'https://$testHost/',
        'https://$testHost/a/b',
        'https://$testHost/${'a' * 65}',
        'https://$testHost/sum mer',
        'https://example.com/summer24',
        'myapp://oauth/callback?code=secret',
        'not a url',
      ]) {
        expect(testRules.classify(url), isNull, reason: url);
      }
    });

    test('ignores case in the host and the default port', () {
      expect(
        testRules.classify('https://ACME-TEST.becklinks.com:443/Summer24'),
        isNotNull,
      );
    });

    test('accepts the custom domains of the cached config', () {
      final rules = LinkUrlRules(
        environment: SdkEnvironment.test,
        linkHosts: const <String>['Go.Acme.com'],
      );

      expect(rules.classify('https://go.acme.com/summer24'), isNotNull);
      expect(testRules.classify('https://go.acme.com/summer24'), isNull);
    });

    test('accepts the "Open in app" custom-scheme form', () {
      final embedded = Uri.encodeComponent(testLinkUrl);
      final received = 'myapp://becklink?url=$embedded&click_id=$clickId';

      final url = testRules.classify(received);

      expect(url, isNotNull);
      expect(url!.form, LinkUrlForm.customScheme);
      expect(url.received, received);
      expect(url.link, Uri.parse(testLinkUrl));
    });

    test(
        'refuses custom-scheme URLs that do not embed a link of this '
        'environment', () {
      for (final url in <String>[
        'myapp://other?url=${Uri.encodeComponent(testLinkUrl)}',
        'myapp://becklink',
        'myapp://becklink?url=${Uri.encodeComponent('http://$testHost/x')}',
        'myapp://becklink?url='
            '${Uri.encodeComponent('https://$liveHost/summer24')}',
        'http://becklink?url=${Uri.encodeComponent(testLinkUrl)}',
      ]) {
        expect(testRules.classify(url), isNull, reason: url);
      }
    });

    test('marks a received URL over 2,048 characters as too long to send', () {
      final url = testRules.classify('$testLinkUrl&pad=${'x' * 2048}');

      expect(url, isNotNull);
      expect(url!.fitsRequest, isFalse);
    });

    test('never shows the query in toString', () {
      expect(
        testRules.classify(testLinkUrl).toString(),
        isNot(contains('newsletter')),
      );
    });
  });

  group('pasteboard rules', () {
    test('ask the native layer with the coarse platform pattern', () {
      expect(testRules.pasteboardHostPatterns, <String>['*.becklinks.com']);
      expect(
        LinkUrlRules(
          environment: SdkEnvironment.test,
          linkHosts: const <String>['go.acme.com', testHost, 'localhost'],
        ).pasteboardHostPatterns,
        <String>['*.becklinks.com', 'go.acme.com', testHost],
      );
    });

    test('accept only a click URL of this environment', () {
      expect(testRules.acceptsPasteboardUrl(pasteboardClickUrl), isTrue);
      expect(
        testRules.acceptsPasteboardUrl('https://$liveHost/_c/$clickId'),
        isFalse,
      );
      expect(
        liveRules.acceptsPasteboardUrl('https://$liveHost/_c/$clickId'),
        isTrue,
      );
      expect(
        testRules
            .acceptsPasteboardUrl('https://app-test.becklinks.com/_c/$clickId'),
        isFalse,
      );
    });
  });

  group('offlineLinkEvent (contract section 7.3 "Offline")', () {
    final receivedAt = DateTime.utc(2026, 10, 7, 12);

    test('builds the event from the URL alone', () {
      final url = testRules.classify('$testLinkUrl&ref=second&lang=en')!;

      final event = offlineLinkEvent(url, receivedAt: receivedAt, isIos: false);

      expect(event.url, url.receivedUri);
      expect(event.path, '/summer24');
      expect(event.params, <String, String>{'ref': 'second', 'lang': 'en'});
      expect(event.data, isEmpty);
      expect(event.linkId, isNull);
      expect(event.campaign, isNull);
      expect(event.isDeferred, isFalse);
      expect(event.matchMethod, MatchMethod.appLink);
      expect(event.confidence, Confidence.certain);
      expect(event.clickedAt, receivedAt);
    });

    test('derives the match method from the form and the platform', () {
      final https = testRules.classify(testLinkUrl)!;
      final scheme = testRules.classify(
        'myapp://becklink?url=${Uri.encodeComponent(testLinkUrl)}',
      )!;

      expect(
        offlineLinkEvent(https, receivedAt: receivedAt, isIos: true)
            .matchMethod,
        MatchMethod.universalLink,
      );
      final fromScheme =
          offlineLinkEvent(scheme, receivedAt: receivedAt, isIos: true);
      expect(fromScheme.matchMethod, MatchMethod.uriScheme);
      expect(fromScheme.path, '/summer24');
      expect(fromScheme.params, <String, String>{'ref': 'newsletter'});
      expect(fromScheme.url, scheme.receivedUri);
    });
  });

  group('platformHostEnvironment', () {
    test('tells live and test hosts apart', () {
      expect(platformHostEnvironment(liveHost), SdkEnvironment.live);
      expect(platformHostEnvironment(testHost), SdkEnvironment.test);
      expect(platformHostEnvironment('becklinks.com'), isNull);
      expect(platformHostEnvironment('acme.becklinks.com.evil'), isNull);
    });
  });
}
