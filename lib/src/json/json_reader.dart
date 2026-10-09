import 'json_value.dart';
import 'malformed_json_exception.dart';

/// Reads typed members from one decoded JSON object and reports a member
/// with the wrong shape as a [MalformedJsonException] naming its JSON
/// Pointer.
///
/// Members documented as "string or null" accept a missing key as `null`
/// (requests may omit them, contract section 2); a present member of the
/// wrong type is always malformed. Unknown members are ignored, so newer
/// servers can add fields (contract section 13).
final class JsonReader {
  /// Creates a reader for [json], located at [pointer] inside the enclosing
  /// document (empty for the root).
  JsonReader(this._json, {this.pointer = ''});

  /// Creates a reader for a decoded JSON document whose root must be an
  /// object.
  factory JsonReader.root(Object? document) {
    final object = _asObject(document);
    if (object == null) throw MalformedJsonException('', 'a JSON object');
    return JsonReader(object);
  }

  final Map<String, Object?> _json;

  /// RFC 6901 JSON Pointer of this object inside the enclosing document.
  final String pointer;

  /// Throws a [MalformedJsonException] for the member [key], which is not
  /// [expected].
  Never fail(String key, String expected) =>
      throw MalformedJsonException(_pointerTo(key), expected);

  /// The required string member [key].
  String string(String key) {
    final value = _json[key];
    if (value is String) return value;
    fail(key, 'a string');
  }

  /// The string member [key], or `null` when it is missing or `null`.
  String? optionalString(String key) {
    final value = _json[key];
    if (value is String?) return value;
    fail(key, 'a string or null');
  }

  /// The required boolean member [key].
  bool boolean(String key) {
    final value = _json[key];
    if (value is bool) return value;
    fail(key, 'a boolean');
  }

  /// The boolean member [key], or `null` when it is missing or `null`.
  bool? optionalBoolean(String key) {
    final value = _json[key];
    if (value is bool?) return value;
    fail(key, 'a boolean or null');
  }

  /// The finite number member [key], or `null` when it is missing or
  /// `null`.
  num? optionalNumber(String key) {
    final value = _json[key];
    if (value == null) return null;
    if (value is num && value.isFinite) return value;
    fail(key, 'a finite number or null');
  }

  /// The required integer member [key]; an integral double such as `15.0`
  /// is accepted as well, because JSON has a single number type.
  int integer(String key) {
    final value = _json[key];
    if (value is int) return value;
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    fail(key, 'an integer');
  }

  /// The required timestamp member [key], as a UTC [DateTime].
  ///
  /// The string must be ISO-8601 with a zone designator (`Z` or an offset);
  /// a timestamp without one is ambiguous and therefore malformed.
  DateTime timestamp(String key) {
    final value = _json[key];
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      // DateTime.parse returns UTC exactly when the string names a zone.
      if (parsed != null && parsed.isUtc) return parsed;
    }
    fail(key, 'an ISO-8601 timestamp in UTC');
  }

  /// The timestamp member [key] as a UTC [DateTime] (see [timestamp]), or
  /// `null` when it is missing or `null`.
  DateTime? optionalTimestamp(String key) {
    if (_json[key] == null) return null;
    return timestamp(key);
  }

  /// The required absolute URI member [key].
  Uri uri(String key) {
    final value = _json[key];
    if (value is String) {
      final parsed = Uri.tryParse(value);
      if (parsed != null && parsed.hasScheme) return parsed;
    }
    fail(key, 'an absolute URI');
  }

  /// A reader for the required object member [key].
  JsonReader object(String key) {
    final value = _asObject(_json[key]);
    if (value == null) fail(key, 'an object');
    return JsonReader(value, pointer: _pointerTo(key));
  }

  /// A reader for the object member [key], or `null` when it is missing or
  /// `null`.
  JsonReader? optionalObject(String key) {
    if (_json[key] == null) return null;
    return object(key);
  }

  /// Readers for the required member [key], an array of objects, each
  /// located at its own JSON Pointer (`/key/0`, `/key/1`, …).
  List<JsonReader> objectList(String key) {
    final value = _json[key];
    if (value is! List<Object?>) fail(key, 'an array of objects');
    final readers = <JsonReader>[];
    for (var index = 0; index < value.length; index++) {
      final item = _asObject(value[index]);
      if (item == null) fail(key, 'an array of objects');
      readers.add(JsonReader(item, pointer: '${_pointerTo(key)}/$index'));
    }
    return readers;
  }

  /// The required member [key], an object whose values are all strings.
  Map<String, String> stringMap(String key) {
    final value = _asObject(_json[key]);
    if (value == null || value.values.any((item) => item is! String)) {
      fail(key, 'an object of string values');
    }
    return Map<String, String>.unmodifiable(value.cast<String, String>());
  }

  /// The required member [key], an object whose values are all booleans.
  Map<String, bool> boolMap(String key) {
    final value = _asObject(_json[key]);
    if (value == null || value.values.any((item) => item is! bool)) {
      fail(key, 'an object of boolean values');
    }
    return Map<String, bool>.unmodifiable(value.cast<String, bool>());
  }

  /// The required member [key], an array of strings.
  List<String> stringList(String key) {
    final value = _json[key];
    if (value is List<Object?> && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    fail(key, 'an array of strings');
  }

  /// The required member [key], an arbitrary JSON object, as a deep,
  /// unmodifiable copy.
  Map<String, Object?> jsonObject(String key) {
    final value = _asObject(_json[key]);
    if (value == null || !isJsonValue(value)) fail(key, 'a JSON object');
    return freezeJsonObject(value);
  }

  /// The member [key] as for [jsonObject], or `null` when it is missing or
  /// `null`.
  Map<String, Object?>? optionalJsonObject(String key) {
    if (_json[key] == null) return null;
    return jsonObject(key);
  }

  String _pointerTo(String key) =>
      '$pointer/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';

  /// [value] as a map with string keys, or `null` when it is not one.
  ///
  /// Accepts any map type (decoders differ in the static type they produce)
  /// as long as every key is a string.
  static Map<String, Object?>? _asObject(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map<Object?, Object?> &&
        value.keys.every((key) => key is String)) {
      return value.cast<String, Object?>();
    }
    return null;
  }
}
