# becklink_flutter

Deep links, deferred deep links and install attribution for Flutter apps on Android and iOS, with
[Beck Link](https://becklinks.com).

- **Direct deep links:** Universal Links (iOS) and App Links (Android) on your project's
  `becklinks.com` host open the right screen, on cold and warm start.
- **Deferred deep links:** a user who clicks a link, installs the app and opens it lands on the
  linked screen. Android uses the Google Play Install Referrer; iOS uses an opt-in pasteboard token.
  Every match says how it was made (`matchMethod`) and how sure it is (`confidence`).
- **Attribution and events:** which link brought an install, plus custom events (purchases,
  sign-ups) with an offline queue, shown in the Beck Link dashboard.
- **Share links:** create referral and share links from the app.
- **Privacy first:** no IDFA, no GAID, no device fingerprinting, no tracking prompt. See
  [Privacy](#privacy).

## Requirements

| What               | Minimum                                                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| Flutter / Dart     | Flutter 3.27 (Dart 3.6)                                                                                 |
| iOS                | iOS 15 (app deployment target 15.0); Xcode 16 or newer (the plugin compiles in Swift 5.9 language mode) |
| Android            | Android 6.0 (API 23; app `minSdk` 23 or higher), `compileSdk` 35, Kotlin Gradle plugin 1.8 or AGP 9     |
| Platforms          | Android and iOS only                                                                                    |
| Beck Link          | A project with your iOS and/or Android app configured, and its publishable key                          |
| Native code to add | None: the plugin registers itself; you only do the platform setup below                                 |

## Install

The package is not yet published on pub.dev. Until it is, add it as a git dependency in
`pubspec.yaml` (this needs read access to the repository):

```yaml
dependencies:
  becklink_flutter:
    git:
      url: https://github.com/Tecbeckp/becklink-flutter.git
      ref: main
```

Once it is published:

```sh
flutter pub add becklink_flutter
```

## Quick start (5 minutes)

### 1. In the Beck Link dashboard

1. Open your project in the environment you develop against (`test`).
2. Under **Applications**, enter your iOS app (bundle ID, Apple Team ID, App Store ID) and your
   Android app (package name, SHA-256 fingerprints, Play Store URL). Beck Link then serves
   `apple-app-site-association` and `assetlinks.json` on your link hosts.
3. Note your link hosts (live `{slug}.becklinks.com`, test `{slug}-test.becklinks.com`) and copy the
   publishable key (`pk_test_…` for development, `pk_live_…` for release builds).
4. Create a link whose deep-link path is a route of your app, for example `/product/123`.

The examples below use the slug `acme` and the app ID `com.acme.shop`; replace them with yours.

### 2. Platform setup

Do the [iOS](#ios) and [Android](#android) steps. The minimum is the iOS 15.0 deployment target,
the Associated Domains entitlement and `FlutterDeepLinkingEnabled = NO` on iOS, and `minSdk` 23,
the `autoVerify` intent filter and `flutter_deeplinking_enabled = false` on Android.

### 3. Configure the SDK and route links in one place

```dart
import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/product/:id',
      builder: (context, state) => ProductScreen(id: state.pathParameters['id']!),
    ),
  ],
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Returns at once; storage, the launch link and network work run in the background.
  await BeckLink.instance.configure(apiKey: 'pk_test_YOUR_KEY');

  // The one place that routes Beck Link links: the link that launched the app, the deferred link
  // after an install, and links opened while the app runs. Each arrives once.
  BeckLink.instance.onLink.listen(routeLink);

  runApp(MaterialApp.router(routerConfig: router));
}

/// Opens the screen of [link]. Link paths come from outside the app, so only known routes pass;
/// anything else keeps the current screen.
void routeLink(LinkEvent link) {
  final uri = Uri.tryParse(link.path);
  final route = switch (uri?.pathSegments) {
    ['product', final id] => '/product/${Uri.encodeComponent(id)}',
    _ => null,
  };
  if (route != null) router.go(route);
}
```

`onLink` keeps the newest links until the first listener subscribes, so nothing is lost between
`configure()` and `listen()`.

### 4. Attribution and events

```dart
final attribution = await BeckLink.instance.getAttribution();
if (attribution.state == AttributionState.attributed) {
  debugPrint('Installed from campaign ${attribution.campaign?.name}');
}

await BeckLink.instance.track('add_to_cart', properties: {'sku': 'SKU-123', 'quantity': 2});
await BeckLink.instance.track('purchase', revenue: 49.98, currency: 'USD');
```

### 5. Verify it works

1. Run a debug build with `configure(apiKey: …, logLevel: LogLevel.debug)`.
2. Open your test link on the device:
   - Android:
     `adb shell am start -W -a android.intent.action.VIEW -d "https://acme-test.becklinks.com/abc123" com.acme.shop`
     (the package name at the end skips the App Links check; leave it out to test verification
     too).
   - iOS: paste the link into Notes or Messages and tap it (a link typed into Safari never opens
     an app).
3. The app opens on the linked screen and the console shows
   `[BeckLink] INFO: Delivering LinkEvent(url: https://acme-test.becklinks.com/abc123, path: /product/123, …)`.
4. Your tracked events appear on the dashboard's **Events** page within about a minute.

If something does not work, see [Troubleshooting](#troubleshooting).

## Platform setup

Each environment has its own link host: links of `test` are on `{slug}-test.becklinks.com` and work
only with a `pk_test_…` key, links of `live` are on `{slug}.becklinks.com` and work only with a
`pk_live_…` key. Enter your app details in every environment you use.

### iOS

**Deployment target iOS 15.0.** The plugin needs iOS 15, and Flutter's app template targets an
older version (12.0 or 13.0, depending on the Flutter version). Raise your app's target:

1. In Xcode, open `ios/Runner.xcworkspace`, select the Runner target, then **General** →
   **Minimum Deployments** → **iOS 15.0** (this sets `IPHONEOS_DEPLOYMENT_TARGET = 15.0` in
   `ios/Runner.xcodeproj/project.pbxproj`).
2. **CocoaPods apps** (Flutter 3.27–3.43, or newer Flutter with Swift Package Manager turned off):
   in `ios/Podfile`, uncomment the platform line and set it to 15.0:

   ```ruby
   platform :ios, '15.0'
   ```

3. **Swift Package Manager apps** (Flutter 3.44 or newer): step 1 is enough. Flutter copies your
   deployment target into its generated plugin package on the next build; run
   `flutter build ios --config-only` to apply it at once.

**Associated Domains.** In Xcode, open `ios/Runner.xcworkspace`, select the Runner target, then
**Signing & Capabilities** → **+ Capability** → **Associated Domains**, and add both hosts. This
writes `ios/Runner/Runner.entitlements`:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
  <string>applinks:acme.becklinks.com</string>
  <string>applinks:acme-test.becklinks.com</string>
</array>
```

Check that the Debug, Profile and Release configurations all use this entitlements file
(`CODE_SIGN_ENTITLEMENTS`) and that your App ID has Associated Domains enabled. For development
builds you can add `?mode=developer` to a host (`applinks:acme-test.becklinks.com?mode=developer`)
to bypass Apple's CDN cache; this needs Developer Mode on the device and **Settings → Developer →
Associated Domains Development** turned on.

**Turn off Flutter's own deep linking**, so Flutter's router does not handle the same URL a second
time (Flutter turns it on by default from 3.27). In `ios/Runner/Info.plist`:

```xml
<key>FlutterDeepLinkingEnabled</key>
<false/>
```

**Custom URL scheme (optional).** If you set a custom URI scheme for your iOS app in the dashboard,
the "Open in app" button of Beck Link's page for in-app browsers uses it
(`acmeshop://becklink?url=…`). Register the same scheme in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.acme.shop.becklink</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>acmeshop</string>
    </array>
  </dict>
</array>
```

**Pasteboard deferred links (optional).** For deferred deep links on iOS, turn on pasteboard
deferred linking in the dashboard and opt in in the app:

```dart
await BeckLink.instance.configure(apiKey: 'pk_live_YOUR_KEY', enablePasteboard: true);
```

What the user sees:

1. They tap a link without the app installed. Beck Link's landing page shows a **Get the app**
   button; tapping it copies a click URL (`https://acme.becklinks.com/_c/{click ID}`) and opens the
   App Store.
2. They install and open the app. On that first run only, and only when iOS reports that the
   pasteboard probably holds a web URL, the SDK reads the pasteboard once. iOS 16 and later then
   ask whether the app may paste from Safari, with **Allow Paste** and **Don't Allow Paste**; iOS
   15 shows a short "pasted from" banner instead.
3. With **Allow Paste** the app opens the linked screen (`matchMethod` `pasteboard`, `confidence`
   `certain`). With **Don't Allow Paste** the install counts as organic and the app shows its
   normal first screen.

The SDK only uses a click URL of your project environment; anything else on the pasteboard is
neither sent nor kept, and the SDK never writes or clears the pasteboard. If the pasteboard holds
some other web URL (say, a copied news link), iOS still shows the prompt on that first run. Users
can change their answer later in **Settings → _your app_ → Paste from Other Apps**. The SDK does
not read the pasteboard when a link opened the app, or while tracking is off.

**CocoaPods and Swift Package Manager.** The plugin supports both. On Flutter 3.27–3.43 use
CocoaPods (the default there): the Swift package needs Flutter 3.44 or newer, so do not turn on
Flutter's Swift Package Manager support on older Flutter versions.

### Android

**`minSdk` 23.** The plugin needs Android 6.0 (API 23). Flutter's app template sets
`minSdk = flutter.minSdkVersion` in `android/app/build.gradle` (or `build.gradle.kts`); that value
is 21 on Flutter 3.27 and 24 on Flutter 3.44. If your Flutter's default or your own value is below
23, set it in `defaultConfig` (the same line works in Groovy and in Kotlin DSL):

```kotlin
android {
    defaultConfig {
        minSdk = 23
    }
}
```

Do not lower a value that is already 23 or higher: Flutter's own minimum can be above the plugin's.

**App Links intent filter.** In `android/app/src/main/AndroidManifest.xml`, inside the
`<activity>` of `MainActivity` (keep the template's `android:launchMode="singleTop"`), turn off
Flutter's own deep linking (on by default from Flutter 3.27) and add one filter per host:

```xml
<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />

<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https" android:host="acme.becklinks.com" />
</intent-filter>

<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https" android:host="acme-test.becklinks.com" />
</intent-filter>
```

Android 11 and older verify all `autoVerify` hosts of an app together: if the test host's
`assetlinks.json` lacks the certificate of a build, the live host is not verified for that build
either. Add every signing certificate to both environments in the dashboard, or move the test-host
filter into `android/app/src/debug/AndroidManifest.xml` (inside the same
`<activity android:name=".MainActivity">`) so release builds declare only the live host.

**SHA-256 fingerprints.** `assetlinks.json` must list the certificate that signed the installed
build. Add each one in the dashboard's Android app settings:

| Build                        | Where to find the SHA-256                                                      |
| ---------------------------- | ------------------------------------------------------------------------------ |
| Installed from Google Play   | Play Console → your app → **App integrity** → **App signing key certificate**  |
| Signed with your upload key  | `keytool -list -v -keystore upload-keystore.jks -alias upload`                 |
| Debug builds (`flutter run`) | `.\gradlew signingReport` (Windows) or `./gradlew signingReport` in `android/` |

Devices see the Play App Signing key. Registering only the upload key is the most common reason
App Links open the browser.

**Custom scheme (optional).** If you set a custom scheme for your Android app in the dashboard, add
a filter for it (without `autoVerify`):

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="acmeshop" android:host="becklink" />
</intent-filter>
```

The plugin itself declares the `INTERNET` permission and visibility of the Play Store app (for the
install referrer). It does not use the Advertising ID and adds no `AD_ID` permission.

Check verification on a device or emulator:

```sh
adb shell pm get-app-links com.acme.shop
adb shell pm verify-app-links --re-verify com.acme.shop
```

## Handling links

- **Handle links in one place.** `onLink` delivers every link once: the one that launched the app,
  the deferred link on the first run, and links opened while the app runs. `getInitialLink()`
  returns that same launch event again. Use `onLink` alone (as in the quick start), or call
  `getInitialLink()` from a splash screen and skip that event on `onLink`:

  ```dart
  final initial = await BeckLink.instance.getInitialLink(); // waits at most firstOpenTimeout
  BeckLink.instance.onLink.where((link) => link != initial).listen(routeLink);
  ```

  Do not await `getInitialLink()` before `runApp()`: the SDK resolves the launch link once the app
  is visible, so it would hold up your first frame.

- **Treat link content as untrusted.** Anyone can craft a link URL, and link data is readable by
  anyone with the link and your publishable key. Route only to known paths and never put secrets in
  link data.
- **Offline links.** When the service does not answer within `firstOpenTimeout`, the app still gets
  the link, built on the device: `linkId` is `null`, `data` is empty, and `path` is the link's
  short path (`/abc123`), not its deep-link path. Route such events to a sensible default.
- **Only Beck Link URLs.** Only URLs of the configured environment's link hosts (and the
  custom-scheme form above) arrive on `onLink`. The SDK ignores your own deep links and OAuth
  callbacks, never sends them anywhere, and leaves them to other plugins.
- **Inactive links.** Links that are expired, disabled, archived or deleted are not delivered; the
  SDK logs "The link is not active in this project environment".

`LinkEvent` fields: `url`, `path` (the in-app route), `params` (query parameters), `data` (custom
JSON), `isDeferred`, `matchMethod`, `confidence`, `linkId`, `campaign`, `clickedAt`.

## Apps that already handle deep links (app_links, go_router, GetX)

An app that has its own deep-link handling does not have to give it up. Two public members make the
SDK work next to it:

- `bool BeckLink.instance.isBeckLinkUri(Uri uri)`: synchronous, offline and side-effect free. `true`
  for a link of the configured environment (`https://{slug}.becklinks.com/…` for a `pk_live_` key,
  `https://{slug}-test.becklinks.com/…` for a `pk_test_` key, a custom link host the service sent
  to the SDK, and the `scheme://becklink?url=…` form). Hosts are compared exactly:
  `https://evil.com/?x=acme.becklinks.com` and `https://acme.becklinks.com.evil.com/` are not Beck
  Link URIs. Before `configure()` ran, the environment is unknown and any platform host
  (`*.becklinks.com`, live or test) counts; custom hosts count once the SDK opened its storage.
- `Future<bool> BeckLink.instance.handleUri(Uri uri)`: gives the SDK a URI your app received by
  other means (`app_links`, a `go_router` redirect, a push payload, a QR scan). It resolves it like
  a link opened by the system (the same re-engagement call and offline fallback) and delivers one
  `LinkEvent` on `onLink`. It returns `true` when the URI is a Beck Link URI that the SDK took, and
  `false` otherwise (nothing is sent, stored or logged beyond scheme and host; continue with your
  own handling). It never throws.

Rules that apply to `handleUri`:

- **Once per open.** The same URL (scheme and host case-insensitive, the rest exact) is delivered
  once when it arrives again within **10 seconds**, whether through `handleUri` twice or through
  the platform channel and `handleUri`, in either order. Opening the same link again later is
  delivered again. The window is in memory (it does not survive a restart).
- **Early calls are safe.** While the SDK starts, a forwarded URI waits for storage and for the
  launch link, then follows the same order as links opened while the app runs. Before `configure()`
  at most 16 Beck Link URIs are kept and handled when it runs.
- **Consent.** As for platform links, a forwarded link is still resolved and delivered while tracking
  is off, without any identifier (`setTrackingEnabled(false)`).
- **Privacy.** Logs show scheme, host and the short path of Beck Link URLs only, never query values.

### Pattern A: keep platform links on, filter your own listener

The simplest change. The SDK keeps reading links from the system; your listener skips Beck Link
URIs so they are not handled twice:

```dart
final appLinks = AppLinks();
appLinks.uriLinkStream.listen((uri) {
  if (BeckLink.instance.isBeckLinkUri(uri)) return; // the SDK delivers it on onLink
  Get.toNamed(uri.path, parameters: uri.queryParameters); // GetX; or router.go(...)
});
```

Handle the Beck Link links through `onLink`, as in the quick start. For the launch link do not use
`appLinks.getInitialLink()` for Beck Link URIs: filter it the same way.

### Pattern B: you receive every URI, the SDK receives none from the system

Turn the SDK's own link intake off and forward everything. Your listener stays the single entry point
for deep links:

```dart
await BeckLink.instance.configure(
  apiKey: 'pk_live_YOUR_KEY',
  handlePlatformLinks: false, // the SDK reads no launch or incoming link itself
);

final appLinks = AppLinks();

Future<void> onUri(Uri uri) async {
  if (await BeckLink.instance.handleUri(uri)) return; // a Beck Link URI: the SDK took it
  Get.toNamed(uri.path, parameters: uri.queryParameters); // your own links
}

final initial = await appLinks.getInitialLink();
if (initial != null) await onUri(initial);
appLinks.uriLinkStream.listen(onUri);
```

With `go_router`, call `handleUri` in the listener that feeds `router.go` (as above), not inside
`redirect`, which must stay a pure function.

With `handlePlatformLinks: false`, the SDK does not call the native layer for the launch link and does
not listen to the native link stream (the native code only observes system callbacks, never claims
them, so it does not interfere with `app_links` or other plugins). `getInitialLink()` reports only
the deferred link of a first run; every forwarded URI, the launch link included, arrives on
`onLink`. Deferred deep linking (Play Install Referrer, the iOS pasteboard), the first open,
attribution and events are not links of the system and work as before. The option is read once, at
the first `configure()` of the process.

### Pattern C: Flutter's own deep linking (`flutter_deeplinking_enabled`)

`FlutterDeepLinkingEnabled` (iOS `Info.plist`) and `flutter_deeplinking_enabled` (Android manifest)
only decide whether **Flutter's router** also receives the URL (as the initial route or a pushed
route). They have no effect on whether the SDK or `app_links` receive it: native callbacks reach
both plugins either way.

- **Leave it on** only if your own router can safely receive a Beck Link URL as well. Then the same
  URL is seen twice: once by Flutter's router and once by the SDK (or by `app_links` and
  `handleUri`). The router sees a route such as `/summer24`; unless it ignores it, the user sees an
  unknown-route page or a double navigation. Make the router ignore it (GetX: an `unknownRoute`
  that shows the current page; `go_router`: a `redirect` that returns the current location for
  `isBeckLinkUri`; depending on the Flutter version the router sees the whole URL or only the
  path, so a host check is not always possible).
- **Turn it off** (as in [Platform setup](#platform-setup)) when the router cannot ignore those
  routes. Then only `app_links` and the SDK see the URL, and Pattern A or B decides who handles it.
  This is the safe choice, and the one this README recommends for new apps.
- Neither value makes the SDK deliver a link twice: the SDK delivers one `LinkEvent` per open as
  described above.

This section describes the intended behaviour from the SDK's code and its tests; the combinations of
Flutter versions, `app_links` and routers were not exercised on devices here, so verify your own
combination with `debugOpenLink` and a real link before release.

## Deferred deep linking

What each platform allows, without guessing:

| Platform | How                                                             | Confidence | When it works                                                                                         |
| -------- | --------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------- |
| Android  | Google Play Install Referrer (`matchMethod` `install_referrer`) | `certain`  | The app was installed from Google Play after the click; not for sideloads or other stores             |
| iOS      | Pasteboard click URL, opt-in (`matchMethod` `pasteboard`)       | `certain`  | `enablePasteboard: true`, the user tapped the landing page's **Get the app** button and allowed paste |
| Both     | No fingerprinting, no IP matching, no IDFA                      | —          | In every other case the install is `organic` and no deferred link is delivered                        |

- The match happens on the first open after install, within the project's deferred window (7 days
  by default). A click is matched to one install only.
- `getInitialLink()` waits for the answer at most `firstOpenTimeout` (3 seconds by default, up to
  30), counted from when the request is sent; the time a user takes to answer the paste prompt does
  not count. After the timeout the app gets "no deferred link". A deferred link that matches later
  is **not** delivered to `onLink`; only `onAttribution` updates.
- The deferred link is delivered once per install, also when the install is a reinstall.

**Test on Android:** upload a build to a Play **internal testing** track and join it as a tester.
Uninstall the app, tap a link on the device (it opens the Play Store), install from Play and open
the app. Builds installed with `adb install` or `flutter run` have no install referrer.

**Test on iOS:** turn on pasteboard deferred linking and pass `enablePasteboard: true`. Uninstall
the app, tap a link in Safari, tap **Get the app**, then install your build (TestFlight or Xcode)
and open it; allow paste when asked. The install ID survives a reinstall on the same device, so a
repeated test reports `reinstall`, but it still delivers the deferred link.

## Attribution

`getAttribution()` says which link, if any, brought this install. `state` is `attributed`,
`organic`, `reinstall`, `pending` (the first open's answer is still on its way) or `unavailable`
(tracking is off, or no result could be had). On later launches it answers at once from the stored
result. `onAttribution` emits every change in this process, for example `pending` and then
`attributed`.

## Events and user ID

```dart
await BeckLink.instance.setUserId('user_8841'); // after sign-in; use an internal ID
await BeckLink.instance.track('signup');
await BeckLink.instance.clearUserId(); // on sign-out
await BeckLink.instance.flush(); // optional: send now; waits at most 30 s
```

- Names: 1–64 characters of `a-z`, `0-9` and `_`. Standard names: `signup`, `login`, `purchase`,
  `subscription`, `checkout`, `add_to_cart`, `registration`.
- Properties: flat, at most 50 keys and 8 KB, values `String`, `bool` or `num`; `null` values are
  dropped. The service removes values that look like email addresses or phone numbers unless your
  project allows them.
- `revenue` needs `currency` (ISO 4217, such as `USD`), and `currency` needs `revenue`.
- Events are stored on the device and sent in batches every 15 seconds (your project's remote
  settings can change this), at 20 waiting events and when the app goes to the background.
  Offline, up to 500 events (2 MB) are kept for 7 days and sent when the network is back; the
  service stores each event once.

## Share links

```dart
try {
  final url = await BeckLink.instance.createLink(
    LinkOptions(
      deepLinkPath: '/referral',
      data: {'reward': 'free_month'},
      campaign: 'referral',
      source: 'app',
      medium: 'share',
    ),
  );
  // Hand `url` to your share sheet.
} on BeckLinkException catch (error) {
  // network, timeout, rate_limited, invalid_key or invalid_request; see the error codes below.
  debugPrint('The link was not created: ${error.code.wireValue}');
}
```

Links created from the app use your environment's link host, a generated short path and the
project's default redirects: a publishable key is public, so it cannot choose where a link leads.
When a user ID is set, the SDK adds it to the link's data as `referrer_user_id`.

## Consent

Tracking is on until the app turns it off. To wait for consent, pass the user's choice right after
`configure()`; the SDK keeps it across launches:

```dart
await BeckLink.instance.configure(apiKey: 'pk_live_YOUR_KEY');
await BeckLink.instance.setTrackingEnabled(userHasConsented);
```

While tracking is off, links still open and route (they are resolved without any identifier), but
the SDK sends no first open, sessions or events, deletes queued events, deletes the install ID (on
iOS also the Keychain copy), drops `track()` calls silently and reports attribution `unavailable`.
Turning tracking on again makes the device a new install. If tracking is turned on only after the
first screen appeared, that install's deferred link is not delivered (see
[Known limitations](#known-limitations)).

## Logging

`logLevel` (`none`, `error` by default, `info`, `debug`) sets what the SDK writes to the console,
with the prefix `[BeckLink]`; change it later with `setLogLevel()`. Your project's remote settings
can override it. Logs never contain API keys, user IDs, query strings or event properties.

## Debugging and diagnostics

For debug and support screens (the [example app](example/DEBUGGING.md) uses all of them):

- `BeckLink.version`: the SDK version sent as `X-SDK-Version`.
- `getDiagnostics()`: a `BeckLinkDiagnostics` snapshot with the environment, API origin, install
  ID, first-open status and outcome (matched `LinkEvent`, `unmatchedReason`), attribution, remote
  config (`linkHosts`) and queued event count. No API key or user ID.
- `onApiCall`: a `BeckLinkApiCall` for every request attempt: path, attempt, HTTP status,
  duration, `X-Request-Id`, `Idempotent-Replayed` and the error code of a failed attempt. Never
  the key, bodies or IDs. May be listened to before `configure()`.
- `configure(apiBaseUrl: …)`: talk to a staging or local SDK API instead of
  `https://api.becklinks.com`. HTTPS, or HTTP to this machine (`localhost`, `10.0.2.2` from the
  Android emulator); debug builds also accept HTTP to a private network address (`192.168.x.x`)
  so a phone can reach a server on the same Wi-Fi. Leave it out in apps.
- Debug builds only (they throw `UnsupportedError` elsewhere): `debugResetInstall()` forgets the
  install, `debugRunFirstOpen()` sends the first open again without a restart, and
  `debugOpenLink(uri)` handles a URL as if the system had opened the app with it.

## Example app

[`example/`](example) is a go_router app with home, product and referral screens and a Debug screen
for testing links, events and attribution. It doubles as a debugging app for a real phone against
production or a local server; see [example/DEBUGGING.md](example/DEBUGGING.md). It uses the current Flutter app template and needs
Flutter 3.44 or newer; the package itself supports Flutter 3.27 and newer.

## API reference

The full reference is in the package's dartdoc. Summary:

| Member                                                                                    | What it does                                                                           |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `BeckLink.instance`                                                                       | The SDK                                                                                |
| `Future<void> configure({required apiKey, logLevel, enablePasteboard, firstOpenTimeout})` | Starts the SDK with a publishable key and returns at once; call it in the main isolate |
| `Future<LinkEvent?> getInitialLink()`                                                     | The link that opened the app (direct or deferred), or `null`                           |
| `bool isBeckLinkUri(Uri uri)`                                                             | Whether `uri` is a Beck Link URI of the configured environment (synchronous, offline)  |
| `Future<bool> handleUri(Uri uri)`                                                         | Feeds a URI your app received by other means to the SDK; `false` when it is not ours   |
| `configure(…, handlePlatformLinks: true)`                                                 | `false`: the SDK reads no links from the system; you forward them with `handleUri`     |
| `Stream<LinkEvent> get onLink`                                                            | Every link, each once; buffered until the first listener                               |
| `Future<Attribution> getAttribution()`                                                    | The install's attribution                                                              |
| `Stream<Attribution> get onAttribution`                                                   | Attribution changes                                                                    |
| `Future<void> track(name, {properties, revenue, currency})`                               | Queues a custom event                                                                  |
| `Future<void> setUserId(id)`, `Future<void> clearUserId()`                                | Sets or forgets your user ID (1–256 characters)                                        |
| `Future<String> createLink(LinkOptions options)`                                          | Creates a share link and returns its URL                                               |
| `Future<void> setTrackingEnabled(bool enabled)`                                           | Consent switch, kept across launches                                                   |
| `Future<void> flush()`                                                                    | Sends queued events now                                                                |
| `void setLogLevel(LogLevel level)`                                                        | Changes the console log level                                                          |

| Type                | Contents                                                                                                                |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `LinkEvent`         | `url`, `path`, `params`, `data`, `isDeferred`, `matchMethod`, `confidence`, `linkId`, `campaign`, `clickedAt`           |
| `Attribution`       | `state`, `matchMethod`, `confidence`, `linkId`, `campaign`, `installedAt`                                               |
| `Campaign`          | `name`, `source`, `medium`, `content`, `term`, `creative`                                                               |
| `LinkOptions`       | `deepLinkPath`, `data`, `campaign` (a campaign key), `source`, `medium`, `content`, `term`, `creative`, `expiresAt`     |
| `AttributionState`  | `pending`, `attributed`, `organic`, `reinstall`, `unavailable`                                                          |
| `MatchMethod`       | `universalLink`, `appLink`, `uriScheme`, `installReferrer`, `pasteboard`; `idfa` and `probabilistic` are never reported |
| `Confidence`        | `certain`; `low` is never reported                                                                                      |
| `LogLevel`          | `none`, `error`, `info`, `debug`                                                                                        |
| `BeckLinkException` | `code` (a `BeckLinkErrorCode`), `message`, `statusCode`, `retryAfter`, `requestId`                                      |
| `RemoteConfig`      | Settings the service sends to the SDK; apps do not need it                                                              |

Mistakes in arguments (an event name with capitals, `LinkOptions.data` over 4 KB, a path without a
leading `/`) throw an `ArgumentError`. Everything else is a `BeckLinkException`; branch on `code`,
not on `message`:

| `code`              | Thrown by                                                                                     | What to do                                                              |
| ------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `not_configured`    | Any other method called before `configure()`, except the `onLink` and `onAttribution` getters | Call `configure()` first                                                |
| `invalid_key`       | `configure()` (not a `pk_test_…`/`pk_live_…` key; secret keys are refused), `createLink()`    | Use the publishable key; check it is active and allowed to create links |
| `network`           | `createLink()`                                                                                | Offer a retry                                                           |
| `timeout`           | `createLink()` (after at most 30 seconds)                                                     | Offer a retry                                                           |
| `rate_limited`      | `createLink()`                                                                                | Wait `retryAfter`, then retry                                           |
| `invalid_request`   | `createLink()`, for example with an unknown campaign key                                      | Fix the request; `message` names the problem                            |
| `tracking_disabled` | Not thrown by this version: `track()` drops events while tracking is off                      | —                                                                       |
| `link_not_found`    | Not thrown: inactive links are not delivered, and the SDK logs them                           | —                                                                       |

`track()`, `flush()` and link handling never throw for network trouble: events stay queued, and
links fall back to the event built on the device.

## Troubleshooting

Set `logLevel: LogLevel.debug` first; most problems show up in the `[BeckLink]` log lines. The
dashboard's domain diagnostics and Link Tester check the hosted files for you.

| Symptom                                                                                                                                                                                                   | Cause                                                                                                                               | Fix                                                                                                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Android build fails: `uses-sdk:minSdkVersion 21 cannot be smaller than version 23 declared in library [:becklink_flutter]` (Flutter: "The plugin becklink_flutter requires a higher Android SDK version") | The app's `minSdk` is below 23 (`flutter.minSdkVersion` is 21 on Flutter 3.27)                                                      | Set `minSdk = 23` in `android/app/build.gradle` (or `.kts`); see [Android](#android)                                                                         |
| iOS build fails in `pod install`: "… required a higher minimum deployment target" (Flutter: `The plugin "becklink_flutter" requires a higher minimum iOS deployment version`)                             | The Podfile's `platform :ios` (or, without one, the Runner target's deployment target) is below 15.0                                | Set `platform :ios, '15.0'` in `ios/Podfile` and **Minimum Deployments** iOS 15.0 on the Runner target; see [iOS](#ios)                                      |
| iOS build fails with Swift Package Manager: `The package product 'becklink-flutter' requires minimum platform version 15.0 for the iOS platform, but this target supports 13.0`                           | The Runner target's deployment target is below 15.0                                                                                 | Set **Minimum Deployments** iOS 15.0 on the Runner target, then run `flutter build ios --config-only`                                                        |
| iOS: the link opens Safari or the App Store, not the app                                                                                                                                                  | Wrong Apple Team ID or bundle ID in the dashboard, or the Associated Domains entitlement is missing from this build                 | Fix the iOS app settings in the dashboard; check the entitlement in Release builds and the capability of your App ID                                         |
| iOS: a link typed or pasted into Safari's address bar opens the website                                                                                                                                   | By design: iOS opens apps only for tapped links                                                                                     | Tap the link in Notes or Messages instead                                                                                                                    |
| iOS: tapping a link on a web page of the same host opens the website                                                                                                                                      | By design: iOS ignores Universal Links within the same domain                                                                       | Link from another domain; Beck Link's landing page offers an "Open in app" button                                                                            |
| iOS: links stopped opening the app on one device                                                                                                                                                          | The user once chose to open such a link in Safari, which iOS remembers                                                              | Long-press the link and choose to open it in the app, or tap **Open** in Safari's app banner                                                                 |
| iOS: a changed app setting has no effect yet                                                                                                                                                              | Apple's CDN still serves the old `apple-app-site-association`                                                                       | Wait (it can take hours); compare with `curl https://app-site-association.cdn-apple.com/a/v1/acme.becklinks.com`; use `?mode=developer` in development builds |
| Android: the link opens the browser (Android 12+) or a chooser (Android 6–11)                                                                                                                             | `assetlinks.json` lacks the SHA-256 of the installed build, often because only the upload key is registered                         | Add the Play App Signing (and debug) SHA-256 in the dashboard, reinstall, run `adb shell pm verify-app-links --re-verify com.acme.shop`                      |
| Android 6–11: debug builds open links, release builds do not                                                                                                                                              | The test host is declared, but its environment lacks the release certificate (all hosts verify together)                            | Add the certificate to the test environment, or declare the test host only in the debug manifest                                                             |
| The app opens but shows Flutter's "page not found", or navigates twice                                                                                                                                    | Flutter's own deep linking is still on (the default since Flutter 3.27)                                                             | Set `FlutterDeepLinkingEnabled` to `NO` (iOS) and `flutter_deeplinking_enabled` to `false` (Android)                                                         |
| The link stays in the in-app browser of Instagram, Facebook, TikTok or Gmail                                                                                                                              | These browsers do not hand links to apps                                                                                            | Expected: Beck Link shows an "Open in app" page there. Set a custom scheme in the dashboard and the app so its button can open the app                       |
| The app opens but `onLink` gets nothing; log "Ignored a link of the … environment"                                                                                                                        | A test link with a live key, or the reverse                                                                                         | Use links and the publishable key of the same environment                                                                                                    |
| The app opens but `onLink` gets nothing; log "The link is not active…"                                                                                                                                    | The link is expired, disabled, archived or deleted                                                                                  | Reactivate it or use another link; keep a default screen for this case                                                                                       |
| `linkId` is `null`, `data` is empty and `path` is the short path                                                                                                                                          | The service did not answer within `firstOpenTimeout`, or the device was offline                                                     | Check connectivity; raise `firstOpenTimeout` on slow networks; route unknown paths to a default screen                                                       |
| Android: no deferred link, attribution `organic`                                                                                                                                                          | The app was not installed from Google Play after the click (`adb`, `flutter run`, another store)                                    | Test through a Play internal testing track (see [Deferred deep linking](#deferred-deep-linking))                                                             |
| iOS: no deferred link, attribution `organic`                                                                                                                                                              | `enablePasteboard` is off, pasteboard deferred linking is off in the dashboard, paste was denied, or the link is on a custom domain | Check each; the user must tap **Get the app** on the landing page and allow paste                                                                            |
| No deferred link, but `onAttribution` later reports `attributed`                                                                                                                                          | The first-open answer arrived after `firstOpenTimeout`                                                                              | Raise `firstOpenTimeout` (at most 30 seconds) or check the network                                                                                           |
| No deferred link after the user accepted tracking                                                                                                                                                         | Tracking was off at the first launch and was turned on after the first screen appeared                                              | Known limitation; see [Consent](#consent)                                                                                                                    |
| `configure()` throws `invalid_key`                                                                                                                                                                        | A secret key (`sk_…`) or a malformed key                                                                                            | Use the publishable key (`pk_test_…` or `pk_live_…`) from the dashboard                                                                                      |
| Log "The Beck Link API refused the API key"; nothing is sent                                                                                                                                              | The key is unknown or revoked; the SDK stops sending until the app restarts or `configure()` gets another key                       | Ship the current publishable key; queued events are kept                                                                                                     |
| `createLink()` throws `rate_limited`, or the log says sending was rate limited                                                                                                                            | Too many requests from this install                                                                                                 | Wait `BeckLinkException.retryAfter`; queued events are sent again automatically                                                                              |
| iOS on Flutter 3.27–3.37: no links at all                                                                                                                                                                 | The app adopted the UIScene life cycle, whose events plugins only get from Flutter 3.38                                             | Keep the app-delegate life cycle on these Flutter versions, or upgrade Flutter                                                                               |

Check the hosted files yourself; expect status `200`, `Content-Type: application/json` and no
redirect:

```sh
curl -i https://acme.becklinks.com/.well-known/apple-app-site-association
curl -i https://acme.becklinks.com/.well-known/assetlinks.json
```

## Known limitations

- **iOS on Flutter 3.27–3.37 with UIScene:** apps that adopted the UIScene life cycle themselves
  receive no links, because Flutter gives plugins scene events only from 3.38. Apps on the default
  app-delegate life cycle are not affected.
- **Another plugin claiming the launch:** in UIScene apps on Flutter 3.38+, if another plugin
  returns `true` from `scene(_:willConnectTo:options:)`, the link that launched the app can be
  missed. Links opened while the app runs are not affected.
- **Late deferred links are not delivered:** a deferred link that matches after `firstOpenTimeout`
  only updates the attribution.
- **iOS pasteboard links on custom domains:** on the first run the SDK knows only the
  `*.becklinks.com` hosts, so it does not use a pasteboard click URL on a custom domain.
- **Consent later than the first screen:** turning tracking off deletes the install ID, and turning
  it on starts a new install; a deferred link that this new install matches is not delivered.
- **Main isolate only:** call `configure()` in the app's main isolate. In background isolates and
  headless engines (for example push-messaging handlers) the SDK reads no launch link and registers
  no install.
- **Only Beck Link URLs:** the SDK reports Beck Link URLs only. Your app's other deep links need
  their own handling (for example `app_links`), which can live next to the SDK: see
  [Apps that already handle deep links](#apps-that-already-handle-deep-links-app_links-go_router-getx)
  (`isBeckLinkUri`, `handleUri`, `handlePlatformLinks`). Forwarded URIs are deduplicated for
  10 seconds only, and the pattern combinations are not verified on devices.
- **Reinstalls:** iOS keeps the install ID in the Keychain, so a reinstall on the same device is
  reported as `reinstall`; a new device or a restored backup is a new install. On Android,
  reinstall detection is best effort: a reinstall or cleared app data usually counts as a new
  install.
- **Install referrer:** Google Play only; Galaxy Store, Huawei AppGallery and sideloaded installs
  get no deferred link.
- **Swift Package Manager:** the Swift package needs Flutter 3.44+; use CocoaPods on older Flutter.

## Privacy

The SDK collects only what deep linking, attribution and your events need. It never collects the
IDFA, the GAID, device names or fingerprints, never shows the App Tracking Transparency prompt, and
needs no `AD_ID` permission.

The plugin ships a `PrivacyInfo.xcprivacy` that declares Device ID, Product Interaction, User ID,
Purchase History, Coarse Location and Other Diagnostic Data (all linked to the user, none used for
tracking), so Xcode's privacy report lists all six. In App Store Connect and in Google Play's Data
safety form, declare **User ID** only if you call `setUserId()`, and **Purchase History** only if
you track purchases or revenue; the other types apply to every app that uses the SDK.

[doc/privacy.md](doc/privacy.md) lists exactly what is sent to which endpoint, what is stored on the
device, the App Privacy and Data safety answers, and data retention.

## Releasing

For maintainers. GitHub Actions publishes the package to pub.dev
(`.github/workflows/publish.yml`) with pub.dev's automated publishing: a short-lived
GitHub OIDC token, no pub.dev credential stored anywhere.

**iOS CI is manual, to save free Actions minutes.** The iOS jobs need macOS runners, and on a
private repository GitHub counts each macOS minute 10 times against the free minutes. So pull
requests and pushes run only the Linux jobs of the **Flutter SDK** workflow (format, analyze, unit
tests, Android builds, publish dry run). The two iOS jobs (Flutter 3.27 with CocoaPods; Flutter
stable with Swift Package Manager and the XCTest suite, `.github/workflows/ios.yml`)
run only:

- when you start the workflow by hand: **Actions** → **Flutter SDK** → **Run workflow**, pick the
  branch, keep **Also run the iOS builds** ticked. Do this before merging a change to the Swift
  code, `ios/`, the podspec or `Package.swift`, and after a new Flutter stable;
- on every `v*` tag, inside the publish workflow, which publishes only when they pass.

One-time setup:

1. Publish the first version by hand (`flutter pub publish` in the repository root): pub.dev automates
   only packages that already exist.
2. On pub.dev, open the package's **Admin** tab → **Automated publishing** → **Enable publishing
   from GitHub Actions**, with repository `Tecbeckp/becklink-flutter` and tag pattern
   `v{{version}}`. Turn on **Require GitHub Actions environment** with the environment
   `pub.dev`.
3. On GitHub, create the environment `pub.dev` (**Settings** → **Environments**) with required
   reviewers and a deployment tag rule `v*`, so only approved tags publish.

Each release:

1. Set the same version in `pubspec.yaml` (`version`) and in `lib/src/sdk_info.dart`
   (`sdkVersion`), and give it a `## <version> (<release date>)` entry in `CHANGELOG.md`.
2. Merge to `main` with the **Flutter SDK** workflow green. If the release changes iOS code, run
   the workflow by hand on `main` with the iOS builds first, so a failure shows up before the tag.
3. Tag that commit and push the tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

The workflow first checks that the tag, `pubspec.yaml`, `sdk_info.dart` and the CHANGELOG agree and
that the CHANGELOG entry no longer says "unreleased". It then runs both iOS builds on the tagged
commit; if one fails, nothing is published (re-run a flaky job, or fix the code and tag the fixed
commit after deleting the old tag).
After a reviewer approves the `pub.dev` environment it runs `flutter pub publish --dry-run`, which
fails on any warning, and then publishes.

## License

MIT, see [LICENSE](LICENSE).
