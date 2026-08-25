# app

Non-obvious context for working on the iOS app. Read [`../docs/api-spec.md`](../docs/api-spec.md) for the full HTTP contract, [`README.md`](./README.md) for setup, and [`../AGENTS.md`](../AGENTS.md) for what this half shares with [`../api`](../api) — the server that serves that contract lives in the same repo now, so a wire-format change is one commit across both.

## Project overview

Native iOS app (SwiftUI, iOS 26+, Xcode 26+) for browsing and booking SSSB student-housing laundry timeslots. The user signs in with an SSSB **object id** (`1234-5678-901`) which authenticates every request. Core flows: view a week of timeslots, book/cancel 1–2 groups in one timeslot, optionally add the booking to the system calendar with a reminder at the timeslot start. Filters for active hours and visible groups handle multi-building object ids.

The app talks to the HTTP backend in [`../api`](../api) (deployed at `https://sssb-laundry.eliasf.se`, configured in `SSSBLaundry/Config.swift`). There is no other backend dependency and no local persistence beyond `UserDefaults`.

Key files:

- `LaundryStore.swift` — `@Observable` store, owns week loading, pagination, book/cancel.
- `APIClient.swift` — thin URLSession client, injects `X-Object-Id`, decodes structured errors.
- `Models.swift` — Decodable DTOs plus `ActiveHoursSetting` / `ActiveGroupsSetting` helpers.
- `WeekView.swift` / `BookingSheet.swift` — main UI surfaces.
- `CalendarService.swift` — EventKit write-only integration.
- `PushService.swift` / `AppDelegate.swift` — APNs registration and preference sync.
- `NotificationSettings.swift` — `BookingAlert` offsets and the `@AppStorage` keys.
- `LiveActivityService.swift` — app side of the Live Activity; `Shared/LaundryActivityAttributes.swift` and `SSSBLaundryWidgets/` are the shared model and the widget extension.
- `RootView.swift` — switches between `ObjectIdSetupView` and `WeekView` based on stored object id.

## Auth and identity

- There is no real auth. Every request must carry the user's object id in the `X-Object-Id` header. `APIClient.makeRequest` enforces this and throws `MISSING_OBJECT_ID` locally if missing.
- The object id is stored in `UserDefaults` (`ObjectIdStore`, key `"objectId"`). Treat it as a secret-ish value: never log it, never commit fixtures containing real ids.
- `LaundryStore` maps both `AUTH_FAILED` and `MISSING_OBJECT_ID` to `authFailed = true`, which the UI uses to bounce the user back to sign-in.

## Booking domain rules (must surface in UI)

- A booking targets **one canonical timeslot and 1–2 groups**. Never send 0 or >2 groupIds.
- Categories are intentionally hidden by the API — do **not** introduce a category concept on the client.
- `timeslotId` is opaque. Never construct, parse, or persist it across server changes; always use the id from the latest `GET /timeslots`.
- Bookings auto-cancel **15 minutes after timeslot start** if not activated on the physical machine. The UI does not need to enforce this, but copy should reflect it. The calendar event fires a single alarm at the timeslot start so the user is reminded in time to activate the machine.
- After a successful book/cancel, refresh the affected week. `LaundryStore.refreshWeekContaining` already does this — preserve that behavior.
- Per-group `results[]` can mix success and failure; render partial states. Statuses that count as successful/idempotent: `booked`, `already_booked` (book) and `cancelled`, `not_booked` (cancel) — see `ActionResult.isSuccessful`.

## Time handling

- All server times are `Europe/Stockholm`. `LaundryStore.todayInStockholm()` and `addDays(...)` deliberately pin the timezone — do not switch to the user's local timezone or you will skip/duplicate days.
- Timeslots can span midnight (`spansMidnight: true`). Any time-window filtering must support wrap-around.
- The active-hours filter (`ActiveHoursSetting.includes`) treats `start > end` as wrap-around (e.g. 22:00 → 06:00). `start == end` means "no filter", not "empty range".
- `startAt`/`endAt` are ISO-8601 with offset and **may or may not include fractional seconds**. `CalendarService.parseISO8601` retries without `.withFractionalSeconds` — keep that fallback.

## Pagination

- The API has no explicit pagination cursor. `loadMoreIfNeeded` pages forward by calling `/timeslots?date=<lastWeek.toDate + 1 day>`.
- `reachedEnd` is set when an appended week comes back with `timeslots: []`. Don't replace this with a hard date cutoff — server-side availability windows vary by object id.

## Group display

