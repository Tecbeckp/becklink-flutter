# Privacy and data disclosure

What `becklink_flutter` collects, sends and stores, so you can fill in Apple's App Privacy details
and Google Play's Data safety form. Beck Link processes this data on your behalf; you decide what
your app discloses. This page describes the SDK's behaviour and is not legal advice.

## Summary

| The SDK collects                                                                                 | The SDK never collects                                               |
| ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| A random install ID it creates itself                                                            | IDFA, GAID, IDFV, `ANDROID_ID` or any other device identifier        |
| Link opens, app sessions and the custom events you track                                         | Device names, contacts, photos, precise location                     |
| Your user ID, only if you call `setUserId()`                                                     | Device fingerprints; there is no probabilistic or IP-based matching  |
| Platform, OS version, app version and build, device model, locale                                | Pasteboard contents other than a Beck Link click URL of your project |
| Once per install: the Play install referrer (Android), or the pasteboard click URL (iOS, opt-in) | URLs your app receives that are not Beck Link links                  |
| Country and region, derived by the service from the IP address                                   | Raw IP addresses: they are never stored                              |

The SDK never shows the App Tracking Transparency prompt, does not use the Advertising ID, and adds
no `AD_ID` or location permission. Its only native dependency is Google's Install Referrer library
on Android, which talks to the Play Store app on the device.

## What the SDK sends

All requests go to `https://api.becklinks.com` over HTTPS (TLS 1.2 or newer).

### On every request

| Item                                        | Content                                                                                                    |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Authorization`                             | Your publishable key (`pk_test_…` or `pk_live_…`), which is public by design                               |
| `X-SDK-Name`, `X-SDK-Version`, `User-Agent` | `becklink_flutter` and its version; no device information                                                  |
| IP address                                  | Part of every connection. Used in memory for rate limiting and to look up country and region; never stored |

### Device context

Sent as `context` with every request except link creation.

| Field          | Example      | Source                                                                                  |
| -------------- | ------------ | --------------------------------------------------------------------------------------- |
| `platform`     | `ios`        | `android` or `ios`                                                                      |
| `os_version`   | `18.6`       | Android `Build.VERSION.RELEASE`, iOS `systemVersion`                                    |
| `app_version`  | `2.4.0`      | Android `versionName`, iOS `CFBundleShortVersionString`                                 |
| `app_build`    | `2401`       | Android `versionCode`, iOS `CFBundleVersion`                                            |
| `device_model` | `iPhone16,2` | Hardware model: Android `Build.MODEL`, iOS hardware identifier; never the device's name |
| `locale`       | `en-GB`      | The device's preferred language and region                                              |

Context is used for analytics only, never to match installs to clicks.

### By endpoint

| Endpoint                  | When                                                                                                            | Data                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /v1/sdk/first-open` | Once per install, at the first launch (retried until it succeeds)                                               | `install_id`, `first_open_id` (a second random ID for this app installation), `user_id` if set, `context`, and evidence: `open_url` (the Beck Link URL that launched the first run), `android_install_referrer` (the raw Play install referrer, normally `click_id=…`), `ios_pasteboard_url` (only with `enablePasteboard`, only `https://{host}/_c/{click ID}`) |
| `POST /v1/sdk/init`       | At most once per session on later launches (a new session starts after 30 minutes in the background)            | `install_id`, `user_id` if set, `context`                                                                                                                                                                                                                                                                                                                        |
| `POST /v1/sdk/open`       | For each Beck Link URL that opens the app                                                                       | `url`, `opened_at`, `tracking_enabled`, `install_id` and `user_id` (only while tracking is on), `context`                                                                                                                                                                                                                                                        |
| `POST /v1/sdk/events`     | Batches of queued events: every 15 seconds, at 20 events, when the app goes to the background, and on `flush()` | `install_id`, `context`, and per event `event_id`, `name`, `timestamp`, `properties`, `revenue`, `currency`, `user_id` if set                                                                                                                                                                                                                                    |
| `POST /v1/sdk/links`      | When the app calls `createLink()`                                                                               | `deep_link_path`, `data` (plus `referrer_user_id` when a user ID is set and tracking is on), `campaign`, `utm`, `expires_at`, `install_id` (only while tracking is on)                                                                                                                                                                                           |

While tracking is off (`setTrackingEnabled(false)`), the SDK sends only `/v1/sdk/open` (with
`tracking_enabled: false` and no `install_id` or `user_id`, so links still route) and
`/v1/sdk/links` (without `install_id` or `referrer_user_id`).

From the install referrer, the service keeps only the click ID. Event property values that look
like email addresses or phone numbers are removed by the service unless your project allows them.

## What the SDK stores on the device

| Where                                                                                                                                     | What                                                                                                                                                                                                                                     | How long                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `state.json` in the SDK's own folder: Android `noBackupFilesDir/becklink`, iOS `Application Support/becklink`; both excluded from backups | Install ID, first-open ID, first-open status (with its evidence until the first open succeeded) and result (attribution and deferred link), user ID, tracking choice, last remote settings, 64-bit hashes of the last 50 link deliveries | Until the app is uninstalled or its data is cleared; identifiers are deleted when tracking is turned off; link hashes for 24 hours      |
| `events.json` in the same folder                                                                                                          | Queued events                                                                                                                                                                                                                            | Until sent; at most 7 days, 500 events or 2 MB (the oldest are dropped first)                                                           |
| iOS Keychain: service `app.becklink.flutter`, account `install_id`, accessible after first unlock, this device only                       | The install ID                                                                                                                                                                                                                           | Survives a reinstall on the same device, never moves to another device; replaced by a random, never-sent ID when tracking is turned off |

