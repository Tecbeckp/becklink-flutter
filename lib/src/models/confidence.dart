/// How sure Beck Link is that a match is correct.
///
/// [wireValue] is the snake_case form used by the Beck Link SDK API.
enum Confidence {
  /// The match is deterministic: the link or click was identified exactly.
  /// Every method Beck Link uses today is certain.
  certain('certain'),

  /// The match is a best guess. Reserved for methods Beck Link does not use
  /// today.
  ///
  /// Also the result of [fromWire] for a value this SDK version does not
  /// know.
  low('low');

  const Confidence(this.wireValue);

  /// The snake_case value used in SDK API JSON, for example `certain`.
  final String wireValue;

  /// The confidence whose [wireValue] is [value].
  ///
  /// An unknown value maps to [low], so an app that acts only on certain
  /// matches fails closed. The service never sends values an SDK version does
  /// not know, so this only guards against a contract violation.
  static Confidence fromWire(String value) {
    for (final confidence in values) {
      if (confidence.wireValue == value) return confidence;
    }
    return low;
  }
}
