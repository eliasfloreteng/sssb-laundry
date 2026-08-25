# SSSB Laundry — iOS app

A native iOS app for browsing and booking laundry timeslots in SSSB student housing. Built with SwiftUI. The backend it talks to is [`../api`](../api) in this same repo.

## Features

- View the full week of laundry timeslots for your apartment
- Book or cancel 1–2 groups per timeslot in a single action
- Filter the list to active hours and to a subset of laundry groups (useful when an object number covers several buildings)
- Show the booking rules SSSB publishes for your laundry room, picked by street address
- Add bookings to the system calendar with a reminder at the timeslot start
- A Live Activity in the hour before a booking, counting down to the start and then through the 15 minutes before it is released
- Pull-to-refresh and infinite scroll into future weeks

## Requirements

- Xcode 26+
- iOS 26.0+
- A valid SSSB object number (format: `1234-5678-901`)
- The backend running at the URL set in `SSSBLaundry/Config.swift` (default: `https://sssb-laundry.eliasf.se`). Run it locally with `cd ../api && bun run dev`; its routes are documented in [`../api/README.md`](../api/README.md).

## Getting started

1. Open `SSSBLaundry.xcodeproj` in Xcode (from the repo root: `open app/SSSBLaundry.xcodeproj`).
2. Select an iOS 26 simulator or device and run the `SSSBLaundry` scheme.
3. On first launch, enter your object number. It is stored in `UserDefaults` and sent as the `X-Object-Id` header on every request.

## Project layout

```
SSSBLaundry/
  SSSBLaundryApp.swift     App entry point
  RootView.swift           Switches between sign-in and main view
  WeekView.swift           Weekly timeslot list, pagination, filters
  TimeslotRow.swift        Single timeslot row
  BookingSheet.swift       Book/cancel sheet for one timeslot
  EventEditView.swift      Calendar event editor wrapper
  SettingsView.swift       Object number, laundry room, visible groups, active hours
  LaundryRoomPicker.swift  Street-address picker for the laundry room rules
  LaundryRooms.swift       SSSB's per-room rules, transcribed from sssb.se
  ObjectIdSetupView.swift  First-run sign-in
  GroupChip.swift          Group status chip
  APIClient.swift          HTTP client (URLSession)
  Models.swift             Decodable DTOs and settings helpers
  LaundryStore.swift       @Observable store (week loading, actions)
  CalendarService.swift    EventKit integration
  LiveActivityService.swift App side of the booking Live Activity
  PushService.swift        APNs registration and preference sync
  AppDelegate.swift        APNs token callback and foreground banners
  NotificationSettings.swift  Reminder offsets and their @AppStorage keys
  ErrorPresenter.swift     Shared error alert presentation
  ObjectIdStore.swift      UserDefaults wrapper for the object id
  Config.swift             Base URL
Shared/
  LaundryActivityAttributes.swift  ActivityKit model, built into both targets
  Assets.xcassets/                 AccentColor, likewise shared by both targets
SSSBLaundryWidgets/
  SSSBLaundryWidgetsBundle.swift   Widget extension entry point
  LaundryLiveActivity.swift        Lock Screen and Dynamic Island views
Tools/
  GenerateAppIcon.swift            Regenerates the three AppIcon variants
```

## Vocabulary

The app uses SSSB's own words, with Aptus's labels wherever Aptus is what the
resident sees on screen:

| Term            | Means                                                              |
| --------------- | ------------------------------------------------------------------ |
| laundry room    | The room, at the address SSSB lists for your building               |
| session         | One booked time — what SSSB counts and what "max future bookings" caps |
| group           | Aptus's own `Grupp 1` / `Grupp 2` within a room; a booking covers 1–2 |
| timeslot        | A bookable window in the week list, before it is anyone's session   |
| object number   | The `1234-5678-901` from the rental agreement; sign-in              |
| Aptus tag       | The fob you tag in with, within 15 minutes of the start             |

SSSB's "time after booking" is how long your tag still opens the laundry room once
the session has ended — 60 minutes at all but eight addresses, none at six of them.
The app shows it as "access after a session".

