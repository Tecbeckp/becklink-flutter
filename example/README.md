# becklink_flutter example: Beck Link Debug

A go_router app that shows the whole `becklink_flutter` integration (direct and deferred deep
links, attribution, events, share and referral links, tracking consent) and doubles as a
**debugging app** to install on a real phone and check the whole deep-link flow against a Beck
Link server: production, or your local stack. **[DEBUGGING.md](DEBUGGING.md)** is the step-by-step
guide.

| Screen      | Location        | What it shows                                                                                       |
| ----------- | --------------- | --------------------------------------------------------------------------------------------------- |
| Home        | `/`             | SDK status, connection, install, attribution, the last incoming links                               |
| Configure   | `/config`       | SDK API URL, publishable key, link hosts, user ID, options; saved on the device                     |
| Debug       | `/debug`        | State (diagnostics, init, first open, attribution, opens), actions, timeline of requests, SDK log   |
| Link detail | `/links/:n`     | The incoming URL and the resolved `LinkEvent`, field by field and as JSON                           |
| Product     | `/product/:id`  | What a link with deep-link path `/product/123` opens, with the link's data; buy and share           |
| Referral    | `/referral`     | Create an invite link that carries your user ID; who invited you when an invite link opened it      |

The example builds with the current Flutter stable (it uses the current project template). The SDK
itself supports Flutter 3.27 and newer, and the example's Dart code sticks to Dart 3.6 so you can
copy it into an older app.

## Setup in short

1. Dashboard (test environment): Android package `app.becklink.becklink_flutter_example` with
   your debug keystore's SHA-256, iOS bundle ID `app.becklink.becklinkFlutterExample` with your
   Team ID, custom URI scheme `becklinkdebug` for both.
2. Replace `REPLACE_WITH_YOUR_LINK_HOST` with your link host in
   `android/app/src/main/AndroidManifest.xml` (App Links, `android:autoVerify="true"`) and
   `ios/Flutter/BeckLink.xcconfig` (Associated Domains). `becklinkdebug://…` always opens the
   app, verified or not.
3. `flutter build apk --debug` (or `flutter run`), then on the phone open **Configure**, enter
   the SDK API base URL and the publishable key (`pk_test_…`), and tap **Save & initialize**.
   Nothing is compiled in; never use a secret key (`sk_…`), the SDK refuses it.

Flutter's own deep linking is off (`flutter_deeplinking_enabled = false` on Android,
`FlutterDeepLinkingEnabled = NO` on iOS), so Flutter does not push the link's short path (`/abc`)
to the router: the SDK resolves the link to its deep-link path and the app routes from `onLink`.

Associated Domains needs a paid Apple Developer team. To run on a device with a free personal team,
remove the `CODE_SIGN_ENTITLEMENTS` build setting of the Runner target in Xcode; links then only
open through the custom scheme.

## How the example handles links

`lib/src/app.dart` is the only place that handles links. It listens to `BeckLink.instance.onLink`, which
delivers every link once: the link that launched the app, the deferred link on the first run after install,
and links opened while the app runs. The example does **not** also call `getInitialLink()`: it returns the
same launch event, and handling it twice would navigate twice.

The deep-link path comes from the link and is untrusted. `lib/src/deep_link_routes.dart` accepts only known
screens (`/`, `/product/{id}` with a checked ID, `/referral`); any other path opens the home screen with a
message. The Debug screen is never reachable from a link. Screens get the whole `LinkEvent` to show its
`params` and `data`.

With **Show every link in the detail screen** on (the default on the Configure screen), every link
opens the link detail screen first, so you see what the app opened with; turn it off to route like
a real app.

## Debug screen

- **State:** SDK version, environment, API origin, install ID, tracking, queued events
  (`getDiagnostics()`); the last `/v1/sdk/init` and the remote config with `link_hosts`; the
  first open with `matchMethod`, `confidence`, the `link_event` JSON or `unmatched_reason`, and
  **Re-run first open**; attribution (`onAttribution`); the last link that opened the app with
  its `/v1/sdk/open` request; every incoming link.
- **Actions:** open a pasted link as if the system delivered it (`debugOpenLink()`), check the
  pasteboard for an iOS click URL, track an event with JSON properties (with or without the user
  ID), create a link with a deep-link path and data and copy, share or open it, consent and user
  ID, **Reset install** (`debugResetInstall()`).
- **Logs:** copy, share or preview the debug report (JSON, keys masked); the timeline of every SDK
  request (`onApiCall`: status, duration, request ID, `Idempotent-Replayed`), incoming link and
  action; the SDK's own log and `setLogLevel()`. The SDK logs through `debugPrint`, already
  redacted; `lib/src/sdk_log_buffer.dart` keeps a copy of those lines.

The debug helpers (`debugResetInstall()`, `debugRunFirstOpen()`, `debugOpenLink()`) and plain
HTTP to your local network work in debug builds only.

## Automated tests

Run from the repository root:

- **SDK unit tests** (`test/`): `flutter test`.
- **Example unit tests** (`example/test/`): `cd example`, then `flutter test`.
- **Direct-link flow on a device** (`example/integration_test/`): with an emulator, simulator or device
  attached, `cd example`, then `flutter test integration_test`. A test cannot make the operating system
  open an App Link or Universal Link, so it hands the SDK the message the native layer sends on the
  `app.becklink.flutter/links` channel; the file's header explains what it checks and where it stops.
- **Android native** (`android/src/test/kotlin/`, JUnit on the JVM): build the example once
  (`flutter build apk --debug`), then in `example/android` run
  `./gradlew :becklink_flutter:testDebugUnitTest`.
- **iOS native** (`example/ios/RunnerTests/`, XCTest, macOS only): `flutter build ios --config-only` in
  `example`, then `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination
  'platform=iOS Simulator,name=iPhone 16'`.

GitHub Actions (`.github/workflows/ci.yml`) runs the Dart, example and Android suites for every
pull request, on the current Flutter stable. On Flutter 3.27 it runs the SDK
unit tests and, in a new app from that version's template, the JUnit tests and the Android release build.

The iOS build and XCTest suite run on macOS runners, whose minutes count 10 times against a private
repository's free GitHub Actions minutes, so they are manual: **Actions** → **Flutter SDK** → **Run
workflow** (with **Also run the iOS builds** ticked). The publish workflow also runs them on every release
tag and publishes only when they pass. The device test never runs in CI.
