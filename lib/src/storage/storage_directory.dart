/// Where the SDK keeps its state and event queue: named text documents in
/// one directory that belongs to the SDK alone.
///
/// In apps the directory comes from the native layer and is excluded from
/// backups: Android `noBackupFilesDir/becklink`, iOS
/// `Application Support/becklink` marked as excluded from backup (contract
/// section 12 and P26: a restored or migrated device is a new install). See
/// `FileStorageDirectory`; tests and
/// apps without a usable directory use `MemoryStorageDirectory`. Internal to
/// the SDK.
abstract interface class StorageDirectory {
  /// The text of the document [name], or `null` when it does not exist.
  ///
  /// Throws a [FormatException] when the document is larger than [maxBytes]
  /// or is not valid UTF-8 (the caller treats it as corrupt), and a
  /// `FileSystemException` when it cannot be read.
  Future<String?> read(String name, {required int maxBytes});

  /// Replaces the document [name] with [contents] atomically: a reader sees
  /// either the old or the new text in full, even when the app is killed
  /// halfway.
  ///
  /// Throws a `FileSystemException` when the document cannot be written; the
  /// old text is then still in place.
  Future<void> write(String name, String contents);

  /// Removes the document [name]; nothing happens when it does not exist.
  ///
  /// Throws a `FileSystemException` when it cannot be removed.
  Future<void> delete(String name);
}

/// Suffix of the file a document is written to before it replaces the
/// document, so a crash never leaves a half-written document behind.
const String temporarySuffix = '.tmp';

final _documentName = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,63}$');

/// Throws an [ArgumentError] unless [name] can name a document: lowercase
/// letters, digits, `_`, `.` and `-`, no path separators, and not ending in
/// [temporarySuffix].
void checkDocumentName(String name) {
  if (!_documentName.hasMatch(name) || name.endsWith(temporarySuffix)) {
    throw ArgumentError.value(
      name,
      'name',
      'must be 1 to 64 lowercase letters, digits, "_", "." or "-", start '
          'with a letter or digit, and not end in "$temporarySuffix"',
    );
  }
}
