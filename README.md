# SSSB Laundry

A native iOS app for browsing and booking laundry timeslots in SSSB student housing. Built with SwiftUI.

## Features

- View the full week of laundry timeslots for your apartment
- Book or cancel 1–2 groups per timeslot in a single action
- Filter the list to active hours and to a subset of laundry groups (useful when an object id covers multiple buildings)
- Add bookings to the system calendar with a reminder at the timeslot start
- Optional local reminders before a booked timeslot, with two configurable alert offsets (Calendar.app style)
- A Live Activity in the hour before a booking, counting down to the start and then through the 15 minutes before it is released
- Pull-to-refresh and infinite scroll into future weeks

## Requirements

- Xcode 26+
- iOS 26.0+
- A valid SSSB object id (format: `1234-5678-901`)
- The companion backend service running at the URL set in `SSSBLaundry/Config.swift` (default: `https://sssb-laundry.eliasf.se`). The HTTP contract is documented in [`api-spec.md`](./api-spec.md).

## Getting started

1. Open `SSSBLaundry.xcodeproj` in Xcode.
2. Select an iOS 26 simulator or device and run the `SSSBLaundry` scheme.
3. On first launch, enter your object id. It is stored in `UserDefaults` and sent as the `X-Object-Id` header on every request.

## Project layout

```
SSSBLaundry/
  SSSBLaundryApp.swift     App entry point
  RootView.swift           Switches between sign-in and main view
  WeekView.swift           Weekly timeslot list, pagination, filters
  TimeslotRow.swift        Single timeslot row
  BookingSheet.swift       Book/cancel sheet for one timeslot
  EventEditView.swift      Calendar event editor wrapper
  SettingsView.swift       Object id, visible groups, active hours
  ObjectIdSetupView.swift  First-run sign-in
  GroupChip.swift          Group status chip
  APIClient.swift          HTTP client (URLSession)
  Models.swift             Decodable DTOs and settings helpers
  LaundryStore.swift       @Observable store (week loading, actions)
  CalendarService.swift    EventKit integration
  NotificationService.swift Local booking reminders and alert settings
  LiveActivityService.swift App side of the booking Live Activity
Shared/
  LaundryActivityAttributes.swift  ActivityKit model, built into both targets
SSSBLaundryWidgets/
  SSSBLaundryWidgetsBundle.swift   Widget extension entry point
  LaundryLiveActivity.swift        Lock Screen and Dynamic Island views
  ObjectIdStore.swift      UserDefaults wrapper for the object id
  Config.swift             Base URL
```

## Tests

`SSSBLaundryTests` and `SSSBLaundryUITests` targets are scaffolded but currently empty.

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
- App Store Connect → App Review Information should list a working demo object id so reviewers can get past the sign-in screen.
- Encryption export compliance: `ITSAppUsesNonExemptEncryption` should remain `NO` (HTTPS-only, no custom crypto). Set it in Info.plist to skip the per-build prompt.
