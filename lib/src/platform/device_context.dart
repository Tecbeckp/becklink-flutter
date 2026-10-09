import 'package:meta/meta.dart';

/// App and device details for the `context` object of SDK API requests
/// (contract section 7.1), as the native layer reports them, cut to the
/// contract's limits.
///
/// Holds no identifier of the device or the user: no IDFA, GAID, IDFV,
/// ANDROID_ID or user-chosen device name (contract section 12, §54.6).
/// Context is analytics data only and never used for matching. Internal to
/// the SDK.
@immutable
final class DeviceContext {
  /// Creates a context. The values must already fit the limits below;
  /// [readDeviceContext] enforces them for native answers.
  const DeviceContext({
    required this.osVersion,
    required this.appVersion,
    this.appBuild,
    this.deviceModel,
    this.locale,
  });

  /// Stand-in for a required member the native layer could not report; the
  /// SDK API requires both [osVersion] and [appVersion].
  static const String unknownValue = 'unknown';

  /// The context used when the native layer cannot report one (plugin not
  /// registered, no answer in time).
  static const DeviceContext unknown = DeviceContext(
    osVersion: unknownValue,
    appVersion: unknownValue,
  );

  /// Longest [osVersion], in characters (contract section 7.1).
  static const int maxOsVersionLength = 32;

  /// Longest [appVersion], in characters.
  static const int maxAppVersionLength = 64;

  /// Longest [appBuild], in characters.
  static const int maxAppBuildLength = 32;

  /// Longest [deviceModel], in characters.
  static const int maxDeviceModelLength = 64;

  /// Longest [locale], in characters.
  static const int maxLocaleLength = 35;

  /// Operating system version, for example `18.6` or `15`.
  final String osVersion;

  /// The app's version: iOS `CFBundleShortVersionString`, Android
  /// `versionName`.
  final String appVersion;

  /// The app's build: iOS `CFBundleVersion`, Android `versionCode`.
  final String? appBuild;

  /// Hardware model such as `iPhone16,2` or `Pixel 8`.
  final String? deviceModel;

  /// The user's preferred language as a BCP 47 tag, for example `en-US`.
  final String? locale;

  /// The members of the contract's `context` object this class holds; the
  /// caller adds `platform`, which Dart knows itself.
  Map<String, Object?> toJson() => <String, Object?>{
        'os_version': osVersion,
        'app_version': appVersion,
        'app_build': appBuild,
        'device_model': deviceModel,
        'locale': locale,
      };

  @override
  bool operator ==(Object other) =>
      other is DeviceContext &&
      other.osVersion == osVersion &&
      other.appVersion == appVersion &&
      other.appBuild == appBuild &&
      other.deviceModel == deviceModel &&
      other.locale == locale;

  @override
  int get hashCode =>
      Object.hash(osVersion, appVersion, appBuild, deviceModel, locale);

  @override
  String toString() => 'DeviceContext(osVersion: $osVersion, '
      'appVersion: $appVersion, appBuild: $appBuild, '
      'deviceModel: $deviceModel, locale: $locale)';
}

/// Reads the native answer to `getDeviceContext` (see
/// `doc/platform-channel.md`), or returns `null` when it is not a map.
///
/// Values are cleaned so a request is never refused over its context:
/// control characters removed, whitespace trimmed, cut to the contract's
/// length in Unicode code points; an empty or non-string optional member
/// becomes `null` and a missing required one [DeviceContext.unknownValue].
/// A locale that is not a BCP 47 tag becomes `null` (`_` is accepted as
/// `-`).
DeviceContext? readDeviceContext(Object? payload) {
  if (payload is! Map<Object?, Object?>) return null;
  return DeviceContext(
    osVersion: _text(payload['os_version'], DeviceContext.maxOsVersionLength) ??
        DeviceContext.unknownValue,
    appVersion:
        _text(payload['app_version'], DeviceContext.maxAppVersionLength) ??
            DeviceContext.unknownValue,
    appBuild: _text(payload['app_build'], DeviceContext.maxAppBuildLength),
    deviceModel: _text(
      payload['device_model'],
      DeviceContext.maxDeviceModelLength,
    ),
    locale: _locale(payload['locale']),
  );
}

final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

// Language subtag followed by any number of subtags; precise enough to keep
// garbage out without rejecting rare but valid tags such as `zh-Hant-TW`.
final _languageTag = RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$');

String? _text(Object? value, int maxLength) {
  if (value is! String) return null;
  final text = value.replaceAll(_controlCharacters, '').trim();
  if (text.isEmpty) return null;
  final runes = text.runes;
  if (runes.length <= maxLength) return text;
  return String.fromCharCodes(runes.take(maxLength)).trimRight();
}

String? _locale(Object? value) {
  if (value is! String) return null;
  final tag = value.trim().replaceAll('_', '-');
  if (tag.length > DeviceContext.maxLocaleLength ||
      !_languageTag.hasMatch(tag)) {
    return null;
  }
  return tag;
}
