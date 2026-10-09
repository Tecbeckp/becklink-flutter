# Beck Link Debug app

The example app doubles as a debugging app: install it on a real phone, point it at a Beck Link
server (production, or your local stack) and watch the whole deep-link flow: configuration,
first open (deferred deep link), attribution, link opens (re-engagement), events, links created by
the SDK, and every SDK API request with its status, request ID and `Idempotent-Replayed` header.

Nothing is compiled in: the server URL, publishable key, link hosts and user ID are entered on the
**Configure** screen and kept on the phone (shared_preferences). Debug builds only can use plain
HTTP to your network, reset the install, re-run the first open and open pasted links.

| Screen                  | What it shows                                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Home                    | SDK status, connection, install ID, first-open status, attribution, the last incoming links                              |
| Configure               | SDK API URL, publishable key, link hosts, user ID, pasteboard opt-in, log level; warnings (HTTP, wrong key, wrong host)  |
| Debug → State           | SDK version, install, init and remote config (`link_hosts`), first open (`matchMethod`, `confidence`, `unmatched_reason`, `link_event` JSON), attribution, last open, all incoming links |
| Debug → Actions         | Open a pasted link, check the pasteboard (iOS), track events (with or without user ID), create a link, consent and user ID, reset install |
| Debug → Logs            | Copy / share / preview the debug report, the timeline of requests, links and actions, the SDK's own log                  |
| Link detail `/links/:n` | Opened for every incoming link: the URL, the resolved `LinkEvent` field by field and as JSON                              |

## 1. Link host and app identity

The app's identifiers:

| Platform | Identifier                                                                     |
| -------- | ------------------------------------------------------------------------------ |
| Android  | package `app.becklink.becklink_flutter_example`                                |
| iOS      | bundle ID `app.becklink.becklinkFlutterExample` (change it in Xcode if needed) |
| Both     | custom URI scheme `becklinkdebug`                                              |

In the dashboard, open the project environment you test (use the **test** environment with a
`pk_test_` key) and set:

- **Android app:** the package name above, custom URI scheme `becklinkdebug`, and the SHA-256
  fingerprint of the key that signs the APK. A debug build is signed with your debug keystore:

  ```powershell
  keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android
  ```

  (PowerShell: `"$env:USERPROFILE\.android\debug.keystore"`; macOS/Linux: `~/.android/debug.keystore`.)
  Copy the `SHA256:` line.
- **iOS app:** the bundle ID, your Apple Team ID, custom URI scheme `becklinkdebug`.

Then put your link host (lower case, for example `myshop-test.becklinks.com`) into the app:

- **Android:** `android/app/src/main/AndroidManifest.xml`, replace `REPLACE_WITH_YOUR_LINK_HOST`
  in the `android:autoVerify="true"` intent filter. One `<data android:scheme="https"
  android:host="…" />` line per host.
- **iOS:** `ios/Flutter/BeckLink.xcconfig`, `BECKLINK_LINK_HOST = myshop-test.becklinks.com`. It
  becomes `applinks:myshop-test.becklinks.com` in `ios/Runner/Runner.entitlements` (Associated
  Domains; needs a paid Apple Developer team). For a development build, append
  `?mode=developer` to the entitlement and turn on Settings → Developer → Associated Domains
  Development, so the phone fetches the AASA file from the host directly.

`becklinkdebug://…` always opens the app, with no verification: use it when App Links or Universal
Links are not set up yet.

Also enter the host on the Configure screen: the app then offers ready-made test URLs and warns
when the host and the key belong to different environments.

## 2. Build and install (Android)

```powershell
cd example
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

Or `flutter run` with the phone attached. Optional build-time defaults (used only until something
is saved on the Configure screen; never commit them):
`flutter run --dart-define=BECKLINK_KEY=pk_test_… --dart-define=BECKLINK_API=http://localhost:4100`.

## 3. Point the phone at a server

On the Configure screen, set **SDK API base URL** (the ingest service, `/v1/sdk/*`) and the
**publishable key**, then **Save & initialize**. The timeline (Debug → Logs) shows
`POST /v1/sdk/first-open → 200` on the first run, `POST /v1/sdk/init → 200` on later launches.

| Server                         | SDK API base URL                       | Notes                                                       |
| ------------------------------ | -------------------------------------- | ----------------------------------------------------------- |
| Production                     | `https://api.becklinks.com`             | Default                                                     |
| Local, phone on USB (simplest) | `http://localhost:4100`                | Run `adb reverse tcp:4100 tcp:4100` after each reconnect    |
| Local, phone on the same Wi-Fi | `http://192.168.x.x:4100` (your PC)    | Ingest must listen on the LAN and the firewall must allow it |
| Local, through an HTTPS tunnel | `https://<your-tunnel-host>`           | Any free tunnel that forwards to `http://localhost:4100`    |
| Android emulator               | `http://10.0.2.2:4100`                 | The emulator's alias for your PC                            |

