import 'debug_config.dart';

/// How serious a [ConfigIssue] is.
enum IssueSeverity {
  /// The SDK will refuse the configuration.
  error,

  /// It works, but only in a debug build or not the way it is probably meant.
  warning,

  /// Good to know.
  info,
}

/// A problem with a [DebugConfig], shown on the Configure screen.
class ConfigIssue {
  const ConfigIssue(this.severity, this.message);

  final IssueSeverity severity;
  final String message;
}

const Set<String> _thisMachine = <String>{
  'localhost',
  '127.0.0.1',
  '::1',
  '10.0.2.2',
};

/// Whether [host] is a private network address the SDK accepts over plain
/// HTTP in debug builds (the same rule as the SDK's `checkBaseUrl`).
bool isPrivateNetworkHost(String host) {
  if (host.endsWith('.local') && host.length > '.local'.length) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  final a = octets[0];
  final b = octets[1];
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// The environment of a platform link host, `test` for
/// `{slug}-test.becklinks.com`, `live` for `{slug}.becklinks.com`, `null` for
/// a custom domain.
String? platformHostEnvironment(String host) {
  const suffix = '.becklinks.com';
  if (!host.endsWith(suffix)) return null;
  final label = host.substring(0, host.length - suffix.length);
  if (label.isEmpty || label.contains('.')) return null;
  return label.endsWith('-test') ? 'test' : 'live';
}

/// Everything worth telling the owner about [config] before it is applied.
List<ConfigIssue> checkConfig(DebugConfig config) {
  final issues = <ConfigIssue>[];
  final key = config.apiKey.trim();
  if (key.isEmpty) {
    issues.add(
      const ConfigIssue(
        IssueSeverity.error,
        'Enter the publishable key of your project environment (dashboard: '
        'project, API keys).',
      ),
    );
  } else if (key.toLowerCase().startsWith('sk_')) {
    issues.add(
      const ConfigIssue(
        IssueSeverity.error,
        'This is a secret key. Secret keys must never be put into an app; '
        'use the publishable key (pk_test_… or pk_live_…) and revoke this '
        'secret key if it was shared.',
      ),
    );
  } else if (config.keyEnvironment == null) {
    issues.add(
      const ConfigIssue(
        IssueSeverity.error,
        'A publishable key starts with pk_test_ or pk_live_.',
      ),
    );
  }

  final uri = config.apiBaseUri;
  if (uri == null) {
    issues.add(
      const ConfigIssue(
        IssueSeverity.error,
        'The API base URL must look like https://api.becklinks.com or '
        'http://192.168.1.20:4100.',
      ),
    );
  } else {
    if (uri.path.isNotEmpty && uri.path != '/' ||
        uri.hasQuery ||
        uri.hasFragment) {
      issues.add(
        const ConfigIssue(
          IssueSeverity.error,
          'Use the origin only (scheme, host and port), without a path such '
          'as /v1.',
        ),
      );
    }
    final host = uri.host.toLowerCase();
    if (uri.scheme == 'http') {
      if (_thisMachine.contains(host)) {
        issues.add(
          ConfigIssue(
            IssueSeverity.warning,
            host == '10.0.2.2'
                ? 'Plain HTTP to the computer running the Android emulator. '
                      'Fine for local development.'
                : 'Plain HTTP to "$host" means this phone itself. On a real '
                      'phone run "adb reverse tcp:${uri.port} '
                      'tcp:${uri.port}" so it reaches your computer.',
          ),
        );
      } else if (isPrivateNetworkHost(host)) {
        issues.add(
          const ConfigIssue(
            IssueSeverity.warning,
            'Plain HTTP (cleartext) to your local network: accepted only by '
            'debug builds of the SDK and this app. On iOS it needs the Local '
            'Network permission; prefer an HTTPS tunnel there.',
          ),
        );
      } else {
        issues.add(
          const ConfigIssue(
            IssueSeverity.error,
            'The SDK sends plain HTTP only to this phone, the emulator host '
            '(10.0.2.2) or a private network address (192.168.x.x, 10.x.x.x, '
            '172.16–31.x.x). Use https:// for anything else.',
          ),
        );
      }
    } else if (uri.scheme != 'https') {
      issues.add(
        const ConfigIssue(
          IssueSeverity.error,
          'The API base URL must start with https:// or http://.',
        ),
      );
    }
  }

  final environment = config.keyEnvironment;
  if (config.linkHosts.isEmpty) {
    issues.add(
      const ConfigIssue(
        IssueSeverity.info,
        'Add the link host you test (for example myshop-test.becklinks.com) '
        'to get ready-made test URLs.',
      ),
    );
  }
  for (final host in config.linkHosts) {
    final hostEnvironment = platformHostEnvironment(host);
    if (hostEnvironment == null) {
      issues.add(
        ConfigIssue(
          IssueSeverity.info,
          '$host is a custom domain: the SDK accepts its links only after '
          'the service listed it in the remote config (link_hosts).',
        ),
      );
    } else if (environment != null && hostEnvironment != environment) {
      issues.add(
        ConfigIssue(
          IssueSeverity.warning,
          '$host is a $hostEnvironment link host but the key is a '
          '$environment key: the SDK ignores links of the other environment.',
        ),
      );
    }
  }
  return issues;
}

/// Whether [issues] allow applying the configuration.
bool canApply(List<ConfigIssue> issues) =>
    issues.every((issue) => issue.severity != IssueSeverity.error);
