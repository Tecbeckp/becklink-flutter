import 'package:becklink_flutter/src/logging/redact_secrets.dart';
import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  group('redactSecrets', () {
    test('keeps only the visible prefix of API keys', () {
      expect(
        redactSecrets('key pk_live_AbC123xyz and sk_test_Secret99'),
        'key pk_live_[redacted] and sk_test_[redacted]',
      );
    });

    test('removes bearer tokens and email addresses', () {
      expect(
        redactSecrets(
            'Authorization: Bearer abc.def-ghi, user jane.doe@example.co.uk'),
        'Authorization: Bearer [redacted], user [email]',
      );
    });

    test('leaves ordinary text alone', () {
      const text = 'POST /v1/sdk/events answered HTTP 202 in 12 ms';

      expect(redactSecrets(text), text);
    });
  });

  group('SdkLogger', () {
    test('writes messages up to its level', () {
      final logs = LogCapture();
      final logger = SdkLogger(level: LogLevel.info, sink: logs.add)
        ..error('e')
        ..info('i')
        ..debug('d');

      expect(logs.lines.map((line) => line.message), <String>['e', 'i']);
      expect(logger.isEnabled(LogLevel.debug), isFalse);
      expect(logger.isEnabled(LogLevel.error), isTrue);
    });

    test('is silent at none', () {
      final logs = LogCapture();
      final logger = SdkLogger(level: LogLevel.none, sink: logs.add)
        ..error('e');

      expect(logs.lines, isEmpty);
      expect(logger.isEnabled(LogLevel.none), isFalse);
    });

    test('appends the error and redacts the whole line', () {
      final logs = LogCapture();
      SdkLogger(level: LogLevel.debug, sink: logs.add)
          .error('Request failed', StateError('Bearer pk_test_abcdef12345'));

      expect(logs.lines.single.level, LogLevel.error);
      expect(logs.lines.single.message, startsWith('Request failed: '));
      expect(logs.text, isNot(contains('abcdef12345')));
    });
  });
}
