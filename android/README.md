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

`assembleRelease` minifies with R8 and, until there is a release keystore, signs with
the debug key so the build can still be installed.

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
  has `autoVerify`, but until the API serves `/.well-known/assetlinks.json` with the
  signing certificate's fingerprint, Android opens the link in the browser unless the
  user turns on "Open supported links" for the app.
- **One view model per object number** (`viewModel(key = objectId)`), so switching
  apartments starts from an empty store, as `WeekView().id(objectId)` does on iOS.
