import 'dart:collection';

import '../json/json_reader.dart';
import '../util/fnv1a.dart';

/// The links delivered recently, so the same delivery never reaches the app
/// twice (requirements §29.5 "onLink har link par sirf ek baar"), for
/// example when Android hands the launch intent over again after the
/// activity was recreated.
///
/// Holds at most [capacity] keys, each for [lifetime] after it was first
/// seen; when full, the least recently seen key goes first. Only a 64-bit
/// FNV-1a digest of each key is kept, so link URLs, whose query can carry
/// user data, are not stored. Internal to the SDK.
final class SeenLinks {
  /// Creates an empty set.
  SeenLinks({this.capacity = defaultCapacity, this.lifetime = defaultLifetime})
      : assert(capacity > 0, 'capacity must be positive');

  /// Default [capacity].
  static const int defaultCapacity = 50;

  /// Default [lifetime].
  static const Duration defaultLifetime = Duration(hours: 24);

  /// Most keys kept.
  final int capacity;

  /// How long a key counts as seen after it was first seen.
  final Duration lifetime;

  // Digest to first-seen time (UTC), least recently seen first.
  final LinkedHashMap<String, DateTime> _entries =
      LinkedHashMap<String, DateTime>();

  /// Number of keys kept.
  int get length => _entries.length;

  /// Records [key] as seen at [now] and returns whether it is new, that is,
  /// not seen within [lifetime].
  ///
  /// A repeated key keeps its first-seen time (so it expires [lifetime]
  /// after its first delivery) but counts as recently seen for eviction.
  bool record(String key, DateTime now) {
    final utcNow = now.toUtc();
    removeExpired(utcNow);
    final digest = fnv1a64Hex(key);
    final firstSeen = _entries.remove(digest);
    if (firstSeen != null) {
      _entries[digest] = firstSeen;
      return false;
    }
    _entries[digest] = utcNow;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  /// Whether [key] was recorded and is still within [lifetime] at [now].
  /// Records nothing.
  bool contains(String key, DateTime now) {
    final firstSeen = _entries[fnv1a64Hex(key)];
    return firstSeen != null &&
        now.toUtc().difference(firstSeen).abs() < lifetime;
  }

  /// Removes keys first seen [lifetime] or longer ago, and returns how many.
  ///
  /// A first-seen time that lies [lifetime] or more in the future also
  /// counts as expired: the device clock was set back, and a key must not
  /// stay blocked for that long.
  int removeExpired(DateTime now) {
    final before = _entries.length;
    _entries.removeWhere(
      (_, firstSeen) => now.difference(firstSeen).abs() >= lifetime,
    );
    return before - _entries.length;
  }

  /// The stored form, least recently seen first.
  List<Map<String, Object?>> toJson() => <Map<String, Object?>>[
        for (final entry in _entries.entries)
          <String, Object?>{
            'digest': entry.key,
            'first_seen_at': entry.value.toIso8601String(),
          },
      ];

  /// Replaces the content with the stored form read by [readers], least
  /// recently seen first; throws a `MalformedJsonException` when an entry
  /// has the wrong shape. Keeps at most [capacity] of the most recent ones.
  void restore(List<JsonReader> readers) {
    // Map literals keep insertion order, which is the recency order here.
    final restored = <String, DateTime>{};
    for (final reader in readers) {
      final digest = reader.string('digest');
      if (!_digestFormat.hasMatch(digest)) reader.fail('digest', 'a digest');
      restored.remove(digest);
      restored[digest] = reader.timestamp('first_seen_at');
    }
    _entries
      ..clear()
      ..addAll(restored);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  static final _digestFormat = RegExp(r'^[0-9a-f]{16}$');
}
