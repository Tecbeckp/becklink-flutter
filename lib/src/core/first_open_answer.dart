import 'package:meta/meta.dart';

import '../json/json_reader.dart';
import '../models/attribution.dart';
import '../models/link_event.dart';
import '../models/remote_config.dart';
import '../util/single_line.dart';

/// The `200` answer of `POST /v1/sdk/first-open` (contract section 8.2).
/// Internal to the SDK.
@immutable
final class FirstOpenAnswer {
  /// Creates an answer.
  const FirstOpenAnswer({
    required this.linkEvent,
    required this.attribution,
    required this.unmatchedReason,
    required this.config,
  });

  /// The matched link: a direct open of `evidence.open_url`
  /// (`isDeferred == false`) or a deferred match; `null` when nothing
  /// matched.
  final LinkEvent? linkEvent;

  /// The install attribution.
  final Attribution attribution;

  /// Why nothing matched (contract section 9.5), shortened for logs, or
  /// `null` when a link matched.
  final String? unmatchedReason;

  /// The remote config at the time of the answer.
  final RemoteConfig config;

  /// The form `SdkStateStore.completeFirstOpen` keeps: the answer without
  /// `config`, which is cached on its own.
  Map<String, Object?> toStoredJson() => <String, Object?>{
        'matched': linkEvent != null,
        'link_event': linkEvent?.toJson(),
        'attribution': attribution.toJson(),
        'unmatched_reason': unmatchedReason,
      };
}

/// Longest `unmatched_reason` kept; known values are far shorter.
const int _maxReasonLength = 64;

/// Reads a first-open answer; throws a `MalformedJsonException` when a
/// member has the wrong shape.
///
/// `matched` is not trusted on its own: the contract defines it as "true
/// exactly when `link_event` is not null", so [FirstOpenAnswer.linkEvent]
/// alone decides.
FirstOpenAnswer readFirstOpenAnswer(JsonReader reader) {
  final linkEvent = reader.optionalObject('link_event');
  final reason = reader.optionalString('unmatched_reason');
  return FirstOpenAnswer(
    linkEvent: linkEvent == null ? null : readLinkEvent(linkEvent),
    attribution: readAttribution(reader.object('attribution')),
    unmatchedReason:
        reason == null ? null : singleLine(reason, maxLength: _maxReasonLength),
    config: readRemoteConfig(reader.object('config')),
  );
}

/// The attribution of a stored first-open answer (the `result` of a
/// completed first-open record); throws a `FormatException` when it is
/// malformed.
Attribution readStoredAttribution(Map<String, Object?> result) =>
    readAttribution(JsonReader(result).object('attribution'));
