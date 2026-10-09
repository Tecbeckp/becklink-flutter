import 'package:becklink_flutter/src/core/buffered_broadcast.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  group('BufferedBroadcast', () {
    test('hands values added before anyone listened to the first listener',
        () async {
      final broadcast = BufferedBroadcast<int>(capacity: 16)
        ..add(1)
        ..add(2);
      final received = <int>[];

      final subscription = broadcast.stream.listen(received.add);
      broadcast.add(3);
      await settle(const Duration(milliseconds: 10));

      expect(received, <int>[1, 2, 3]);
      await subscription.cancel();
      await broadcast.close();
    });

    test('keeps only the newest values up to its capacity', () async {
      final broadcast = BufferedBroadcast<int>(capacity: 2);
      for (var i = 1; i <= 5; i++) {
        broadcast.add(i);
      }

      final received = await broadcast.stream.take(2).toList();

      expect(received, <int>[4, 5]);
      await broadcast.close();
    });

    test('delivers to every current listener without buffering', () async {
      final broadcast = BufferedBroadcast<String>(capacity: 4);
      final first = <String>[];
      final second = <String>[];
      final a = broadcast.stream.listen(first.add);
      final b = broadcast.stream.listen(second.add);

      broadcast.add('link');
      await settle(const Duration(milliseconds: 10));
      await a.cancel();
      await b.cancel();
      final afterwards = <String>[];
      final c = broadcast.stream.listen(afterwards.add);
      await settle(const Duration(milliseconds: 10));

      expect(first, <String>['link']);
      expect(second, <String>['link']);
      expect(afterwards, isEmpty, reason: 'delivered values are not replayed');
      await c.cancel();
      await broadcast.close();
    });

    test('buffers again after the last listener left', () async {
      final broadcast = BufferedBroadcast<int>(capacity: 4);
      final first = broadcast.stream.listen((_) {});
      await first.cancel();

      broadcast.add(7);
      final received = await broadcast.stream.first;

      expect(received, 7);
      await broadcast.close();
    });

    test('drops values after close', () async {
      final broadcast = BufferedBroadcast<int>(capacity: 4)..add(1);
      await broadcast.close();

      broadcast.add(2);

      expect(await broadcast.stream.toList(), isEmpty);
    });
  });
}
