import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'debug_config.dart';

/// Keeps the [DebugConfig] on the device (shared_preferences), so the app
/// starts the SDK with it on every launch.
class ConfigStore {
  ConfigStore._(this._preferences);

  static const String _key = 'becklink_debug_config_v1';

  final SharedPreferencesAsync _preferences;

  static Future<ConfigStore> open() async =>
      ConfigStore._(SharedPreferencesAsync());

  /// The saved configuration, or `null` when none was saved or it cannot
  /// be read.
  Future<DebugConfig?> load() async {
    try {
      final text = await _preferences.getString(_key);
      if (text == null) return null;
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      return DebugConfig.fromStoredJson(json);
    } on Exception {
      return null;
    }
  }

  Future<void> save(DebugConfig config) =>
      _preferences.setString(_key, jsonEncode(config.toStoredJson()));

  Future<void> clear() => _preferences.remove(_key);
}
