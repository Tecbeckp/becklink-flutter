/// Removes secrets and contact data from text before it is logged.
///
/// A safety net, not the primary guard: SDK code never puts the API key,
/// request bodies or user IDs into log messages in the first place (contract
/// section 12). This catches what slips through anyway, for example an
/// exception message from another library that echoes a header. Internal to
/// the SDK.
library;

// Beck Link keys keep their visible prefix (`pk_live_`), so a log still
// shows which kind of key was involved without revealing the key itself.
final _apiKey = RegExp(r'\b([ps]k_(?:test|live)_)\w+');
final _bearer = RegExp(r'\b(Bearer\s+)[^\s,;]+', caseSensitive: false);
final _email = RegExp(r'[\w.%+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}');

/// [text] with API keys, bearer tokens and email addresses replaced by
/// placeholders.
String redactSecrets(String text) => text
    .replaceAllMapped(_apiKey, (match) => '${match[1]}[redacted]')
    .replaceAllMapped(_bearer, (match) => '${match[1]}[redacted]')
    .replaceAll(_email, '[email]');
