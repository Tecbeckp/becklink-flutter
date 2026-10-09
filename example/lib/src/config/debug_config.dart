import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/foundation.dart';

/// What the debug app was told to connect to, entered on the Configure
/// screen and kept on the device. Nothing here is compiled into the app.
@immutable
class DebugConfig {
  const DebugConfig({
    required this.apiBaseUrl,
    required this.apiKey,
    this.linkHosts = const <String>[],
    this.userId = '',
    this.enablePasteboard = true,
    this.logLevel = LogLevel.debug,
    this.openEveryLinkInDetail = true,
  });

  /// The production SDK API origin.
  static const String productionApiBaseUrl = 'https://api.becklinks.com';

  /// The defaults of a new install: production, no key yet.
  static const DebugConfig initial = DebugConfig(
    apiBaseUrl: productionApiBaseUrl,
    apiKey: '',
  );

  /// The SDK API (ingest) origin, for example `https://api.becklinks.com`,
  /// `http://192.168.1.20:4100` or an HTTPS tunnel to port 4100.
  final String apiBaseUrl;

  /// The project environment's publishable key, `pk_test_…` or `pk_live_…`.
  /// Public by design (it ships in apps), but still shown masked.
  final String apiKey;

  /// The link hosts to test, for example `myshop-test.becklinks.com`.
  final List<String> linkHosts;

  /// A user ID to set after initializing; empty clears it.
  final String userId;

  /// iOS: read the click URL a Beck Link page copied (opt-in pasteboard).
  final bool enablePasteboard;

  /// The SDK's log level.
  final LogLevel logLevel;

  /// Whether every incoming link opens the link detail screen, instead of
  /// the app's own routing (product, referral, home).
  final bool openEveryLinkInDetail;

  /// Whether enough is set to start the SDK.
  bool get isComplete => apiKey.trim().isNotEmpty && apiBaseUrl.isNotEmpty;

  /// [apiBaseUrl] parsed, or `null` when it is not a URL.
  Uri? get apiBaseUri {
    final uri = Uri.tryParse(apiBaseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }

  /// The origin of [apiBaseUrl] (scheme, host and port), or `null` when it
  /// is not an `http` or `https` URL.
  Uri? get apiOrigin {
    final uri = apiBaseUri;
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return Uri.parse(uri.origin);
  }

  /// Whether the SDK talks to production, so `configure()` gets no
  /// `apiBaseUrl`.
  bool get usesProduction => apiOrigin == Uri.parse(productionApiBaseUrl);

  /// `test` or `live` from the key prefix, or `null` for anything else.
  String? get keyEnvironment {
    final key = apiKey.trim();
    if (key.startsWith('pk_test_')) return 'test';
    if (key.startsWith('pk_live_')) return 'live';
    return null;
  }

  DebugConfig copyWith({
    String? apiBaseUrl,
    String? apiKey,
    List<String>? linkHosts,
    String? userId,
    bool? enablePasteboard,
    LogLevel? logLevel,
    bool? openEveryLinkInDetail,
  }) => DebugConfig(
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    apiKey: apiKey ?? this.apiKey,
    linkHosts: linkHosts ?? this.linkHosts,
    userId: userId ?? this.userId,
    enablePasteboard: enablePasteboard ?? this.enablePasteboard,
    logLevel: logLevel ?? this.logLevel,
    openEveryLinkInDetail: openEveryLinkInDetail ?? this.openEveryLinkInDetail,
  );

  /// The form kept on the device.
  Map<String, Object?> toStoredJson() => <String, Object?>{
    'api_base_url': apiBaseUrl,
    'api_key': apiKey,
    'link_hosts': linkHosts,
    'user_id': userId,
    'enable_pasteboard': enablePasteboard,
    'log_level': logLevel.wireValue,
    'open_every_link_in_detail': openEveryLinkInDetail,
  };

  /// Reads [toStoredJson]; missing or malformed members get the defaults.
  static DebugConfig fromStoredJson(Map<String, Object?> json) {
    String text(String key, String fallback) {
      final value = json[key];
      return value is String ? value : fallback;
    }

    bool flag(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    final hosts = json['link_hosts'];
    final level = json['log_level'];
    return DebugConfig(
      apiBaseUrl: text('api_base_url', initial.apiBaseUrl),
      apiKey: text('api_key', ''),
      linkHosts: hosts is List
          ? <String>[
              for (final host in hosts)
                if (host is String) host,
            ]
          : const <String>[],
      userId: text('user_id', ''),
      enablePasteboard: flag('enable_pasteboard', initial.enablePasteboard),
      logLevel: LogLevel.values.firstWhere(
        (candidate) => candidate.wireValue == level,
        orElse: () => initial.logLevel,
      ),
      openEveryLinkInDetail: flag(
        'open_every_link_in_detail',
        initial.openEveryLinkInDetail,
      ),
    );
  }

  /// For debug reports: the key and user ID masked.
  Map<String, Object?> toReportJson() => <String, Object?>{
    'api_base_url': apiBaseUrl,
    'api_key': maskSecret(apiKey),
    'key_environment': keyEnvironment,
    'link_hosts': linkHosts,
    'user_id': userId.isEmpty ? null : maskSecret(userId),
    'enable_pasteboard': enablePasteboard,
    'log_level': logLevel.wireValue,
  };

  @override
  bool operator ==(Object other) =>
      other is DebugConfig &&
      other.apiBaseUrl == apiBaseUrl &&
      other.apiKey == apiKey &&
      listEquals(other.linkHosts, linkHosts) &&
      other.userId == userId &&
      other.enablePasteboard == enablePasteboard &&
      other.logLevel == logLevel &&
      other.openEveryLinkInDetail == openEveryLinkInDetail;

  @override
  int get hashCode => Object.hash(
    apiBaseUrl,
    apiKey,
    Object.hashAll(linkHosts),
    userId,
    enablePasteboard,
    logLevel,
    openEveryLinkInDetail,
  );
}

/// [value] with only its prefix (up to the second `_`, as in `pk_test_`) and
/// last 4 characters visible, for screens and reports.
String maskSecret(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final prefixMatch = RegExp(r'^[a-z]+_[a-z]+_').firstMatch(trimmed);
  final prefix = prefixMatch?.group(0) ?? '';
  final rest = trimmed.substring(prefix.length);
  if (rest.length <= 4) return '$prefix…';
  return '$prefix…${rest.substring(rest.length - 4)}';
}

/// Splits link hosts typed with commas, spaces or new lines, lower case,
/// without a scheme or path.
List<String> parseLinkHosts(String text) {
  final hosts = <String>[];
  for (final raw in text.split(RegExp(r'[\s,]+'))) {
    var host = raw.trim().toLowerCase();
    if (host.isEmpty) continue;
    final uri = Uri.tryParse(host.contains('://') ? host : 'https://$host');
    host = uri?.host ?? host;
    if (host.isNotEmpty && !hosts.contains(host)) hosts.add(host);
  }
  return hosts;
}
