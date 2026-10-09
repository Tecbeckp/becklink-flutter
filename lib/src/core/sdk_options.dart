import 'package:meta/meta.dart';

import '../http/api_client.dart';
import '../models/becklink_exception.dart';
import '../models/log_level.dart';

/// The project environment a publishable key belongs to. The key alone
/// decides it (contract section 3); it selects which link hosts the SDK
/// accepts (contract section 9.1).
enum SdkEnvironment {
  /// `pk_test_…`: links on `{slug}-test.becklinks.com`.
  test,

  /// `pk_live_…`: links on `{slug}.becklinks.com`.
  live,
}

/// What `BeckLink.configure()` was called with, after validation. Internal
/// to the SDK.
@immutable
final class SdkOptions {
  /// Creates options from already validated values; use [SdkOptions.parse]
  /// for values from the app.
  const SdkOptions({
    required this.apiKey,
    required this.environment,
    required this.logLevel,
    required this.enablePasteboard,
    required this.firstOpenTimeout,
    this.apiBaseUrl,
    this.handlePlatformLinks = true,
  });

  /// Validates the arguments of `configure()` and returns the options.
  ///
  /// Throws a `BeckLinkException` with code `invalid_key` when [apiKey] is
  /// not a publishable key (see [parsePublishableKey]), and an
  /// [ArgumentError] when [firstOpenTimeout] is negative or longer than
  /// [maxFirstOpenTimeout], or [apiBaseUrl] is not an origin the SDK may
  /// use (see `ApiClient.checkBaseUrl`; [allowPrivateNetworkHttp] in debug
  /// builds only).
  factory SdkOptions.parse({
    required String apiKey,
    required LogLevel logLevel,
    required bool enablePasteboard,
    required Duration firstOpenTimeout,
    Uri? apiBaseUrl,
    bool handlePlatformLinks = true,
    bool allowPrivateNetworkHttp = false,
  }) {
    final environment = parsePublishableKey(apiKey);
    if (apiBaseUrl != null) {
      ApiClient.checkBaseUrl(
        apiBaseUrl,
        allowPrivateNetworkHttp: allowPrivateNetworkHttp,
      );
    }
    if (firstOpenTimeout.isNegative || firstOpenTimeout > maxFirstOpenTimeout) {
      throw ArgumentError.value(
        firstOpenTimeout,
        'firstOpenTimeout',
        'must be between zero and ${maxFirstOpenTimeout.inSeconds} seconds',
      );
    }
    return SdkOptions(
      apiKey: apiKey,
      environment: environment,
      logLevel: logLevel,
      enablePasteboard: enablePasteboard,
      firstOpenTimeout: firstOpenTimeout,
      apiBaseUrl: apiBaseUrl,
      handlePlatformLinks: handlePlatformLinks,
    );
  }

  /// Longest `firstOpenTimeout` accepted. Above it the app would wait on a
  /// launch screen longer than any user does; the first open itself keeps
  /// retrying in the background whatever the timeout.
  static const Duration maxFirstOpenTimeout = Duration(seconds: 30);

  /// The publishable key. Never logged and never put into messages.
  final String apiKey;

  /// The environment of [apiKey].
  final SdkEnvironment environment;

  /// The log level the app asked for; remote config can override it
  /// (contract section 7.5).
  final LogLevel logLevel;

  /// Whether the app opted in to the iOS pasteboard deferred link (IOS-005).
  final bool enablePasteboard;

  /// How long the app waits for a link to be resolved: the first-open answer
  /// on the first run (§13) and the `/v1/sdk/open` answer for a link that
  /// opened the app. Measured from when the request is sent.
  final Duration firstOpenTimeout;

  /// The SDK API origin, or `null` for production
  /// (`https://api.becklinks.com`).
  final Uri? apiBaseUrl;

  /// Whether the SDK reads the launch link and the links opened while the
  /// app runs from the native layer. When `false`, the app forwards every
  /// URL with `BeckLink.handleUri`.
  final bool handlePlatformLinks;

  @override
  bool operator ==(Object other) =>
      other is SdkOptions &&
      other.apiKey == apiKey &&
      other.environment == environment &&
      other.logLevel == logLevel &&
      other.enablePasteboard == enablePasteboard &&
      other.firstOpenTimeout == firstOpenTimeout &&
      other.apiBaseUrl == apiBaseUrl &&
      other.handlePlatformLinks == handlePlatformLinks;

  @override
  int get hashCode => Object.hash(
        apiKey,
        environment,
        logLevel,
        enablePasteboard,
        firstOpenTimeout,
        apiBaseUrl,
        handlePlatformLinks,
      );

  // The key is a credential; only its environment is shown.
  @override
  String toString() => 'SdkOptions(environment: ${environment.name}, '
      'logLevel: ${logLevel.wireValue}, enablePasteboard: $enablePasteboard, '
      'firstOpenTimeout: ${firstOpenTimeout.inMilliseconds} ms'
      '${apiBaseUrl == null ? '' : ', apiBaseUrl: $apiBaseUrl'}'
      '${handlePlatformLinks ? '' : ', handlePlatformLinks: false'})';
}

// `pk_test_` or `pk_live_` and a body in the characters every common key
// generator uses (base62, base64url). The service stays authoritative and
// answers 401 for a well-formed but unknown key.
final _publishableKey = RegExp(r'^pk_(test|live)_[A-Za-z0-9_-]{8,256}$');

/// The environment of the publishable key [apiKey] (contract section 3).
///
/// Throws a `BeckLinkException` with code `invalid_key` when [apiKey] is not
/// of the form `pk_test_…` or `pk_live_…`. A secret key (`sk_…`) gets its own
/// message: it must never ship inside an app, so the SDK refuses it before
/// anything is sent. Messages never contain the key.
SdkEnvironment parsePublishableKey(String apiKey) {
  if (apiKey.trimLeft().toLowerCase().startsWith('sk_')) {
    throw const BeckLinkException.invalidKey(
      message: 'configure() was given a secret key (sk_…). Secret keys are '
          'for servers only and must never ship inside an app; use the '
          'publishable key (pk_test_… or pk_live_…) of your project '
          'environment, and revoke the secret key if it was ever part of an '
          'app build.',
    );
  }
  final match = _publishableKey.firstMatch(apiKey);
  if (match == null) {
    throw const BeckLinkException.invalidKey(
      message: 'configure() needs a publishable key of the form pk_test_… or '
          'pk_live_…, as shown with your project\'s API keys in the Beck '
          'Link dashboard.',
    );
  }
  return match[1] == 'live' ? SdkEnvironment.live : SdkEnvironment.test;
}