The iOS Keychain copy lets the service recognise a reinstall on the same device. Because the folder
is excluded from backups and the Keychain item is device-bound, a restored or new device is a new
install.

## Consent

Tracking is on until the app calls `setTrackingEnabled(false)`. The choice is kept across launches.
While it is off, the SDK deletes queued events and the install ID (and replaces the iOS Keychain
copy), sends no first open, sessions or events, drops `track()` calls, does not read the install
referrer or the pasteboard, and reports attribution `unavailable`. Links still route. A user ID set
with `setUserId()` stays on the device but is not sent; call `clearUserId()` to delete it. Turning
tracking on again starts a new install with a new ID.

## Apple App Privacy (App Store Connect)

| Apple data type                     | In Beck Link                                                               | Declare it                             | Linked to the user | Used for tracking | Purposes                     |
| ----------------------------------- | -------------------------------------------------------------------------- | -------------------------------------- | ------------------ | ----------------- | ---------------------------- |
| Identifiers → Device ID             | The install ID and first-open ID, random IDs created by the SDK            | Always                                 | Yes                | No                | App Functionality, Analytics |
| Usage Data → Product Interaction    | Link opens, app sessions, custom events, the install's link click          | Always                                 | Yes                | No                | App Functionality, Analytics |
| Location → Coarse Location          | Country and region the service derives from the IP address                 | Always                                 | Yes                | No                | Analytics                    |
| Diagnostics → Other Diagnostic Data | OS version, device model, app version and build, locale                    | Always                                 | Yes                | No                | Analytics                    |
| Identifiers → User ID               | Your user ID from `setUserId()`, also as `referrer_user_id` in share links | Only if you call `setUserId()`         | Yes                | No                | App Functionality, Analytics |
| Purchases → Purchase History        | Purchase events and revenue you track                                      | Only if you track purchases or revenue | Yes                | No                | Analytics                    |

- **Tracking:** Beck Link does not combine this data with third-party data for advertising and does
  not share it with data brokers. If your app itself sends Beck Link data to advertising networks,
  assess tracking for your app.
- **Your own data:** event properties and link data contain what you put in them. Declare the data
  types they carry (for example search terms as Search History).

### PrivacyInfo.xcprivacy

The plugin ships this privacy manifest (CocoaPods resource bundle `becklink_flutter_privacy`, or the
Swift package's resources). Xcode's privacy report (**Product → Archive**, then **Generate Privacy
Report** in the Organizer) includes it.

| Key                           | Value                                                                                                                                                                                                                             |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NSPrivacyTracking`           | `false`                                                                                                                                                                                                                           |
| `NSPrivacyTrackingDomains`    | Empty                                                                                                                                                                                                                             |
| `NSPrivacyCollectedDataTypes` | Device ID and User ID (App Functionality, Analytics); Product Interaction (App Functionality, Analytics); Purchase History, Coarse Location and Other Diagnostic Data (Analytics). All linked to the user, none used for tracking |
| `NSPrivacyAccessedAPITypes`   | File timestamp APIs, reason `C617.1` (metadata of the SDK's own files in the app container); system boot time, reason `35F9.1` (measuring elapsed time for timeouts and retries)                                                  |

The manifest declares every data type the SDK can collect, so User ID and Purchase History appear
in the report even if your app never uses those features. Your App Store Connect answers follow
the "Declare it" column above.

## Google Play Data safety

| Question                                                              | Answer for the Beck Link SDK                                                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Does your app collect or share any of the required user data types?   | Yes: the SDK collects the data below                                                                   |
| Is all of the user data collected by your app encrypted in transit?   | Yes: HTTPS only                                                                                        |
| Do you provide a way for users to request that their data is deleted? | Your own answer, based on your app's process                                                           |
| Shared with third parties?                                            | No: Beck Link processes the data as your service provider, which Google does not count as sharing      |
| Processed ephemerally?                                                | No (the IP address is, but only the derived country and region are kept)                               |
| Required or optional?                                                 | Optional if your app lets users turn tracking off with `setTrackingEnabled(false)`; otherwise required |

| Data safety category → type            | In Beck Link                                                               | Declare it                             | Purposes                     |
| -------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------- | ---------------------------- |
| Device or other IDs                    | The install ID and first-open ID                                           | Always                                 | App functionality, Analytics |
| App activity → App interactions        | Link opens, app sessions, custom events, the install's link click          | Always                                 | App functionality, Analytics |
| Location → Approximate location        | Country and region the service derives from the IP address                 | Always                                 | Analytics                    |
| App info and performance → Diagnostics | OS version, device model, app version and build, locale                    | Always                                 | Analytics                    |
| Personal info → User IDs               | Your user ID from `setUserId()`, also as `referrer_user_id` in share links | Only if you call `setUserId()`         | App functionality, Analytics |
| Financial info → Purchase history      | Purchase events and revenue you track                                      | Only if you track purchases or revenue | Analytics                    |

For the Play Console's **Advertising ID** declaration: Beck Link does not use the Advertising ID;
answer for your other SDKs.

## Data retention

- **On the device:** see [What the SDK stores on the device](#what-the-sdk-stores-on-the-device).
- **On Beck Link's servers:** SDK sessions, clicks and events are kept for your plan's data
  retention period and then deleted; aggregated reports may be kept longer. Your plan's details list
  its retention period. Raw IP addresses and the raw install referrer are never stored.
