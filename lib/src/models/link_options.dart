import 'dart:convert';

import 'package:meta/meta.dart';

import '../json/json_value.dart';
import 'redaction.dart';

/// What a link created from the app with `BeckLink.instance.createLink()`
/// contains.
///
/// Links created from the app always use the project environment's link
/// domain, a generated short path and the project's default redirects: a
/// publishable key ships inside the app and is public, so it cannot choose
/// where a link leads.
///
/// The constructor checks every limit the device can check and throws an
/// [ArgumentError] for a value outside them. The service stays
/// authoritative: it can still refuse, for example, an unknown campaign key.
@immutable
final class LinkOptions {
  /// Creates link options.
  ///
  /// The UTM-style values ([source], [medium], [content], [term],
  /// [creative]) are trimmed; pass `null`, not an empty string, for "no
  /// value". [data] is copied into unmodifiable collections and [expiresAt]
  /// is converted to UTC.
  ///
  /// Throws an [ArgumentError] when [deepLinkPath], [data], [campaign] or a
  /// UTM-style value breaks the rules documented on its field.
  LinkOptions({
    required String deepLinkPath,
    Map<String, Object?> data = const <String, Object?>{},
    String? campaign,
    String? source,
    String? medium,
    String? content,
    String? term,
    String? creative,
    DateTime? expiresAt,
  })  : deepLinkPath = _checkDeepLinkPath(deepLinkPath),
        data = _checkData(data),
        campaign = _checkCampaign(campaign),
        source = _checkUtm(source, 'source'),
        medium = _checkUtm(medium, 'medium'),
        content = _checkUtm(content, 'content'),
        term = _checkUtm(term, 'term'),
        creative = _checkUtm(creative, 'creative'),
        expiresAt = expiresAt?.toUtc();

  /// Maximum length of [deepLinkPath], in characters (LNK-002).
  static const int maxDeepLinkPathLength = 2048;

  /// Maximum size of [data] as compact UTF-8 JSON, in bytes (LNK-001).
  static const int maxDataBytes = 4096;

  /// Maximum length of a key in [data], at every nesting level, in
  /// characters (LNK-002).
  static const int maxDataKeyLength = 64;

  /// Maximum length of each UTM-style value, in characters.
  static const int maxUtmLength = 255;

  static final _campaignKeyPattern =
      RegExp(r'^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$');

  // Mirrors the database rule: no whitespace (including Unicode spaces) and
  // no C0 or C1 control characters, which would break the URLs built from
  // the path.
  static final _whitespaceOrControl = RegExp(r'[\s\x00-\x1F\x7F-\x9F]');

  /// The in-app route the link opens, such as `/product/123`.
  ///
  /// Starts with `/`, at most [maxDeepLinkPathLength] characters, no
  /// whitespace or control characters; it may carry its own query string.
  final String deepLinkPath;

  /// Custom JSON data the app receives as `LinkEvent.data`.
  ///
  /// Values are `null`, [String], [bool], finite [num], [List] or [Map] with
  /// [String] keys. At most [maxDataBytes] bytes as compact UTF-8 JSON, and
  /// every key at most [maxDataKeyLength] characters. The service measures
  /// size in its own storage format, so data very close to the limit can
  /// still be refused. Link data is readable by anyone who has the link:
  /// never put secrets in it.
  final Map<String, Object?> data;

  /// Key of an existing, non-archived campaign of the project environment,
  /// such as `referral`, or `null` for none.
  ///
  /// Lower-case letters, digits, `-` and `_`, starting and ending with a
  /// letter or digit, at most 64 characters.
  final String? campaign;

  /// Where the traffic comes from (`utm_source`), such as `app`; overrides
  /// the campaign's value. At most [maxUtmLength] characters.
  final String? source;

  /// The marketing medium (`utm_medium`), such as `share`; overrides the
  /// campaign's value. At most [maxUtmLength] characters.
  final String? medium;

  /// Which content or placement was shared (`utm_content`); overrides the
  /// campaign's value. At most [maxUtmLength] characters.
  final String? content;

  /// The search term (`utm_term`); overrides the campaign's value. At most
  /// [maxUtmLength] characters.
  final String? term;

  /// The creative variant; overrides the campaign's value. At most
  /// [maxUtmLength] characters.
  final String? creative;

  /// When the link stops working, in UTC, or `null` for never.
  /// `createLink()` refuses a time that is not in the future.
  final DateTime? expiresAt;

