# SSSB Laundry — Android app

The Android twin of the iOS app in [`../app`](../app): Kotlin, Jetpack Compose and
Material 3 Expressive, talking to the same API in [`../api`](../api). English and
Swedish, with the Swedish wording taken from the iOS app's string catalog.

## What it does

- The week of timeslots with infinite scroll, pull to refresh and a date picker to jump ahead
- Book or cancel 1–2 groups in one action from a bottom sheet, with a per-group receipt
- Long press a timeslot to book, cancel (after a confirmation), call dibs, add to the calendar or copy the time
- Dibs and dibs priority, behind the same opt-in setting as on iOS
- Settings: visible groups, active hours, laundry room rules by street address, dibs, sign out
- Invite links (`https://sssb-laundry.eliasf.se/invite#…`), shared through the system share sheet and opened by the app
- Feedback straight to the developer, with a draft that survives the sheet
- A "Start a timer" card while a session is running, which hands the countdown to the Clock app

Not yet on Android: booking reminders and dibs pushes (the server only speaks APNs),
and the Live Activity.

## Building

Needs JDK 21 and the Android SDK (`ANDROID_HOME`, or `sdk.dir` in an untracked
`local.properties`). Gradle comes from the wrapper.

```sh
cd android
./gradlew assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest      # JVM tests for the rules, invite links and decoding
./gradlew installDebug           # onto a running emulator or a connected phone
```

Release builds minify with R8 and are signed with the Play upload key from
`secrets/` (see below); without it they come out unsigned.

```sh
./gradlew bundleRelease          # app/build/outputs/bundle/release/app-release.aab, for Play
./gradlew assembleRelease        # the same build as an APK, to try on a device first
```

## Releasing on Google Play

The app ships through Play with **Play App Signing**: Play holds the key that signs
what users install, and an upload goes in signed with an *upload key* of our own. That
key lives in the gitignored `android/secrets/`, the same convention as `api/secrets/`:

```
secrets/upload.jks           PKCS12 keystore, alias "upload", valid until 2056
secrets/upload.properties    storeFile, storePassword, keyAlias, keyPassword
```

Keep a copy of both somewhere safe, such as a password manager. A lost upload key is
not fatal, since Play support can reset it, but that takes days.

**Each upload needs a higher `versionCode`** in `app/build.gradle.kts`. It is the iOS
build number: `.github/workflows/bump-build.yml` bumps `CURRENT_PROJECT_VERSION` and
`versionCode` together, copies `MARKETING_VERSION` into `versionName`, and tags the
commit `v<version>-<build>`.

### Automated releases

Every version tag goes to Play's closed testing track the way Xcode Cloud takes it to
TestFlight: `.github/workflows/android-release.yml` builds the bundle, signs it with the
upload key and rolls it out to "Closed testing - Alpha" with `fastlane supply`. Release
notes come from `fastlane/metadata/android/<lang>/changelogs/<versionCode>.txt`, else
`default.txt`; nothing else in the listing is uploaded. `bump-build.yml` calls the
workflow itself, since a tag pushed with the Actions token starts no other workflow; a
tag pushed by hand starts it directly. Run it from the Actions tab on a tag to retry, or
with *dry run* to build and check the Play credentials without uploading.

It needs these repository secrets:

```
ANDROID_UPLOAD_KEYSTORE_BASE64   base64 of secrets/upload.jks
ANDROID_UPLOAD_STORE_PASSWORD    \
ANDROID_UPLOAD_KEY_ALIAS          } from secrets/upload.properties
ANDROID_UPLOAD_KEY_PASSWORD      /
PLAY_SERVICE_ACCOUNT_JSON        key of sssb-laundry-play@subtle-hydra-441510-q6.iam.gserviceaccount.com
```

The service account lives in the "Accord App" Google Cloud project and has only *View
app information* and *Release apps to testing tracks* on SSSB Laundry in Play Console, so
it cannot touch production or Accord's apps. A new key is `gcloud iam service-accounts keys
create` and `gh secret set PLAY_SERVICE_ACCOUNT_JSON`.

### Store listing

Everything the listing needs is in `fastlane/metadata/android/`, in the layout `fastlane
supply` and Play's own tooling read, so it can be pasted in by hand now and uploaded by a
tool later:

```
en-US/ sv-SE/   title, short and full description, changelogs/<versionCode>.txt
en-US/images/   icon.png (512), featureGraphic.png (1024×500), phoneScreenshots/
```

`fastlane/art/render.sh` redraws the icon and feature graphic from `icon.svg` and
`feature-graphic.html`. The screenshots are from the emulator at 1080×2160 (`adb shell wm
size 1080x2160`), because Play refuses anything longer than twice its width, with demo
mode on for a clean status bar. Settings is scrolled past the object number, which must
never appear in one.

### Testers

The app is in Play's **closed testing** track, in every country, so it is not searchable
on Google Play. Its testers are the members of the Google Group
`sssb-laundry-testers@googlegroups.com`, which anyone can join and only managers can
see the members of. `https://sssb-laundry.eliasf.se/android` (`api/site/android.html`)
takes a tester through joining the group, opting in at
`https://play.google.com/apps/testing/se.floreteng.sssblaundry` and installing; the
landing page links to it, and the invite page sends Android visitors there.

