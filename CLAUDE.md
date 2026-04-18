# CLAUDE.md

SwiftUI iOS app for booking SSSB laundry slots. Xcode project — no package manager, no build scripts outside Xcode.

## Architecture

- **Entry:** [sssb_laundryApp.swift](sssb-laundry/sssb_laundryApp.swift) creates a single `Session` `@StateObject` and injects it as an `environmentObject`. Every view that needs auth state reads `@EnvironmentObject private var session: Session`.
- **Routing:** [ContentView.swift](sssb-laundry/ContentView.swift)'s `RootView` switches between `SignInView` and `MainTabView` based on `session.isAuthenticated`. There is no navigation framework beyond `NavigationStack` inside tabs.
- **Auth:** [Session.swift](sssb-laundry/Session.swift) stores the apartment number in `@AppStorage("objectId")`. There is no password or token — the object ID *is* the credential and is sent as `X-Object-Id` on every request.
- **Networking:** [APIClient.swift](sssb-laundry/APIClient.swift) is a `final class ... @unchecked Sendable` singleton (`APIClient.shared`). All HTTP goes through the private `request(...)` helper which sets headers, decodes `APIError` on non-2xx, and prints bodies in `#if DEBUG`. Base URL is hardcoded to the Cloudflare Workers API.
- **Models:** [Models.swift](sssb-laundry/Models.swift) — plain `Codable` structs. Dates are decoded with a custom strategy that accepts ISO 8601 with and without fractional seconds.
- **Pagination:** `SlotsPage` / `BookingsPage` carry an optional `nextCursor`. The client falls back to decoding a bare array if the response isn't paginated.

## Conventions

- Views are `struct`s with `#Preview` at the bottom seeded with `Session()`.
- All async work goes through `Task { ... }` inside view methods; errors surface as `APIError` (which conforms to `LocalizedError`) or fall through to generic messages.
- `@AppStorage` is used for lightweight user prefs (`objectId`, `activeHoursStart`, `activeHoursEnd`). No Core Data / SwiftData despite the leftover [Item.swift](sssb-laundry/Item.swift) stub.
- Styling leans on SF Symbols, `Color.accentColor`, and `RoundedRectangle` backgrounds. No third-party UI libraries.

## Gotchas

- [Item.swift](sssb-laundry/Item.swift) is a SwiftData-era leftover and isn't used — don't build features on it.
- `Session` is `@MainActor`; don't call it from background tasks without hopping to the main actor.
- The API base URL is hardcoded in `APIClient.swift`. If you need a staging env, add an `#if DEBUG` branch rather than a build setting.
- `BookingPreference` raw values are `"both"`, `"1"`, `"2"`, `"any"` — match those exactly when sending to the API.

## Tests

- [sssb-laundryTests](sssb-laundryTests/) and [sssb-laundryUITests](sssb-laundryUITests/) exist but are essentially empty Xcode templates. Run via `Cmd+U` in Xcode.
