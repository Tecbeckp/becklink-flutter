/// The outcome of install attribution.
///
/// [wireValue] is the snake_case form used by the Beck Link SDK API.
enum AttributionState {
  /// The first open was sent and the answer has not arrived yet. Set by the
  /// SDK only.
  pending('pending'),

  /// The install was credited to a link.
  attributed('attributed'),

  /// No link matched: an ordinary store install.
  organic('organic'),

  /// The app was installed again on a device that had it before. A reinstall
  /// can still carry the matched link's data, visible as a non-null
  /// `Attribution.linkId`.
  reinstall('reinstall'),

  /// No result is available, for example because tracking is disabled. Set
  /// by the SDK only.
  ///
  /// Also the result of [fromWire] for a value this SDK version does not
  /// know.
  unavailable('unavailable');

  const AttributionState(this.wireValue);

  /// The snake_case value used in SDK API JSON, for example `attributed`.
  final String wireValue;

  /// The state whose [wireValue] is [value].
  ///
  /// An unknown value maps to [unavailable] rather than claiming a result the
  /// SDK cannot interpret. The service never sends values an SDK version
  /// does not know, so this only guards against a contract violation.
  static AttributionState fromWire(String value) {
    for (final state in values) {
      if (state.wireValue == value) return state;
    }
    return unavailable;
  }
}