- Group `name` from the API is noisy (often prefixed with "Vad skall bokas?" and a building/area string). `LaundryGroup.displayName` strips the question and `LaundryGroup.commonDisplayPrefix` computes a shared prefix across the loaded groups so the UI can show short labels. If you change either, check that single-group setups still render something non-empty.
- Visible groups are stored as a **comma-separated string of hidden ids** under `activeGroups.hiddenIds` (because `@AppStorage` doesn't support `Set<Int>`). Use `ActiveGroupsSetting.parse`/`encode`, don't roll your own.

## Calendar integration

- `Info.plist` requires `NSCalendarsWriteOnlyAccessUsageDescription` (set via `INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription` in the pbxproj). The app uses `requestWriteOnlyAccessToEvents()` — full read access is intentionally not requested, so don't try to read existing events.
- The `EKEventStore` must outlive the `EKEvent`; `PreparedEvent` carries both. Do not drop the store before the event editor commits.
- Event title is `"Tvätt <groups>"` (Swedish) with no notes/description, and a single alarm at offset `0` (timeslot start). Keep it terse — the user reviews the event in the system editor before saving.

## Push notifications

Reminders are **server-driven**. The server polls the object id and sends the
pushes, so a booking made by someone else on the same object id still notifies
this device with the app closed. There is no local scheduling — an earlier
`UNTimeIntervalNotificationTrigger` implementation was reverted on purpose
(`1e5429a`); do not reintroduce it.

- `@AppStorage` is the **source of truth** for the preferences; the server is a
  mirror that `PushService.syncToServer()` overwrites. Sync on launch, on
  permission granted, on either picker changing, on `scenePhase == .active`, and
  after registration. Deregister on toggle-off, sign-out and `authFailed` —
  otherwise the server keeps pushing a stranger's bookings to this phone.
- `syncToServer` sends `enabled` as `NotificationSetting.isEnabled && authorized`,
  so permission revoked in iOS Settings stops the server too, not just the UI.
- `BookingAlert` raw values *are* the minutes the server stores (`-1` = off,
  `0` = at start). Keep them aligned with `alertMinutes` in
  `../api/src/notifications.ts`.
- The permission prompt is offered **after a successful booking**, once, gated on
  `notifications.prompted` and `.notDetermined`. It sleeps 700 ms first: an alert
  raised while the booking sheet is dismissing is dropped without a trace. It is
  attached to the `NavigationStack`, not to `content`, because the error alert
  already owns that view and SwiftUI silently drops the second alert on a view.
- `APIClient` sends `X-Device-Token` on book/cancel so the server can skip this
  phone when it announces the booking to the other devices on the object id.
- `SSSBLaundry.entitlements` carries `aps-environment` and the Time Sensitive
  Notifications entitlement, wired via `CODE_SIGN_ENTITLEMENTS` in both build
  configs. `UIBackgroundModes` is deliberately *not* set — these are visible
  alert pushes, not silent ones.
- `AppDelegate` exists only for the APNs token callback and foreground banners;
  everything else stays pure SwiftUI.

## Live Activity

- The project has **three source roots**, all Xcode file-system-synchronized groups: `SSSBLaundry/` (app), `SSSBLaundryWidgets/` (the `com.apple.product-type.app-extension` widget target, bundle id `se.floreteng.SSSBLaundry.Widgets`), and `Shared/`, which is a member of *both* targets. `LaundryActivityAttributes` has to compile into both — put anything else they share in `Shared/`, never a second copy.
- `SSSBLaundryWidgets/Info.plist` declares `NSExtensionPointIdentifier`, and is excluded from the extension's Copy Bundle Resources phase by a `PBXFileSystemSynchronizedBuildFileExceptionSet` in the pbxproj. Without that exception the build fails with "Multiple commands produce .../Info.plist" — keep it if you touch the synchronized group.
- The app target needs `INFOPLIST_KEY_NSSupportsLiveActivities = YES`.
- The activity covers one booking at a time: the earliest whose window (`start - 1 h` through `start + 15 min`) contains now. `LiveActivityService.sync` starts, advances and ends it, and runs after every week fetch and on `scenePhase == .active`, so **opening the app inside the lead window is what starts it**. `Activity.request` requires the foreground, which is why there is no other trigger.
- Two phases: `.upcoming` counts down to the start, `.grace` counts down the 15 minutes before the machine releases the booking.
- **The phase flip is driven by `staleDate`, not by an update.** The app is normally suspended by the time the slot starts, so `sync` sets `staleDate` to the phase boundary and the widget resolves `state.phase == .grace || context.isStale`. The in-app supervisor `Task` pushes the real update and the ending when the app happens to be alive; treat it as the fast path, not the mechanism.
- Known limitation: the reminder pushes are visible alerts, not silent ones, so nothing wakes the app to end the activity at the deadline. If the app is never reopened it shows a spent countdown until the next launch reconciles it (or ActivityKit's own cap). Ending it on time needs `pushType: .token` and live-activity pushes from the server.
- `LaundryStore.bookedSlots` folds `heldBookings` (one row per machine, because the two-booking quota is counted per machine) into one entry per timeslot. Its `id` is derived from the start epoch and the group ids, never the opaque `timeslotId`.
- Countdown ranges in the widget are built from the booking's own dates, never `Date.now` — a range whose lower bound has drifted past its upper bound traps at render time.
- `ActivityContent(state:staleDate:)` cannot infer its generic from `.init(phase:)`; name `LaundryActivityAttributes.ContentState` explicitly.
- `laundryGracePeriod` in `Shared/` is the single source for the 15 minutes; `LaundryStore.activationGraceMinutes` derives from it.

## State and concurrency

- `LaundryStore` is `@Observable` (Swift Observation, not Combine). Mutate it from the main actor only — async API calls are awaited then state is assigned on resume.
- Task cancellation during view teardown is expected. `LaundryStore.isCancellation` filters `CancellationError` and `URLError.cancelled` so cancelled fetches don't surface as user-facing errors. Preserve this when adding new awaited calls.

## Configuration

- Base URL lives in `Config.swift` and is currently hardcoded to a single environment. There is no scheme/build-config switching yet — if you add staging/prod, do it via xcconfig rather than runtime flags so the object id never leaks to the wrong host.

## Build

- iOS deployment target is **26.0** (some configs are 26.4). Don't lower it without checking SwiftUI APIs in use (`@Observable`, write-only EventKit access, etc.).
- Tests targets exist but are empty stubs.
