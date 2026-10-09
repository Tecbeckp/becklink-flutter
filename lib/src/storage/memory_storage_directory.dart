import 'dart:convert';

import 'storage_directory.dart';

/// A [StorageDirectory] that keeps documents in memory only.
///
/// For tests, and for the SDK when the platform offers no storage
/// directory: the SDK then works normally for the running process, but
/// state and queued events do not survive a restart. Internal to the SDK.
final class MemoryStorageDirectory implements StorageDirectory {
  /// Creates a directory that starts with [documents] (name to text).
  MemoryStorageDirectory([Map<String, String> documents = const {}]) {
    documents.forEach((name, contents) {
      checkDocumentName(name);
      _documents[name] = contents;
    });
  }

  final Map<String, String> _documents = <String, String>{};

  /// A snapshot of the documents (name to text), for tests and debugging.
  Map<String, String> get documents =>
      Map<String, String>.unmodifiable(_documents);

  @override
  Future<String?> read(String name, {required int maxBytes}) async {
    checkDocumentName(name);
    final contents = _documents[name];
    if (contents != null && utf8.encode(contents).length > maxBytes) {
      throw FormatException('Document is larger than $maxBytes bytes.');
    }
    return contents;
  }

  @override
  Future<void> write(String name, String contents) async {
    checkDocumentName(name);
    _documents[name] = contents;
  }

  @override
  Future<void> delete(String name) async {
    checkDocumentName(name);
    _documents.remove(name);
  }
}
