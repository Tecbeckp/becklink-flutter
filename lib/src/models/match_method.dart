/// How a link was matched to an app open or an install.
///
/// [wireValue] is the snake_case form used by the Beck Link SDK API.
enum MatchMethod {
  /// iOS opened the app directly from an `https` link URL (Universal Link).
  universalLink('universal_link'),

  /// Android opened the app directly from an `https` link URL (App Link).
  appLink('app_link'),

  /// The app was opened through its custom URI scheme, for example from the
  /// "Open in app" button of a redirect page.
  uriScheme('uri_scheme'),

  /// Deferred match on Android through the Play Install Referrer.
  installReferrer('install_referrer'),

  /// Deferred match on iOS through the opt-in pasteboard token.
  pasteboard('pasteboard'),

  /// Reserved for advertising-identifier matching. Beck Link does not
  /// collect the IDFA, so the service never reports this value today.
  idfa('idfa'),

  /// Reserved for probabilistic matching. Beck Link does not fingerprint
  /// devices, so the service never reports this value today.
  ///
  /// Also the result of [fromWire] for a value this SDK version does not
  /// know.
  probabilistic('probabilistic');

  const MatchMethod(this.wireValue);

  /// The snake_case value used in SDK API JSON, for example
  /// `universal_link`.
  final String wireValue;

  /// The method whose [wireValue] is [value].
  ///
  /// An unknown value maps to [probabilistic], the weakest kind of evidence,
  /// so an app that only trusts deterministic methods fails closed. The
  /// service never sends values an SDK version does not know, so this only
  /// guards against a contract violation.
  static MatchMethod fromWire(String value) {
    for (final method in values) {
      if (method.wireValue == value) return method;
    }
    return probabilistic;
  }
}
