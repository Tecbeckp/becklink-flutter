/// Whether [value] is a JSON value: `null`, a [String], a [bool], a finite
/// [num], a [List] of JSON values, or a [Map] with [String] keys and JSON
/// values.
///
/// [value] must not contain cycles.
bool isJsonValue(Object? value) {
  if (value == null || value is String || value is bool) return true;
  // NaN and infinities have no JSON form.
  if (value is num) return value.isFinite;
  if (value is List<Object?>) return value.every(isJsonValue);
  if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      if (entry.key is! String || !isJsonValue(entry.value)) return false;
    }
    return true;
  }
  return false;
}

/// Returns a deep copy of [value] in which every [Map] and [List] is
/// unmodifiable, so models holding it are immutable all the way down.
///
/// [value] must satisfy [isJsonValue].
Object? freezeJson(Object? value) {
  if (value is Map<Object?, Object?>) {
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final entry in value.entries)
        entry.key as String: freezeJson(entry.value),
    });
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(freezeJson));
  }
  return value;
}

/// Returns a deep, unmodifiable copy of the JSON object [object].
///
/// [object] must satisfy [isJsonValue].
Map<String, Object?> freezeJsonObject(Map<String, Object?> object) =>
    freezeJson(object) as Map<String, Object?>;

/// Returns a deep, unmodifiable copy of [object], the argument named [name],
/// or throws an [ArgumentError] when it holds a value that is not JSON (see
/// [isJsonValue]).
Map<String, Object?> checkJsonObjectArgument(
  Map<String, Object?> object,
  String name,
) {
  if (!isJsonValue(object)) {
    throw ArgumentError(
      'must contain only JSON values: null, String, bool, finite num, List, '
      'and Map with String keys',
      name,
    );
  }
  return freezeJsonObject(object);
}

/// Deep equality of two JSON values: maps compare by entries regardless of
/// order, lists element by element, everything else with `==`.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !jsonEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Hash code consistent with [jsonEquals].
int jsonHash(Object? value) {
  if (value is Map<Object?, Object?>) {
    return Object.hashAllUnordered(
      value.entries
          .map((entry) => Object.hash(entry.key, jsonHash(entry.value))),
    );
  }
  if (value is List<Object?>) return Object.hashAll(value.map(jsonHash));
  return value.hashCode;
}
