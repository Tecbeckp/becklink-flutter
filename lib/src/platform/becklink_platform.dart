import 'device_context.dart';
import 'install_id_seed_result.dart';
import 'install_referrer_result.dart';
import 'platform_link.dart';

/// Everything the SDK needs from the operating system that Dart cannot
/// reach on its own. The Dart layer owns networking, storage and
/// attribution; this interface is the whole surface of the thin native
/// layers (phase 7 "Architecture").
///
/// `MethodChannelBeckLinkPlatform` implements it over the platform
/// channels; tests pass their own implementation to the SDK's constructor
/// instead. The wire contract the Kotlin and Swift layers implement is in
/// `doc/platform-channel.md`:
///
/// | Member                | Channel call                         | Android                        | iOS                                     |
/// | --------------------- | ------------------------------------ | ------------------------------ | --------------------------------------- |
/// | [getInitialLink]      | `getInitialLink`                     | launch intent URL, once        | launch Universal Link or URL, once      |
/// | [links]               | event channel `…/links`              | `onNewIntent`                  | `continueUserActivity`, `openURL`       |
/// | [getStorageDirectory] | `getStorageDirectory`                | `noBackupFilesDir/becklink`    | Application Support/becklink, no backup |
/// | [getInstallIdSeed]    | `getInstallIdSeed`                   | `null`                         | Keychain                                |
/// | [saveInstallIdSeed]   | `saveInstallIdSeed {install_id}`     | `false`                        | Keychain                                |
/// | [getInstallReferrer]  | `getInstallReferrer`                 | Play Install Referrer          | `null`                                  |
/// | [readPasteboardUrl]   | `readPasteboardUrl {allowed_hosts}`  | `null`                         | pasteboard, after pattern detection     |
/// | [getDeviceContext]    | `getDeviceContext`                   | `Build`, package info, locale  | `UIDevice`, bundle info, locale         |
/// | [isDebugBuild]        | none (Dart's `kDebugMode`)           |                                |                                         |
///
/// Rules for every implementation, which the SDK relies on:
///
/// - Constructing an implementation does no platform work, so
///   `configure()` stays under 20 ms (§29); every call is asynchronous.
/// - Calls never throw for platform trouble: a missing plugin, a native
///   failure or no answer in time gives the documented fallback (`null`,
///   `false`, an "unavailable" result or [DeviceContext.unknown]) and is
///   logged. Only programmer errors throw an [ArgumentError].
/// - Calls always complete: each has a deadline.
/// - Nothing an implementation logs contains a URL's query, a referrer, an
///   install ID or pasteboard text (contract section 12).
///
/// Internal to the SDK.
abstract interface class BeckLinkPlatform {
  /// The link that launched the app (cold start), or `null` when there is
  /// none or the native layer cannot be reached.
  ///
  /// The native layer hands each launch link out once per process, so a
  /// second call, also after a hot restart, returns `null`. A link that
  /// arrives while the app runs comes through [links] instead; one delivery
  /// never comes through both.
  Future<PlatformLink?> getInitialLink();

  /// Links the operating system hands to the running app (warm start).
  ///
  /// A broadcast stream that never emits errors and never ends. The native
  /// layer buffers links until the first listener subscribes, so links that
  /// arrive before `configure()` are not lost. Listen from one place only:
  /// one subscription per process is all the native side serves.
  Stream<PlatformLink> get links;

  /// Absolute path of the SDK's own storage directory, which the native
  /// layer created and which is excluded from backups (contract P26), or
  /// `null` when it is not available; the SDK then keeps its state in
  /// memory for this process.
  Future<String?> getStorageDirectory();

  /// The install ID kept outside the app container, which survives a
  /// reinstall on the same device (iOS Keychain, contract section 12). See
  /// [InstallIdSeedResult] for the three outcomes.
  Future<InstallIdSeedResult> getInstallIdSeed();

  /// Keeps [installId] outside the app container for a later reinstall to
  /// find (iOS Keychain, device-only) and returns whether it was stored.
  /// Platforms without such a store (Android) return `false`.
  ///
  /// Throws an [ArgumentError] when [installId] is not a UUID.
  Future<bool> saveInstallIdSeed(String installId);

  /// The Google Play Install Referrer (Android, AND-005). The native layer
  /// reads it at most once per process; the SDK asks only until first-open
  /// stored its evidence, so once per install.
  Future<InstallReferrerResult> getInstallReferrer();

  /// The click URL the redirect page copied to the pasteboard
  /// (`https://{host}/_c/{click_id}`, contract section 9.3), or `null`.
  ///
  /// iOS only (Android returns `null`) and only when the app opted in
  /// (`enablePasteboard`). The native layer first asks `UIPasteboard` pattern
  /// detection whether a web URL is probably present and reads nothing (so
  /// no paste prompt appears) when not; it reads at most once per process
  /// and never writes the pasteboard. Text that is not a click URL of one of
  /// [allowedHosts] never leaves the native layer, and Dart checks the answer
  /// again. Patterns are coarse (`*.becklinks.com`); the caller still applies
  /// the exact link host rule (contract section 9.1) before using the URL.
  ///
  /// May wait for the user to answer the system's paste prompt. Throws an
  /// [ArgumentError] when [allowedHosts] is empty, too long or holds an entry
  /// that is not a host pattern (see `checkPasteboardHosts`).
  Future<String?> readPasteboardUrl({required List<String> allowedHosts});

  /// App and device details for request `context` (contract section 7.1),
  /// or [DeviceContext.unknown] when the native layer cannot be reached.
  Future<DeviceContext> getDeviceContext();

  /// Whether this is a debug build, which gates developer-only features
  /// such as resetting the install from the example app's Debug screen.
  bool get isDebugBuild;
}
