# Platform channel contract

The wire contract between the Dart layer (`lib/src/platform/`) and the plugin's native layers
(`android/…/BeckLinkPlugin.kt`, `ios/…/BeckLinkPlugin.swift`). Dart owns networking, storage and
attribution; the native layers only do what Dart cannot. Changing anything here means changing
both sides and `MethodChannelBeckLinkPlatform`.

## Channels

| Channel                        | Kind                                | Codec                 |
| ------------------------------ | ----------------------------------- | --------------------- |
| `app.becklink.flutter/methods` | `MethodChannel`: every call below   | `StandardMethodCodec` |
| `app.becklink.flutter/links`   | `EventChannel`: links while running | `StandardMethodCodec` |

## Rules for every native method

- **Threads.** Reply on the platform main thread. Do disk, Keychain and IPC work off it (Android:
  a background executor; iOS: a background `DispatchQueue`), except `UIPasteboard`, which is
  main-thread only. Nothing may block the main thread while the app starts (§29: `configure()`
  stays under 20 ms).
- **Expected outcomes are answers, not errors.** "No link", "no seed", "no referrer" and "no
  pasteboard URL" are `null` or a status (see each method). `result.error(code, message, null)` is
  only for unexpected failures; Dart logs the code and uses the fallback.
- **Error codes.** `storage_unavailable` (`getStorageDirectory`), `keychain_unavailable`
  (`getInstallIdSeed`) and `invalid_arguments`: a method whose arguments are missing or have the
  wrong type (for example `saveInstallIdSeed` without a UUID string, `readPasteboardUrl` without a
  list of strings). Dart validates arguments before calling, so `invalid_arguments` only reports a
  bug; both platforms use this code, and a platform that ignores a method's arguments (Android for
  `saveInstallIdSeed` and `readPasteboardUrl`) never sends it.
- **Unknown methods** answer `notImplemented()` / `FlutterMethodNotImplemented`.
- **Privacy** (contract section 12): never log URLs, query strings, referrers, install IDs or
  pasteboard text; error messages must not contain them either. Never read IDFA, GAID, IDFV,
  `ANDROID_ID` or the user-chosen device name.
- **Dart deadlines.** Dart waits 10 s for each call (15 s for `getInstallReferrer`, 60 s for
  `readPasteboardUrl`), then uses the fallback and drops a late answer. Pasteboard and referrer
  results are therefore cached natively (see below), so a later call still gets them.

## Link payload

`getInitialLink` and the link event channel use the same map:

| Key              | Type   | Rule                                                                                         |
| ---------------- | ------ | -------------------------------------------------------------------------------------------- |
| `url`            | String | The URL exactly as received: Android `intent.dataString`, iOS `URL.absoluteString`; ≤ 16 KiB |
| `received_at_ms` | Int    | Device clock (ms since the Unix epoch) when the native layer got the URL from the OS         |

Report every `VIEW` / `openURL` / `NSUserActivityTypeBrowsingWeb` URL, whatever its host or scheme;
Dart decides which ones are Beck Link URLs (contract section 9.1) and never sends the others
anywhere. `received_at_ms` is the direct open's `opened_at` and, with `url`, identifies one
delivery for Dart's link dedupe, so stamp each delivery once and keep that stamp.

## Methods

| Method                | Arguments                               | Answer                 | Android                     | iOS                            |
| --------------------- | --------------------------------------- | ---------------------- | --------------------------- | ------------------------------ |
| `getInitialLink`      | none                                    | link payload or `null` | launch intent               | launch Universal Link / URL    |
| `getStorageDirectory` | none                                    | String (absolute path) | `noBackupFilesDir/becklink` | `Application Support/becklink` |
| `getInstallIdSeed`    | none                                    | String or `null`       | `null`                      | Keychain item                  |
| `saveInstallIdSeed`   | `{install_id: String}` (lowercase UUID) | Bool: stored           | `false`                     | Keychain item                  |
| `getInstallReferrer`  | none                                    | status map, or `null`  | Play Install Referrer       | `null`                         |
| `readPasteboardUrl`   | `{allowed_hosts: List<String>}`         | String or `null`       | `null`                      | pasteboard click URL           |
| `getDeviceContext`    | none                                    | map                    | see below                   | see below                      |