Not "machine" (a group is several), not "object id" (SSSB says number), and never
"category" — those are deliberately hidden from the client.

## Branding

The accent colour is SSSB's brand blue, `#064A88`, with `#3E8BC8` — the lighter blue
from the same palette — as the dark-appearance variant, because `#064A88` on a black
background falls below any usable contrast ratio.

The app icon is the `washer` SF Symbol at its default `.regular` weight, white on the
brand blue. It is generated rather than drawn:

```sh
swift Tools/GenerateAppIcon.swift
```

That writes all three variants into `AppIcon.appiconset`. The light one is opaque (App
Store validation rejects a marketing icon with an alpha channel); the dark and tinted
ones are transparent, because iOS supplies its own backdrop behind those and only uses
the glyph.

## Tests

`SSSBLaundryTests` and `SSSBLaundryUITests` targets are scaffolded but currently empty.

## Things that will bite you

- **Times are pinned to Europe/Stockholm** (`LaundryStore.todayInStockholm()`,
  `addDays`). Falling back to the device timezone skips or duplicates days. Slots can
  span midnight, so any time-window filter has to wrap around — `ActiveHoursSetting`
  treats `start > end` as wrap-around and `start == end` as "no filter", not an empty
  range.
- **`startAt`/`endAt` may or may not carry fractional seconds.**
  `CalendarService.parseISO8601` retries without `.withFractionalSeconds`; keep that
  fallback.
- **Push preferences: `@AppStorage` is the source of truth, the server is a mirror**
  that `PushService.syncToServer()` overwrites. Deregister on toggle-off, sign-out and
  `authFailed` — otherwise the server keeps pushing a stranger's bookings to this phone.
  Reminders are entirely server-driven; a local `UNTimeIntervalNotificationTrigger`
  implementation was reverted on purpose (`1e5429a`), don't reintroduce it.
- **The notification permission prompt sleeps 700 ms and hangs off the
  `NavigationStack`**, not `content`. An alert raised while the booking sheet is
  dismissing is dropped without a trace, and SwiftUI silently drops a second alert on a
  view that already has one.
- **The widget extension shares `Shared/` as a third source root.** All three roots are
  file-system-synchronized groups; `Shared/` is a member of both targets, so anything the
  app and the widget share goes there rather than being copied.
  `SSSBLaundryWidgets/Info.plist` is excluded from the extension's Copy Bundle Resources
  by a `PBXFileSystemSynchronizedBuildFileExceptionSet` — without it the build fails with
  "Multiple commands produce .../Info.plist".
