import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../json/json_value.dart';
import 'campaign.dart';
import 'confidence.dart';
import 'match_method.dart';
import 'redaction.dart';

/// A link that opened the app, directly or after install (deferred).
///
/// Treat [path], [params] and [data] as untrusted input when routing: anyone
/// can craft a link URL, and link data is readable by anyone who has the
/// link and the app's publishable key, so it never holds secrets.
@immutable
final class LinkEvent {
  /// Creates a link event.
  ///
  /// [params] and [data] are copied into unmodifiable collections and
  /// [clickedAt] is converted to UTC. Throws an [ArgumentError] when [data]
  /// holds a value that is not JSON (see [data]).
  LinkEvent({
    required this.url,
    required this.path,
    required this.isDeferred,
    required this.matchMethod,
    required this.confidence,
    required DateTime clickedAt,
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> data = const <String, Object?>{},
    this.linkId,
    this.campaign,
  })  : params = Map<String, String>.unmodifiable(params),
        data = _checkData(data),
        clickedAt = clickedAt.toUtc();

  /// Reads the SDK API JSON form (`link_event` in the contract).
  ///
  /// Unknown `match_method` and `confidence` values map to the fallbacks
  /// documented on [MatchMethod.fromWire] and [Confidence.fromWire]. Throws a
  /// [FormatException] when a member is missing or has the wrong type.
  factory LinkEvent.fromJson(Map<String, Object?> json) =>
      readLinkEvent(JsonReader(json));

  /// For a direct open, the URL exactly as the app received it; for a
  /// deferred match, the URL of the clicked link.
  final Uri url;

  /// The link's deep-link path, the in-app route such as `/product/123`. It
  /// may carry its own query string.
  final String path;

  /// Query parameters of the link URL. For a deferred match, the click's
  /// pass-through parameters when the link allows them, otherwise empty.
  /// For a repeated key the last value wins.
  final Map<String, String> params;

  /// The link's custom JSON data (at most 4 KB); empty when the link has
  /// none.
  ///
  /// Values are `null`, [String], [bool], [num], [List] or [Map] with
  /// [String] keys, unmodifiable at every level.
  final Map<String, Object?> data;

  /// Whether the link was matched after install (deferred) rather than
  /// opening the installed app directly.
  final bool isDeferred;

  /// How the link was matched.
  final MatchMethod matchMethod;

  /// How sure the match is.
  final Confidence confidence;

  /// Public ID of the link. `null` only for an event the SDK built on the
  /// device because the service could not be reached; such an event has
  /// empty [data] and no [campaign].
  final String? linkId;

  /// The link's campaign fields, or `null` when it has none.
  final Campaign? campaign;

  /// For a deferred match, when the link was clicked; for a direct open,
  /// when the app received the URL. Always UTC.
  final DateTime clickedAt;

  /// The SDK API JSON form (`link_event` in the contract).
  Map<String, Object?> toJson() => <String, Object?>{
        'url': url.toString(),
        'path': path,
        'params': params,
        'data': data,
        'is_deferred': isDeferred,
        'match_method': matchMethod.wireValue,
        'confidence': confidence.wireValue,
        'link_id': linkId,
        'campaign': campaign?.toJson(),
        'clicked_at': clickedAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is LinkEvent &&
      other.url == url &&
      other.path == path &&
      jsonEquals(other.params, params) &&
      jsonEquals(other.data, data) &&
      other.isDeferred == isDeferred &&
      other.matchMethod == matchMethod &&
      other.confidence == confidence &&
      other.linkId == linkId &&
      other.campaign == campaign &&
      other.clickedAt == clickedAt;

  @override
  int get hashCode => Object.hash(
        url,
        path,
        jsonHash(params),
        jsonHash(data),
        isDeferred,
        matchMethod,
        confidence,
        linkId,
        campaign,
        clickedAt,
      );

  /// A description for logs. Query strings and the values of [params] and
  /// [data] are left out because they can carry user data.
  @override
  String toString() => 'LinkEvent(url: ${describeUri(url)}, '
      'path: ${withoutQuery(path)}, params: ${params.length} keys, '
      'data: ${data.length} keys, isDeferred: $isDeferred, '
      'matchMethod: ${matchMethod.wireValue}, '
      'confidence: ${confidence.wireValue}, linkId: $linkId, '
      'campaign: ${campaign?.name}, '
      'clickedAt: ${clickedAt.toIso8601String()})';

  static Map<String, Object?> _checkData(Map<String, Object?> data) {
    if (!isJsonValue(data)) {
      throw ArgumentError(
        'must contain only JSON values: null, String, bool, finite num, '
            'List, and Map with String keys',
        'data',
      );
    }
    return freezeJsonObject(data);
  }
}

/// Reads a [LinkEvent] from [reader]. Internal to the SDK.
LinkEvent readLinkEvent(JsonReader reader) {
  final campaign = reader.optionalObject('campaign');
  return LinkEvent(
    url: reader.uri('url'),
    path: reader.string('path'),
    params: reader.stringMap('params'),
    data: reader.jsonObject('data'),
    isDeferred: reader.boolean('is_deferred'),
    matchMethod: MatchMethod.fromWire(reader.string('match_method')),
    confidence: Confidence.fromWire(reader.string('confidence')),
    linkId: reader.optionalString('link_id'),
    campaign: campaign == null ? null : readCampaign(campaign),
    clickedAt: reader.timestamp('clicked_at'),
  );
}
