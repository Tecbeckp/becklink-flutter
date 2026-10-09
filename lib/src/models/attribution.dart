import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import 'attribution_state.dart';
import 'campaign.dart';
import 'confidence.dart';
import 'match_method.dart';

/// The install attribution result: which link, if any, brought this
/// install.
@immutable
final class Attribution {
  /// Creates an attribution result; [installedAt] is converted to UTC.
  Attribution({
    required this.state,
    required DateTime installedAt,
    this.matchMethod,
    this.confidence,
    this.linkId,
    this.campaign,
  }) : installedAt = installedAt.toUtc();

  /// Reads the SDK API JSON form (`attribution` in the contract).
  ///
  /// Unknown enum values map to the fallbacks documented on
  /// [AttributionState.fromWire], [MatchMethod.fromWire] and
  /// [Confidence.fromWire]. Throws a [FormatException] when a member is
  /// missing or has the wrong type.
  factory Attribution.fromJson(Map<String, Object?> json) =>
      readAttribution(JsonReader(json));

  /// The outcome.
  final AttributionState state;

  /// How the link was matched; `null` when no link matched.
  final MatchMethod? matchMethod;

  /// How sure the match is; `null` when no link matched.
  final Confidence? confidence;

  /// Public ID of the matched link; `null` when no link matched.
  final String? linkId;

  /// Campaign fields of the matched link at click time; `null` when no link
  /// matched or the link has none.
  final Campaign? campaign;

  /// When this install (for a reinstall: the reinstall) first opened the
  /// app. Always UTC.
  final DateTime installedAt;

  /// The SDK API JSON form (`attribution` in the contract).
  Map<String, Object?> toJson() => <String, Object?>{
        'state': state.wireValue,
        'match_method': matchMethod?.wireValue,
        'confidence': confidence?.wireValue,
        'link_id': linkId,
        'campaign': campaign?.toJson(),
        'installed_at': installedAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is Attribution &&
      other.state == state &&
      other.matchMethod == matchMethod &&
      other.confidence == confidence &&
      other.linkId == linkId &&
      other.campaign == campaign &&
      other.installedAt == installedAt;

  @override
  int get hashCode => Object.hash(
        state,
        matchMethod,
        confidence,
        linkId,
        campaign,
        installedAt,
      );

  @override
  String toString() => 'Attribution(state: ${state.wireValue}, '
      'matchMethod: ${matchMethod?.wireValue}, '
      'confidence: ${confidence?.wireValue}, linkId: $linkId, '
      'campaign: ${campaign?.name}, '
      'installedAt: ${installedAt.toIso8601String()})';
}

/// Reads an [Attribution] from [reader]. Internal to the SDK.
Attribution readAttribution(JsonReader reader) {
  final matchMethod = reader.optionalString('match_method');
  final confidence = reader.optionalString('confidence');
  final campaign = reader.optionalObject('campaign');
  return Attribution(
    state: AttributionState.fromWire(reader.string('state')),
    matchMethod: matchMethod == null ? null : MatchMethod.fromWire(matchMethod),
    confidence: confidence == null ? null : Confidence.fromWire(confidence),
    linkId: reader.optionalString('link_id'),
    campaign: campaign == null ? null : readCampaign(campaign),
    installedAt: reader.timestamp('installed_at'),
  );
}
