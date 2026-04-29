# CLAUDE.md

Non-obvious context for working in this repo. Read [`api-spec.md`](./api-spec.md) for the full HTTP contract and [`README.md`](./README.md) for setup.

## Project overview

Native iOS app (SwiftUI, iOS 26+, Xcode 26+) for browsing and booking SSSB student-housing laundry timeslots. The user signs in with an SSSB **object id** (`1234-5678-901`) which authenticates every request. Core flows: view a week of timeslots, book/cancel 1–2 groups in one timeslot, optionally add the booking to the system calendar with a reminder at the timeslot start. Filters for active hours and visible groups handle multi-building object ids.

The app talks to a companion HTTP backend (default `https://sssb-laundry.eliasf.se`, configured in `SSSBLaundry/Config.swift`). There is no other backend dependency and no local persistence beyond `UserDefaults`.

Key files:

- `LaundryStore.swift` — `@Observable` store, owns week loading, pagination, book/cancel.
- `APIClient.swift` — thin URLSession client, injects `X-Object-Id`, decodes structured errors.
- `Models.swift` — Decodable DTOs plus `ActiveHoursSetting` / `ActiveGroupsSetting` helpers.
- `WeekView.swift` / `BookingSheet.swift` — main UI surfaces.
- `CalendarService.swift` — EventKit write-only integration.
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

## State and concurrency

- `LaundryStore` is `@Observable` (Swift Observation, not Combine). Mutate it from the main actor only — async API calls are awaited then state is assigned on resume.
- Task cancellation during view teardown is expected. `LaundryStore.isCancellation` filters `CancellationError` and `URLError.cancelled` so cancelled fetches don't surface as user-facing errors. Preserve this when adding new awaited calls.

## Configuration

- Base URL lives in `Config.swift` and is currently hardcoded to a single environment. There is no scheme/build-config switching yet — if you add staging/prod, do it via xcconfig rather than runtime flags so the object id never leaks to the wrong host.

## Build

- iOS deployment target is **26.0** (some configs are 26.4). Don't lower it without checking SwiftUI APIs in use (`@Observable`, write-only EventKit access, etc.).
- Tests targets exist but are empty stubs.
