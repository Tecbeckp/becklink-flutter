import 'dart:convert';

import 'package:meta/meta.dart';

/// A custom event the app passed to `track()`, checked against the SDK API
/// contract (section 8.4, §17) before it is queued. Internal to the SDK.
@immutable
final class EventInput {
  const EventInput._({
    required this.name,
    required this.properties,
    required this.revenue,
    required this.currency,
  });

  /// The event name, such as `purchase`.
  final String name;

  /// Flat properties without `null` values, or `null` when none are left.
  final Map<String, Object?>? properties;

  /// Revenue amount, or `null`.
  final num? revenue;

  /// Upper-case ISO 4217 code of [revenue], or `null`.
  final String? currency;
}

/// Most properties per event (§17).
const int maxEventProperties = 50;

/// Largest properties object, as compact UTF-8 JSON (§17, contract 8.4).
const int maxEventPropertiesBytes = 8 * 1024;

/// Longest property key, in characters (contract 8.4).
const int maxEventPropertyKeyLength = 64;

/// Largest revenue magnitude the service stores (contract 8.4).
const num maxEventRevenue = 1000000000;

final _eventName = RegExp(r'^[a-z0-9_]{1,64}$');
final _currencyCode = RegExp(r'^[A-Za-z]{3}$');
final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

/// Checks the arguments of `track()` and returns the event to queue.
///
/// Rules (contract section 8.4): [name] matches `^[a-z0-9_]{1,64}$`;
/// [properties] is flat, `null` values are dropped, and what is left has at
/// most [maxEventProperties] keys of 1–[maxEventPropertyKeyLength] characters
/// without control characters, values that are a [String], a [bool] or a
/// finite [num], and at most [maxEventPropertiesBytes] bytes as compact UTF-8
/// JSON; [revenue] is finite, within ±[maxEventRevenue] and comes with
/// [currency], a three-letter ISO 4217 code (any case, sent upper case),
/// which is not allowed without [revenue].
///
/// Throws an [ArgumentError] for a value outside these rules. Messages name
/// the rule, never a property key or value, which can be user data.
EventInput checkEventInput(
  String name, {
  Map<String, Object?>? properties,
  num? revenue,
  String? currency,
}) {
  if (!_eventName.hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'name',
      'must be 1 to 64 lower-case letters, digits or "_"',
    );
  }
  return EventInput._(
    name: name,
    properties: properties == null ? null : _checkProperties(properties),
    revenue: _checkRevenue(revenue, currency),
    currency: _checkCurrency(currency, revenue),
  );
}

Map<String, Object?>? _checkProperties(Map<String, Object?> properties) {
  final kept = <String, Object?>{};
  for (final entry in properties.entries) {
    final value = entry.value;
    if (value == null) continue;
    final key = entry.key;
    final length = key.runes.length;
    if (length == 0 || length > maxEventPropertyKeyLength) {
      throw ArgumentError(
        'keys must be 1 to $maxEventPropertyKeyLength characters (one has '
            '$length)',
        'properties',
      );
    }
    if (_controlCharacters.hasMatch(key)) {
      throw ArgumentError(
        'keys must not contain control characters',
        'properties',
      );
    }
    if (value is num) {
      if (!value.isFinite) {
        throw ArgumentError(
          'number values must be finite (not NaN or infinity)',
          'properties',
        );
      }
    } else if (value is! String && value is! bool) {
      throw ArgumentError(
        'values must be a String, a bool or a num; nested maps and lists are '
            'not allowed (found ${value.runtimeType})',
        'properties',
      );
    }
    kept[key] = value;
  }
  if (kept.length > maxEventProperties) {
    throw ArgumentError(
      'must have at most $maxEventProperties keys with a non-null value '
          '(has ${kept.length})',
      'properties',
    );
  }
  if (kept.isEmpty) return null;
  final bytes = utf8.encode(jsonEncode(kept)).length;
  if (bytes > maxEventPropertiesBytes) {
    throw ArgumentError(
      'must be at most $maxEventPropertiesBytes bytes as compact UTF-8 JSON '
          '(is $bytes bytes)',
      'properties',
    );
  }
  return Map<String, Object?>.unmodifiable(kept);
}

num? _checkRevenue(num? revenue, String? currency) {
  if (revenue == null) return null;
  if (!revenue.isFinite || revenue.abs() > maxEventRevenue) {
    throw ArgumentError.value(
      revenue,
      'revenue',
      'must be a finite number between -$maxEventRevenue and '
          '$maxEventRevenue',
    );
  }
  if (currency == null) {
    throw ArgumentError(
      'needs a currency (ISO 4217 code such as "USD")',
      'revenue',
    );
  }
  return revenue;
}

String? _checkCurrency(String? currency, num? revenue) {
  if (currency == null) return null;
  if (!_currencyCode.hasMatch(currency)) {
    throw ArgumentError.value(
      currency,
      'currency',
      'must be a three-letter ISO 4217 code such as "USD"',
    );
  }
  if (revenue == null) {
    throw ArgumentError(
      'is only allowed together with revenue',
      'currency',
    );
  }
  return currency.toUpperCase();
}
