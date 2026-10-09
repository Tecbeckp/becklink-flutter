/// How starting the SDK went when the app launched.
sealed class SdkSetup {
  const SdkSetup();
}

/// No configuration was entered yet (Configure screen, or
/// `--dart-define=BECKLINK_KEY=…` at build time), so the SDK was not
/// started.
final class SdkKeyMissing extends SdkSetup {
  const SdkKeyMissing();
}

/// `configure()` accepted the key.
final class SdkConfigured extends SdkSetup {
  const SdkConfigured({required this.environment});

  /// The setup for [apiKey], which `configure()` accepted, so it starts with
  /// `pk_test_` or `pk_live_`.
  factory SdkConfigured.forKey(String apiKey) => SdkConfigured(
    environment: apiKey.startsWith('pk_live_') ? 'live' : 'test',
  );

  /// The project environment the key belongs to: `test` or `live`. Only
  /// links of this environment reach the app.
  final String environment;
}

/// `configure()` refused the key; [message] says why.
final class SdkSetupFailed extends SdkSetup {
  const SdkSetupFailed(this.message);

  final String message;
}