There is no native `isDebugBuild`: Dart uses its compile-time `kDebugMode`.

### `getInitialLink`

The URL that launched the app (cold start), handed out **once per process**: the first call returns
it and forgets it; later calls (also after a Flutter hot restart) return `null`. A URL delivered
after launch goes to the link event channel instead. Each OS delivery is reported exactly once,
through one of the two. **A launch link that only arrives after Dart asked** (iOS: a scene that
connects later, or a launch delivery that reaches the plugin after the first `getInitialLink`
call) **goes to the link event channel**, so it is never lost; Dart handles it like any link
received while running.

Dart calls `getInitialLink` once per engine, and only after the app reached the foreground
(lifecycle `resumed` or `inactive`, or its first frame was drawn). A headless engine, such as a
push-messaging background isolate, therefore never asks, so Android never waits for an activity
that will not come.

- **Android:** the launching activity's intent (`ACTION_VIEW` with data), read when the plugin is
  attached to the activity (`ActivityAware`). Do not report it again when the activity is recreated
  (configuration change, process restore with a saved state) or launched from Recents
  (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`). If Dart asks before any activity is attached (prewarmed
  engine), answer once the first activity attaches.
- **iOS:** the launch Universal Link (`NSUserActivity` with `webpageURL`) or URL from the launch
  options or the scene's connection options. When iOS also calls `continueUserActivity` /
  `openURL` for that same launch delivery, do not report it a second time on the event channel.

### Link event channel (`app.becklink.flutter/links`)

URLs received while the app runs: Android `onNewIntent` (`ACTION_VIEW` with data); iOS
`application(_:continue:restorationHandler:)`, `application(_:open:options:)` and their
`UIScene` equivalents where the Flutter version offers them. Each event is a link payload.

- Until Dart listens, buffer events in arrival order (keep the newest 16), then send them all on
  `onListen`, followed by live events. After `onCancel`, buffer again. `onListen` replaces any
  previous sink (hot restart).
- Never send `error` or end-of-stream; Dart ignores both.
- Observe URLs, never claim them: return `false` from the iOS `openURL` / `continueUserActivity`
  delegate methods (Flutter stops at the first plugin that returns `true`, which would hide OAuth
  callbacks and other URLs from other plugins) and from Android's `NewIntentListener`.

### `getStorageDirectory`

Absolute path of the SDK's own folder, created if missing, excluded from backups (contract P26: a
restored or migrated device is a new install). Dart writes `state.json` and `events.json` there.

- **Android:** `File(context.noBackupFilesDir, "becklink")` (`mkdirs()`); Auto Backup never copies
  `noBackupFilesDir`.
- **iOS:** `Library/Application Support/becklink`, with `isExcludedFromBackup` (`URLResourceValues`)
  set to `true` on that folder on every call, never on Application Support itself, which holds the
  app's own data.
- If the folder cannot be created: `error("storage_unavailable", …)`. Dart then keeps state in memory
  for the process.

### `getInstallIdSeed` / `saveInstallIdSeed`

The install ID kept outside the app container, so a reinstall on the same device keeps it (contract
sections 8.2 and 12, P26).

- **iOS:** one generic-password Keychain item: `kSecAttrService` `app.becklink.flutter`,
  `kSecAttrAccount` `install_id`, `kSecAttrAccessible` `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  not synchronizable, UTF-8 value. `getInstallIdSeed` returns the value or `null`
  (`errSecItemNotFound`); when the Keychain cannot be read now (`errSecInteractionNotAllowed` before
  the first unlock, other `OSStatus`) answer `error("keychain_unavailable", …)` — never `null`, or Dart
  would treat the device as new. `saveInstallIdSeed` adds or updates the item and returns `true`, or
  `false` when that fails.
- **Android:** `getInstallIdSeed` returns `null`; `saveInstallIdSeed` returns `false`.

### `getInstallReferrer`

- **Android** (AND-005): read the Play Install Referrer with Google's `installreferrer` library and
  return the raw `installReferrer` string unchanged (contract section 9.2):

  | Answer                                                                                                     | When                                                                           |
  | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
  | `{status: "ok", raw_referrer: String, click_timestamp_seconds: Int, install_begin_timestamp_seconds: Int}` | `OK`; timestamps from `ReferrerDetails`, `0` when unknown                      |
  | `{status: "service_unavailable"}`                                                                          | `SERVICE_UNAVAILABLE`, `SERVICE_DISCONNECTED`, bind failure, no answer in 10 s |
  | `{status: "feature_not_supported"}`                                                                        | `FEATURE_NOT_SUPPORTED` (no or old Play Store)                                 |
  | `{status: "developer_error"}`                                                                              | `DEVELOPER_ERROR`                                                              |
  | `{status: "permission_error"}`                                                                             | `PERMISSION_ERROR`                                                             |

  Connect at most once per process: concurrent calls share the pending read, and an `ok` or a
  permanent failure is cached and returned again; only `service_unavailable` lets a later call try
  again. Always `endConnection()`. Bound the native wait to 10 s. "Once per install" is kept by Dart,
  which asks only until first-open stored its evidence.

- **iOS:** `null`.

### `readPasteboardUrl`

The opt-in iOS pasteboard deferred link (IOS-005, contract section 9.3). Dart calls it only when the
app set `enablePasteboard`, before first-open.

- **iOS:**
  1. Ask `UIPasteboard.general.detectPatterns(for: [.probableWebURL])`. If the pattern is not
     detected, return `null` without reading (no paste prompt).
  2. Read `UIPasteboard.general.string` (this may show the system paste prompt), trim whitespace.
  3. Return it only when it is `https://{host}/_c/{ULID}` and nothing else: scheme `https`, no user
     info, no port or port 443, no query, no fragment, ≤ 2,048 characters, path `/_c/` plus a ULID
     (`[0-7][0-9A-HJKMNP-TV-Z]{25}`, either case), and the lowercase host matches an
     `allowed_hosts` entry. An entry is a lowercase host (exact match) or `*.` plus a host, which
     matches exactly one more label (`*.becklinks.com` matches `acme.becklinks.com`, not
     `becklinks.com` or `a.b.becklinks.com`). Anything else: return `null` and keep nothing.
  4. Read at most once per process; later calls return the first result without touching the
     pasteboard. Never write or clear the pasteboard.

  Dart checks the answer again with the same rules and then applies the exact link host rule
  (environment suffix, reserved slugs, contract section 9.1).

- **Android:** `null`.

### `getDeviceContext`

App and device details for request `context` (contract section 7.1). All values are strings; send
`null` for one you cannot read. Dart trims and cuts them to the contract's lengths and adds
`platform` itself.

| Key            | Android                                                  | iOS                                                                                                      |
| -------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `os_version`   | `Build.VERSION.RELEASE` (`15`)                           | `UIDevice.current.systemVersion` (`18.6`)                                                                |
| `device_model` | `Build.MODEL` (`Pixel 8`)                                | hardware identifier from `utsname.machine` (`iPhone16,2`); on the simulator `SIMULATOR_MODEL_IDENTIFIER` |
| `locale`       | `Locale.getDefault().toLanguageTag()` (`en-US`)          | `Locale.preferredLanguages.first` (`en-GB`), BCP 47 with `-`                                             |
| `app_version`  | `PackageInfo.versionName`                                | `CFBundleShortVersionString`                                                                             |
| `app_build`    | `PackageInfo.longVersionCode` (API 28+) or `versionCode` | `CFBundleVersion`                                                                                        |

Never `UIDevice.current.name` (user-chosen, often a person's name) or any identifier.
