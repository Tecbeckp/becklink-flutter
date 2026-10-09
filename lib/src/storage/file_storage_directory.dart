import 'dart:convert';
import 'dart:io';

import 'storage_directory.dart';

/// A [StorageDirectory] backed by a directory on disk, one file per
/// document.
///
/// Writes go to `<name>.tmp` first (flushed to disk) and are then renamed
/// over the document, so the document is always either the old or the new
/// version. Only one writer per document may exist in a process; the SDK's
/// stores serialise their own writes. Internal to the SDK.
final class FileStorageDirectory implements StorageDirectory {
  /// Creates a storage directory in [directory], which is created on the
  /// first write. [directory] must belong to the SDK alone; in apps it is
  /// the folder `BeckLinkPlatform.getStorageDirectory` reports (Android
  /// `noBackupFilesDir/becklink`, iOS `Application Support/becklink`), which
  /// the native layer already created and excluded from backups.
  FileStorageDirectory(this.directory);

  /// The directory that holds the documents.
  final Directory directory;

  bool _created = false;

  @override
  Future<String?> read(String name, {required int maxBytes}) async {
    checkDocumentName(name);
    final file = _file(name);
    try {
      final length = await file.length();
      // Checked before reading, so a runaway file cannot exhaust memory.
      if (length > maxBytes) {
        throw FormatException('Document is larger than $maxBytes bytes.');
      }
      // Throws a FormatException for bytes that are not valid UTF-8.
      return utf8.decode(await file.readAsBytes());
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> write(String name, String contents) async {
    checkDocumentName(name);
    final temporary = _file('$name$temporarySuffix');
    try {
      if (!_created) {
        await directory.create(recursive: true);
        _created = true;
      }
      // flush: the bytes must be on disk before the rename makes them the
      // document, otherwise a power loss could leave an empty document.
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(_file(name).path);
    } on FileSystemException {
      // The directory may have been removed meanwhile (the user cleared the
      // app's data); the next write creates it again.
      _created = false;
      try {
        await temporary.delete();
      } on FileSystemException {
        // Best effort: the original failure is the one worth reporting, and
        // the next write replaces the leftover anyway.
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String name) async {
    checkDocumentName(name);
    await _deleteIfPresent(_file(name));
    await _deleteIfPresent(_file('$name$temporarySuffix'));
  }

  File _file(String name) =>
      File('${directory.path}${Platform.pathSeparator}$name');

  static Future<void> _deleteIfPresent(File file) async {
    try {
      await file.delete();
    } on PathNotFoundException {
      // Already gone, which is the goal.
    }
  }
}
