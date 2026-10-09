import 'package:meta/meta.dart';

import '../json/json_reader.dart';

/// Campaign and UTM-style fields of a link.
///
/// Each value is the effective one: the link's own value, otherwise its
/// campaign's. For a deferred match they are the values at click time.
/// Every field is `null` when unset, never an empty string.
@immutable
final class Campaign {
  /// Creates campaign fields.
  const Campaign({
    this.name,
    this.source,
    this.medium,
    this.content,
    this.term,
    this.creative,
  });

  /// Reads the SDK API JSON form, an object with the six snake_case keys.
  ///
  /// Throws a [FormatException] when a member is not a string or `null`.
  factory Campaign.fromJson(Map<String, Object?> json) =>
      readCampaign(JsonReader(json));

  /// The campaign's name; `null` for links without a campaign.
  final String? name;

  /// Where the traffic comes from (`utm_source`), for example `newsletter`.
  final String? source;

  /// The marketing medium (`utm_medium`), for example `email`.
  final String? medium;

  /// Which content or placement was clicked (`utm_content`).
  final String? content;

  /// The paid search term (`utm_term`).
  final String? term;

  /// The creative variant, for example `blue_v2`.
  final String? creative;

  /// The SDK API JSON form, with all six keys.
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'source': source,
        'medium': medium,
        'content': content,
        'term': term,
        'creative': creative,
      };

  @override
  bool operator ==(Object other) =>
      other is Campaign &&
      other.name == name &&
      other.source == source &&
      other.medium == medium &&
      other.content == content &&
      other.term == term &&
      other.creative == creative;

  @override
  int get hashCode =>
      Object.hash(name, source, medium, content, term, creative);

  @override
  String toString() => 'Campaign(name: $name, source: $source, '
      'medium: $medium, content: $content, term: $term, creative: $creative)';
}

/// Reads a [Campaign] from [reader]. Internal to the SDK.
Campaign readCampaign(JsonReader reader) => Campaign(
      name: reader.optionalString('name'),
      source: reader.optionalString('source'),
      medium: reader.optionalString('medium'),
      content: reader.optionalString('content'),
      term: reader.optionalString('term'),
      creative: reader.optionalString('creative'),
    );