  /// The SDK API JSON request body for `POST /v1/sdk/links`, without
  /// `install_id`, which the client adds.
  ///
  /// `utm` is `null` when no UTM-style value is set.
  Map<String, Object?> toJson() {
    final hasUtm = source != null ||
        medium != null ||
        content != null ||
        term != null ||
        creative != null;
    return <String, Object?>{
      'deep_link_path': deepLinkPath,
      'data': data,
      'campaign': campaign,
      'utm': hasUtm
          ? <String, Object?>{
              'source': source,
              'medium': medium,
              'content': content,
              'term': term,
              'creative': creative,
            }
          : null,
      'expires_at': expiresAt?.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is LinkOptions &&
      other.deepLinkPath == deepLinkPath &&
      jsonEquals(other.data, data) &&
      other.campaign == campaign &&
      other.source == source &&
      other.medium == medium &&
      other.content == content &&
      other.term == term &&
      other.creative == creative &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
        deepLinkPath,
        jsonHash(data),
        campaign,
        source,
        medium,
        content,
        term,
        creative,
        expiresAt,
      );

  /// A description for logs. The query string of [deepLinkPath] and the
  /// values of [data] are left out because they can carry user data.
  @override
  String toString() =>
      'LinkOptions(deepLinkPath: ${withoutQuery(deepLinkPath)}, '
      'data: ${data.length} keys, campaign: $campaign, source: $source, '
      'medium: $medium, content: $content, term: $term, creative: $creative, '
      'expiresAt: ${expiresAt?.toIso8601String()})';

  static String _checkDeepLinkPath(String path) {
    if (!path.startsWith('/')) {
      throw ArgumentError('must start with "/"', 'deepLinkPath');
    }
    if (path.runes.length > maxDeepLinkPathLength) {
      throw ArgumentError(
        'must be at most $maxDeepLinkPathLength characters',
        'deepLinkPath',
      );
    }
    if (_whitespaceOrControl.hasMatch(path)) {
      throw ArgumentError(
        'must not contain whitespace or control characters; '
            'percent-encode them',
        'deepLinkPath',
      );
    }
    return path;
  }

  static Map<String, Object?> _checkData(Map<String, Object?> data) {
    // jsonEncode runs first because it reports cycles instead of recursing
    // forever; isJsonValue then also rejects objects jsonEncode accepts
    // through a toJson() method, which the link would store in a different
    // shape than the app passed.
    final String encoded;
    try {
      encoded = jsonEncode(data);
    } on JsonUnsupportedObjectError {
      throw _notJson();
    }
    if (!isJsonValue(data)) throw _notJson();
    final bytes = utf8.encode(encoded).length;
    if (bytes > maxDataBytes) {
      throw ArgumentError(
        'must be at most $maxDataBytes bytes as compact UTF-8 JSON '
            '(is $bytes bytes)',
        'data',
      );
    }
    _checkDataKeys(data, '');
    return freezeJsonObject(data);
  }

  static ArgumentError _notJson() => ArgumentError(
        'must contain only JSON values: null, String, bool, finite num, '
            'List, and Map with String keys, without cycles',
        'data',
      );

  static void _checkDataKeys(Object? value, String pointer) {
    if (value is Map<Object?, Object?>) {
      for (final entry in value.entries) {
        final key = entry.key as String;
        final length = key.runes.length;
        if (length > maxDataKeyLength) {
          // Names the enclosing object and the length, not the key, which
          // could be user data.
          throw ArgumentError(
            'keys must be at most $maxDataKeyLength characters '
                '(a key in "${pointer.isEmpty ? '/' : pointer}" has $length)',
            'data',
          );
        }
        _checkDataKeys(
          entry.value,
          '$pointer/${key.replaceAll('~', '~0').replaceAll('/', '~1')}',
        );
      }
    } else if (value is List<Object?>) {
      for (var i = 0; i < value.length; i++) {
        _checkDataKeys(value[i], '$pointer/$i');
      }
    }
  }

  static String? _checkCampaign(String? campaign) {
    if (campaign == null || _campaignKeyPattern.hasMatch(campaign)) {
      return campaign;
    }
    throw ArgumentError(
      'must be a campaign key: lower-case letters, digits, "-" and "_", '
          'starting and ending with a letter or digit, at most 64 characters',
      'campaign',
    );
  }

  static String? _checkUtm(String? value, String name) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('must not be blank; pass null for no value', name);
    }
    if (trimmed.runes.length > maxUtmLength) {
      throw ArgumentError('must be at most $maxUtmLength characters', name);
    }
    return trimmed;
  }
}