Local stack (see `docs/LOCAL_SETUP.md`): start it with `pnpm dev`, create a publishable key for the
project's **test** environment in the local dashboard (http://localhost:3000, project → API keys),
and use the seeded test link host `acme-test.localhost` (or your own project's host).

**USB with adb reverse.** Ingest listens on `127.0.0.1:4100` by default, which `adb reverse`
reaches without any other change:

```powershell
adb devices                      # the phone is listed as "device"
adb reverse tcp:4100 tcp:4100    # phone localhost:4100 → PC localhost:4100
adb reverse --list
```

**Wi-Fi.** Let ingest listen on all interfaces (`HOST=0.0.0.0` in the ingest environment, local
development only), find the PC's address with `ipconfig` (IPv4 of the Wi-Fi adapter), and allow the
port through Windows Defender Firewall for private networks (elevated PowerShell):

```powershell
New-NetFirewallRule -DisplayName "Beck Link ingest 4100 (dev)" -Direction Inbound -Protocol TCP -LocalPort 4100 -Action Allow -Profile Private
```

Check from the phone's browser: `http://192.168.x.x:4100/healthz` answers `200`. Remove the rule
when you are done (`Remove-NetFirewallRule -DisplayName "Beck Link ingest 4100 (dev)"`).

Plain HTTP (cleartext) works only in debug builds: `android/app/src/debug/AndroidManifest.xml`
sets `android:usesCleartextTraffic="true"` (the main manifest keeps Android's default, off), and
the SDK accepts `http://` only to this phone, `10.0.2.2` or a private network address
(`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `*.local`), and to private addresses only in debug
builds. Anything else must be HTTPS.

**Local link hosts.** The SDK accepts `https://{slug}-test.becklinks.com/…` links for a test key
right away, and any other host (such as the seeded `acme-test.localhost`, or a custom domain) once
the server listed it in the remote config `link_hosts` (Debug → State → Init and remote config),
which happens with the first open or init. A phone cannot verify App Links for a local host, so
open local links from the app (**Debug → Actions → Open a link**) or through the custom scheme
(next section). The link must exist in the local database (dashboard, or the seeded links).

## 4. Test a direct link (and re-engagement)

From the app: **Debug → Actions → Open a link**, paste `https://<host>/<short path>` and tap
**Open**. The SDK resolves it with `POST /v1/sdk/open`, the app opens the link detail screen, and
Debug → State → **Last open (re-engagement)** shows the request status, request ID and
`Idempotent-Replayed`.

From outside the app, as the system would deliver it (cold start: app closed; warm start: app in
the background):

```powershell
$PKG = "app.becklink.becklink_flutter_example"

# App Link (opens the app only when the host is verified, otherwise the browser)
adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "https://myshop-test.becklinks.com/abc123" $PKG

# Custom scheme: always opens the app ("Open in app" form of Beck Link pages)
adb shell am start -W -a android.intent.action.VIEW -d "becklinkdebug://becklink?url=https%3A%2F%2Fmyshop-test.becklinks.com%2Fabc123" $PKG

# App Link verification state per host ("verified" is what you want)
adb shell pm get-app-links $PKG

# Ask Android to verify again (after fixing assetlinks.json or the fingerprint)
adb shell pm verify-app-links --re-verify $PKG
```

Without the package name at the end, `am start` shows the system chooser or the browser when the
link is not verified, which is the real-world behaviour. Verification fails until the dashboard
has the package name and your debug keystore's SHA-256 (section 1) and the link host serves
`/.well-known/assetlinks.json`; `docs/runbooks/link-debugging.md` checks every layer.

**Create a link from the app:** Debug → Actions → **Create a link (SDK)** with a deep-link path
and JSON data (needs the `sdk:links` scope on the key). **Copy**, **Share** or **Open** it; opened
from another app (Notes, a chat) it should come back into this app with that data.

## 5. Test a deferred deep link and the first open

1. Debug → Actions → **Reset install** (`debugResetInstall()`): forgets the install ID, the
   first-open result, the user ID and queued events.
2. Click a link of your project on the phone **before** opening the app again.
3. Close the app completely (swipe it away) and open it. Its first open sends the evidence it has
   and Debug → State → **First open** shows the result: `matchMethod`, `confidence`, the matched
   `link_event` JSON, or `unmatched_reason` (`no_evidence`, `click_not_found`, …).

**Re-run first open** sends the first open again without a restart (after a reset, or after fixing
the server URL or key while it kept failing). The install referrer and the pasteboard are read
once per app process, so for those, restart the app instead.

**Android, Play Install Referrer.** The SDK reads the referrer through Google's Play Install
Referrer API. Only an install **from Google Play** has one: the redirect sends Android users to
Play with `referrer=click_id%3D<id>`, and Play hands it to the app on its first open. To test it
for real, upload a build to a Play **internal testing** track (or internal app sharing), uninstall
the app, click your link on the phone, install from Play, and open the app: First open shows
`install_referrer` / `certain`.

The old broadcast still appears in many guides:

```powershell
adb shell am broadcast -a com.android.vending.INSTALL_REFERRER -n app.becklink.becklink_flutter_example/<receiver> --es "referrer" "click_id%3D01J0000000000000000000000"
```

It only reaches an app that declares an `INSTALL_REFERRER` broadcast receiver; the Play Install
Referrer API ignores it, so it cannot simulate a referrer for this SDK (Google deprecated the
broadcast in 2020; see https://developer.android.com/google/play/installreferrer). A sideloaded
debug build reports "no referrer" and the first open answers `no_evidence`, which is the
expected organic install.

Without Play you can still test the first open with a link: reset the install, close the app, then
open it **through** a link (the adb commands above). The first open carries the link as
`open_url` and matches it directly (`app_link` or `uri_scheme`, not deferred).

## 6. iOS (needs a Mac)

iOS builds need Xcode on a Mac (or the macOS GitHub Actions runner); this Windows machine cannot
build or sign them.

1. On the Mac: `cd example`, set `BECKLINK_LINK_HOST` (section 1), open
   `ios/Runner.xcworkspace`, select your team under Signing & Capabilities, and run on the iPhone
   (`flutter run`, or Xcode with the Debug configuration).
2. Server: prefer `https://` (production or an HTTPS tunnel). For plain HTTP to your Mac's or PC's
   LAN address, `Info.plist` allows local networking (`NSAllowsLocalNetworking`, which covers only
   local addresses), and iOS asks for the Local Network permission on first use: allow it.
   `http://localhost` on a phone is the phone itself.
3. Universal Links: tap the link in Notes or Messages (typing it into Safari never opens an app).
   Settings → Developer → Universal Links → Diagnostics checks a URL.
4. Custom scheme on the Simulator:
   `xcrun simctl openurl booted "becklinkdebug://becklink?url=https%3A%2F%2Fmyshop-test.becklinks.com%2Fabc123"`.
5. Deferred link through the pasteboard (opt-in; **iOS pasteboard deferred links** is on by
   default on the Configure screen): Reset install, close the app, open a link in Safari and let
   its page copy the click URL before the App Store step, then open the app and allow the paste.
   First open shows `pasteboard` / `certain`. **Check pasteboard** on the Actions tab tells you
   whether the pasteboard holds a click URL (`https://{host}/_c/{click_id}`) without showing
   anything else.

## 7. Send a debug report

Debug → Logs → **Copy debug report** (or **Share**) and paste it to the developer. It contains the
configuration with the key and user ID masked, diagnostics (install ID, first open, remote
config), attribution, the last incoming links, the timeline with request IDs and the SDK log
(already redacted by the SDK). Request IDs match the `X-Request-Id` in the server logs.

## Troubleshooting

| Symptom                                                         | Cause and fix                                                                                                                  |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Timeline: `→ no answer · network`                               | Server not reachable: `adb reverse` lost after reconnecting, ingest bound to `127.0.0.1` for Wi-Fi, firewall, wrong IP/port    |
| Timeline: `→ 401 · invalid_key`                                 | Unknown or revoked key, or a key of another server (production key on the local stack). The SDK stops calling until re-initialized |
| Configure refuses the URL                                       | HTTP to a public host, or a path such as `/v1`: use the origin only, HTTPS outside your network                                |
| "Link ignored by the SDK"                                       | The host belongs to the other environment (test key, live link), is not a link host, or the path is not one short-path segment |
| Link opens the browser                                          | App Link not verified: `adb shell pm get-app-links`, fingerprint and package in the dashboard, then `--re-verify`             |
| Link detail says "not resolved by the service"                  | `/v1/sdk/open` failed (see its status in the timeline): the link does not exist on that server, is inactive, or the server is unreachable |
| First open `no_evidence`                                        | Sideloaded Android build (no Play referrer), pasteboard off or not allowed on iOS, or no link clicked before the first open      |
| Events stay queued                                              | Events wait until the first open succeeded; then check `/v1/sdk/events` in the timeline                                       |
