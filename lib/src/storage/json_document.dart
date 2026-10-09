import 'dart:convert';
import 'dart:io' show FileSystemException;

import '../json/json_reader.dart';
import '../json/malformed_json_exception.dart';
import '../logging/sdk_logger.dart';
import '../util/async_lock.dart';
import 'storage_directory.dart';

/// One JSON document of SDK state in a [StorageDirectory]: a JSON object
/// with an integer `schema_version` member, read so that damage never stops
/// the app, and written one write at a time.
///
/// Callers must never pass user data to the logger; this class logs only
/// the document name and what went wrong, never document content. Internal
/// to the SDK.
final class JsonDocument {
  /// Creates the document [name] in [directory], whose current layout is
  /// [schemaVersion]. Reads refuse documents larger than [maxBytes].
  JsonDocument({
    required this.name,
    required this.schemaVersion,
    required StorageDirectory directory,
    required SdkLogger logger,
    this.maxBytes = defaultMaxBytes,
  })  : _directory = directory,
        _logger = logger {
    checkDocumentName(name);
    if (schemaVersion < 1) {
      throw ArgumentError.value(schemaVersion, 'schemaVersion', 'must be >= 1');
    }
  }

  /// Default read limit. Far above what any SDK document holds (the event
  /// queue is capped at 2 MiB), so it only stops a runaway file from
  /// exhausting memory.
  static const int defaultMaxBytes = 4 * 1024 * 1024;

  /// The member that holds the layout version of a document.
  static const String versionKey = 'schema_version';

  /// File name of the document.
  final String name;

  /// Layout version this SDK writes. Raise it only for a layout an older SDK
  /// would misread; a member whose meaning changes gets a new name instead.
  final int schemaVersion;

  /// Largest document [load] accepts.
  final int maxBytes;

  final StorageDirectory _directory;
  final SdkLogger _logger;
  final AsyncLock _lock = AsyncLock();
  Future<void>? _pendingSave;

  /// Whether [save] may write. Turned off when the document exists but
  /// could not be read (for example iOS data protection before the first
  /// unlock after a reboot): writing would replace a document that may be
  /// intact, such as the install ID, with this process's empty state.
  bool _writable = true;

  /// Reads the document, or returns `null` when there is none or it cannot
  /// be used.
  ///
  /// A corrupt document (too large, not UTF-8, not a JSON object, or without
  /// a usable `schema_version`) is deleted and reported at error level: the
  /// SDK then starts over with defaults instead of failing on every launch.
  /// A document that cannot be read at all is left alone, and [save] does
  /// nothing until the app restarts. A document from a newer SDK (higher
  /// `schema_version`, after the app was downgraded) is returned as well,
  /// because newer layouts keep the meaning of every member they keep (see
  /// [schemaVersion]). Callers read members leniently and fall back to
  /// defaults for what they cannot use.
  Future<JsonReader?> load() => _lock.synchronized(_load);

  /// Writes the object [snapshot] returns, plus `schema_version`, replacing
  /// the document atomically.
  ///
  /// Writes run one at a time. A call made while another write is still
  /// waiting for its turn joins that write, whose [snapshot] runs only when
  /// it starts and so includes every change made before. A failed write is
  /// logged at error level and not thrown: the state stays in memory and
  /// applies until the app restarts. Does nothing after [load] could not
  /// read the document.
  Future<void> save(Map<String, Object?> Function() snapshot) {
    if (!_writable) return Future<void>.value();
    final pending = _pendingSave;
    if (pending != null) return pending;
    final write = _lock.synchronized<void>(() async {
      _pendingSave = null;
      final text = jsonEncode(<String, Object?>{
        versionKey: schemaVersion,
        ...snapshot(),
      });
      try {
        await _directory.write(name, text);
      } on FileSystemException catch (error) {
        _logger.error(
          'Could not save the SDK document "$name"; the change applies '
          'until the app restarts',
          error,
        );
      }
    });
    _pendingSave = write;
    return write;
  }

  /// Completes once every read and write started so far has finished.
  Future<void> whenIdle() => _lock.whenIdle();

  Future<JsonReader?> _load() async {
    final String? text;
    try {
      text = await _directory.read(name, maxBytes: maxBytes);
    } on FormatException {
      await _discard('is larger than $maxBytes bytes or not UTF-8 text');
      return null;
    } on FileSystemException catch (error) {
      _writable = false;
      _logger.error(
        'Could not read the SDK document "$name"; until the app restarts '
        'the SDK keeps its state in memory and leaves the document as it is',
        error,
      );
      return null;
    }
    if (text == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      // The exception would quote the document, which can hold user data.
      await _discard('is not valid JSON');
      return null;
    }
    try {
      final reader = JsonReader.root(decoded);
      final version = reader.integer(versionKey);
      if (version < 1) reader.fail(versionKey, 'a schema version of 1 or more');
      if (version > schemaVersion) {
        _logger.info(
          'The SDK document "$name" comes from a newer SDK version (schema '
          '$version); reading the parts this version knows',
        );
      }
      return reader;
    } on MalformedJsonException catch (error) {
      await _discard('is malformed (${error.message})');
      return null;
    }
  }

  Future<void> _discard(String problem) async {
    _logger.error(
      'The SDK document "$name" $problem and was reset. A storage fault can '
      'cause this; the SDK continues with defaults',
    );
    try {
      await _directory.delete(name);
    } on FileSystemException catch (error) {
      _logger.error('Could not remove the SDK document "$name"', error);
    }
  }
}
