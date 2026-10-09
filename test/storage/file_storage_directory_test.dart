import 'dart:io';

import 'package:becklink_flutter/src/storage/file_storage_directory.dart';
import 'package:becklink_flutter/src/storage/memory_storage_directory.dart';
import 'package:becklink_flutter/src/storage/storage_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory folder;
  late FileStorageDirectory storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('becklink_files_test_');
    // Created by the first write, as on a fresh install.
    folder = Directory('${root.path}${Platform.pathSeparator}becklink');
    storage = FileStorageDirectory(folder);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File file(String name) =>
      File('${folder.path}${Platform.pathSeparator}$name');

  group('FileStorageDirectory', () {
    test('reads nothing before the first write', () async {
      expect(await storage.read('state.json', maxBytes: 1024), isNull);
    });

    test('replaces a document and leaves no temporary file', () async {
      await storage.write('state.json', '{"v":1}');
      await storage.write('state.json', '{"v":2}');

      expect(await storage.read('state.json', maxBytes: 1024), '{"v":2}');
      expect(file('state.json$temporarySuffix').existsSync(), isFalse);
    });

    test('keeps the old document when a write fails', () async {
      await storage.write('state.json', '{"v":1}');
      // A folder where the temporary file must go makes the write fail.
      Directory(file('state.json$temporarySuffix').path).createSync();

      await expectLater(
        storage.write('state.json', '{"v":2}'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await storage.read('state.json', maxBytes: 1024), '{"v":1}');
    });

    test('treats an over-large or non-UTF-8 document as corrupt', () async {
      await storage.write('events.json', 'x' * 100);
      file('state.json').writeAsBytesSync(<int>[0xff, 0xfe, 0x00]);

      await expectLater(
        storage.read('events.json', maxBytes: 99),
        throwsFormatException,
      );
      await expectLater(
        storage.read('state.json', maxBytes: 1024),
        throwsFormatException,
      );
    });

    test('deletes a document and its temporary file', () async {
      await storage.write('state.json', '{}');
      file('state.json$temporarySuffix').writeAsStringSync('half');

      await storage.delete('state.json');
      await storage.delete('missing.json');

      expect(file('state.json').existsSync(), isFalse);
      expect(file('state.json$temporarySuffix').existsSync(), isFalse);
    });

    test('creates the folder again after it was removed', () async {
      await storage.write('state.json', '{"v":1}');
      folder.deleteSync(recursive: true);

      // The first write after the removal fails and resets the folder flag;
      // the next one recreates it.
      try {
        await storage.write('state.json', '{"v":2}');
      } on FileSystemException {
        await storage.write('state.json', '{"v":2}');
      }

      expect(await storage.read('state.json', maxBytes: 1024), '{"v":2}');
    });
  });

  group('document names', () {
    test('refuse path separators, temporary names and odd characters', () {
      for (final name in <String>[
        '../state.json',
        'a/b.json',
        r'a\b.json',
        'state.json.tmp',
        'State.json',
        '.hidden',
        '',
      ]) {
        expect(() => checkDocumentName(name), throwsArgumentError,
            reason: name);
        expect(
          () => storage.read(name, maxBytes: 1),
          throwsArgumentError,
          reason: name,
        );
      }
    });
  });

  group('MemoryStorageDirectory', () {
    test('behaves like a folder of documents', () async {
      final memory = MemoryStorageDirectory(
        const <String, String>{'state.json': '{}'},
      );

      expect(await memory.read('state.json', maxBytes: 10), '{}');
      await memory.write('events.json', '[]');
      await memory.delete('state.json');

      expect(memory.documents, <String, String>{'events.json': '[]'});
      await expectLater(
        memory.read('events.json', maxBytes: 1),
        throwsFormatException,
      );
    });
  });
}