- **`Color.accentColor` resolves against the *running* bundle**, which for a Live Activity
  is the widget extension, not the app. That is why `AccentColor` lives in
  `Shared/Assets.xcassets` and why both targets set
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`; with the colour in
  `SSSBLaundry/Assets.xcassets` alone the Lock Screen and Dynamic Island silently fall
  back to SwiftUI's default blue.
- **The Live Activity's phase flip is driven by `staleDate`, not by an update.** The app
  is normally suspended by the time the slot starts, so the widget resolves
  `state.phase == .grace || context.isStale`; the in-app supervisor task is the fast
  path, not the mechanism. `Activity.request` needs the foreground, which is why opening
  the app inside the lead hour is what starts it. Known limitation: the reminder pushes
  are visible alerts rather than silent ones, so if the app is never reopened the
  activity shows a spent countdown until the next launch reconciles it.
- **Calendar access is write-only** (`requestWriteOnlyAccessToEvents()`), so existing
  events can't be read. The `EKEventStore` must outlive the `EKEvent` — `PreparedEvent`
  carries both.
- **`LaundryRooms.all` is transcribed, not fetched.** SSSB fills the dropdown on
  <https://www.sssb.se/en/book-a-laundry-room/> from
  `wp-content/themes/sssb_pilot2/js/laundry.js`; that array is mirrored verbatim,
  their typos included, so a diff against the source stays readable. Nothing in the
  app is enforced from it — Aptus decides — and an unset room means the app shows no
  limits rather than asserting one, because "max future bookings" is 1 for 53 of the
  74 addresses and 2 for only 19.
- **"Max future bookings" counts sessions, not groups, and only future ones.** One
  booked time is one session however many groups it covers (`BookedSlot`), and a
  session that has already started stops counting — the machines may still be
  running, but the next slot can be booked. `LaundryStore.maxGroupsPerBooking` is a
  different limit: Aptus's own cap of two groups in one booking action.
- **Hidden groups are stored as a comma-separated string of ids**
  (`activeGroups.hiddenIds`), because `@AppStorage` can't hold a `Set<Int>`. Go through
  `ActiveGroupsSetting.parse`/`encode` rather than rolling your own.

## Publishing an update to TestFlight

The app ships via TestFlight under bundle id `se.floreteng.SSSBLaundry`. Each upload needs a unique build number; the marketing version only needs to change for user-visible releases. TestFlight builds expire 90 days after upload — refreshing an expired build is just a build-number bump and a re-upload.

`CURRENT_PROJECT_VERSION` in the pbxproj is the *next* build number to use only if every past upload was committed. If an upload fails with `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE` ("The bundle version must be higher than the previously uploaded version"), check the actual latest build in App Store Connect and bump past it.

1. **Bump the version** in the `SSSBLaundry` target → General, or directly in `SSSBLaundry.xcodeproj/project.pbxproj`:
   - `CURRENT_PROJECT_VERSION` — increment for every upload (e.g. `1` → `2`).
   - `MARKETING_VERSION` — bump for user-visible releases (e.g. `1.0` → `1.1`).
2. **Commit** the version bump so the archive matches a tagged state. Optionally `git tag v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`.
3. **Archive** in Xcode:
   - Select destination **Any iOS Device (arm64)** (not a simulator).
   - Product → Archive. The Organizer opens when it finishes.
4. **Upload** from the Organizer:
   - Select the new archive → Distribute App → TestFlight & App Store → Upload.
   - Let Xcode manage signing.
5. **Wait for processing** in [App Store Connect](https://appstoreconnect.apple.com/) (usually 5–30 min). You'll get an email when the build is ready.
6. **Release to testers**:
   - Internal testers get the build automatically once processing finishes.
   - External testers need the build added to their group. The first build of a new `MARKETING_VERSION` triggers Beta App Review (typically <24h); subsequent build-number-only bumps within the same version skip review.

### Uploading from the command line

Instead of the Organizer, steps 3–4 can be done headlessly with the App Store Connect account already signed in to Xcode:

```sh
xcodebuild archive -project SSSBLaundry.xcodeproj -scheme SSSBLaundry \
  -destination 'generic/platform=iOS' -archivePath /tmp/SSSBLaundry.xcarchive \
  -allowProvisioningUpdates

# ExportOptions.plist: method=app-store-connect, destination=upload,
# teamID=XQ9HKBVB36, signingStyle=automatic, manageAppVersionAndBuildNumber=false
env PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive \
  -archivePath /tmp/SSSBLaundry.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath /tmp/export -allowProvisioningUpdates
```

The stripped `PATH` matters: Xcode's IPA packaging step runs `/usr/bin/rsync` (openrsync) with `-E`, and if Homebrew's rsync is earlier on `PATH` it serves the other end of the transfer and rejects `--extended-attributes`, failing the export with a bare `error: exportArchive Copy failed`. The real cause is only visible in the `.xcdistributionlogs` bundle printed at the top of the output.

### Things to keep working

- `NSCalendarsWriteOnlyAccessUsageDescription` must stay set (via `INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription` in the pbxproj) — App Review rejects builds that prompt for calendar access without it.
- The backend at the URL in `Config.swift` must be reachable during Beta App Review.
- App Store Connect → App Review Information should list a working demo object number so reviewers can get past the sign-in screen.
- Encryption export compliance: `ITSAppUsesNonExemptEncryption` should remain `NO` (HTTPS-only, no custom crypto). Set it in Info.plist to skip the per-build prompt.