The developer account is Accord Software's, an organization account, so Play's
12-testers-for-14-days rule for new personal accounts does not apply before production.

### Play Console answers

- **Privacy policy:** `https://sssb-laundry.eliasf.se/privacy`, served from
  `api/site/privacy.html`.
- **App access:** everything is behind sign-in with an object number, so review gets
  the demo one, `0000-0000-000`: the server answers it with sample data kept in memory, so
  booking with it touches nobody's laundry (see `api/README.md`).
- **Ads:** none. **Category:** House & Home. **Contact:** elias.floreteng@gmail.com. **Target audience:** 18 and over.
- **Content rating:** a utility, with no user-to-user content, no location sharing,
  no purchases.
- **Advertising ID:** not used. **Government, financial and health features:** none.
- **Data safety:** data is encrypted in transit; there is no account creation, but users
  sign in with an account made outside the app (the object number, from the tenancy);
  deletion requests go through the privacy policy URL. None of it is shared with third
  parties (booking on SSSB's portal is the user's own request, and Telegram only carries
  feedback as a service provider). Play's "Developer communications" means messages
  *to* users, so feedback is not filed under it. Collected, none of it ephemerally:
  - *Personal info → User IDs* (the object number): required, for app functionality
    and account management.
  - *App activity → Other actions* (dibs and their order): optional, for app
    functionality.
  - *App activity → Other user-generated content* (feedback text): optional, for app
    functionality.
  - *Personal info → Address* (the street address sent with feedback) and *App info
    and performance → Diagnostics* (app version, model, OS, language sent with
    feedback): optional, for analytics, as they serve fixing bugs.

### App signing

Play holds the app signing key, so an install from Play is signed with a different
certificate than a local release build. `api/site/assetlinks.json` lists both SHA-256
fingerprints, Play's app signing key (from *Protected with Play → App signing*) and the
upload key, so invite links verify either way.

## Design

- **Material You first.** Dynamic colour on Android 12+, falling back to a scheme built
  around SSSB's `#064A88` (with `#3E8BC8`-derived tones in dark mode), as on iOS.
- **Material 3 Expressive** — `MaterialExpressiveTheme`, the expressive motion scheme,
  `LoadingIndicator`, flexible large top app bars and shape morphs from `MaterialShapes`.
  Those APIs ship in `material3` 1.5, which is still in beta, so `libs.versions.toml`
  pins it past the Compose BOM.
- **Segmented lists** in the style of Android 16's own Settings: rows of one day share
  small inner corners, the ends round off.
- Icons are Material Symbols Rounded, checked in as vector drawables under `res/drawable`.

## Layout

```
app/src/main/java/se/floreteng/sssblaundry/
  MainActivity.kt          Splash, edge-to-edge, invite links in onCreate and onNewIntent
  SssbLaundryApplication   Settings store and API client, one per process
  data/
    Models.kt              DTOs, hand-mirrored from api/src (as Models.swift is)
    ApiClient.kt           OkHttp + kotlinx.serialization, X-Object-Id on every request
    SettingsRepository.kt  DataStore; the same keys the iOS app uses in UserDefaults
    BookingRules.kt        canBook/canCancel, dibs eligibility, active hours
    LaundryRooms.kt        SSSB's per-room rules, generated from LaundryRooms.swift
    LaundryTime.kt         Europe/Stockholm days and ISO timestamps
    InviteLink.kt          Building and reading the invite link
  ui/
    LaundryViewModel.kt    The port of LaundryStore: anchor, paging, bookings, dibs
    Presenters.kt          ErrorPresenter and group-name formatting
    AppRoot.kt             Sign-in vs signed in, Navigation 3 back stack, switch dialog
    week/ booking/ settings/ dibs/ invite/ feedback/ timer/ signin/
fastlane/
  metadata/android/        Play listing text and images, en-US and sv-SE
  art/                     Sources for the icon and feature graphic, and render.sh
secrets/                   The upload key (gitignored)
```

## Things that will bite you

Everything under "Things that will bite you" in [`../app/README.md`](../app/README.md)
about the data applies here unchanged — Stockholm time, barren weeks ending the list,
bookings never filtered out, `canBook`/`canCancel` deciding what is offered, opaque
`timeslotId`s. The Android-specific ones:

- **`LaundryRooms.kt` is generated from the Swift table**, not edited by hand. Change
  `app/SSSBLaundry/LaundryRooms.swift` and regenerate, so the two can't drift.
- **The object number is excluded from backups** (`res/xml/backup_rules.xml` and
  `data_extraction_rules.xml`) — it is username and password upstream.
- **Invite links verify only with Digital Asset Links.** The manifest's intent filter
  has `autoVerify`, and the API serves `/.well-known/assetlinks.json` from
  `api/site/assetlinks.json`. A certificate missing from it means Android opens the link in the browser unless the user
  turns on "Open supported links" for the app.
- **One view model per object number** (`viewModel(key = objectId)`), so switching
  apartments starts from an empty store, as `WeekView().id(objectId)` does on iOS.
