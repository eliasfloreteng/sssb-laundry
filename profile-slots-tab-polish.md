# Profile + Slots tab polish

## Context

Five small UX/dev-quality improvements to the SSSB Laundry iOS app:

1. The API base URL is hardcoded in `APIClient.swift`, which makes it painful to point the app at a staging/dev Workers deployment. We want a Profile-level setting so the URL can be changed without a rebuild.
2. Active hours (e.g. `08:00–01:00`) can't currently cross midnight — the Profile form shows an orange "End must be after start" warning, and `visibleSlots` assumes `start < end`. Laundry slots often run late, so users need a wrap-around range.
3. The "All" toggle in the top-right of the Slots tab is redundant UI; remove it.
4. Each timeslot row shows two right-chevrons — one from the `NavigationLink`, one explicit `chevron.right` inside `SlotRow`. The explicit one is visual noise.
5. The timeslot row's sub-text currently shows `"Group 1 · free • Group 2 · taken"`. Users only care which groups they *can* book — we'll show only bookable group names.

---

## Changes

### 1. Configurable API base URL

**File:** `sssb-laundry/APIClient.swift`

- Add a `static let defaultBaseURL = "https://sssb-laundry-api.eliasfloreteng.workers.dev"` constant on `APIClient`.
- Replace the stored `private let baseURL = URL(...)` (line 11) with a computed `private var baseURL: URL` that reads `UserDefaults.standard.string(forKey: "apiBaseURL")`, falls back to `defaultBaseURL` if the value is nil or empty or an invalid URL. This way the running singleton picks up changes without having to recreate it.

**File:** `sssb-laundry/ProfileView.swift`

- Add `@AppStorage("apiBaseURL") private var apiBaseURL: String = ""` (empty string means "use default"). Using `""` as the "unset" sentinel matches the existing `objectId` pattern and keeps the default string out of UserDefaults until the user explicitly changes it.
- Add a new `Section` placed **between "Booking groups" and "Sign out"** titled `"Advanced"`:
  - A `TextField("API URL", text: $apiBaseURL, prompt: Text(APIClient.defaultBaseURL))` with `.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`, `.keyboardType(.URL)`, and `.textContentType(.URL)`.
  - Footer text explaining: "Leave blank to use the default. Changes apply to the next request."
  - A small "Reset" button inline that sets `apiBaseURL = ""` when the field is non-empty (optional nicety; keep it simple with a trailing button in the same row).

### 2. Active hours can cross midnight

**File:** `sssb-laundry/SlotsView.swift`

Replace the `visibleSlots` filter body (lines 160–172). New semantics: if `activeHoursStart < activeHoursEnd`, behave as today. If `activeHoursStart >= activeHoursEnd`, treat the range as a wrap-around window `[start, 24) ∪ [0, end]`.

Sketch:

```swift
private var visibleSlots: [Slot] {
    guard activeHoursEnabled else { return vm.slots }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return vm.slots.filter { slot in
        let startHour = cal.component(.hour, from: slot.startsAt)
        let endComponents = cal.dateComponents([.hour, .minute], from: slot.endsAt)
        let endHour = endComponents.hour ?? 0
        let endMinute = endComponents.minute ?? 0
        let endEffective = (endHour == 0 && endMinute == 0) ? 24 : endHour + (endMinute > 0 ? 1 : 0)

        if activeHoursStart < activeHoursEnd {
            return startHour >= activeHoursStart && endEffective <= activeHoursEnd
        } else {
            // Wrap-around: slot must fit entirely in [start, 24] OR [0, end]
            let fitsLate    = startHour >= activeHoursStart && endEffective <= 24
            let fitsEarly   = startHour >= 0 && endEffective <= activeHoursEnd
            return fitsLate || fitsEarly
        }
    }
}
```

Also update `activeHoursEnabled` so that `start == end` (covers nothing) still counts as "enabled" only if it's not the full-day default. Current check `activeHoursStart != 0 || activeHoursEnd != 24` already works for the `start < end` case; for wrap-around the same check still triggers filtering, which is correct.

**File:** `sssb-laundry/ProfileView.swift`

- Remove the orange warning at lines 41–45 (`if activeHoursStart >= activeHoursEnd { Label("End must be after start.", ...) }`). Wrap-around is now valid.
- Update the footer at line 49 from `"Slots outside these hours are hidden. Set 00:00–24:00 to show all."` to something like `"Slots outside these hours are hidden. If the end time is before the start, the range wraps past midnight (e.g. 08:00–01:00)."`

### 3. Remove the "All" toggle

**File:** `sssb-laundry/SlotsView.swift`

- Delete the entire `ToolbarItem(placement: .topBarTrailing) { Toggle(isOn: $vm.includeAll) ... }` block (lines 108–116) and the trailing `.onChange(of: vm.includeAll) { ... }` modifier (lines 122–124).
- Delete `@Published var includeAll = false` on `SlotsViewModel` (line 16) — with no UI toggling it, the property is dead.
- Update the two `APIClient.shared.slots(...)` call sites (lines 29 and 45) to drop the `includeAll:` argument; it already defaults to `false` in the API client signature, so this is a no-op.
- Simplify `emptySubtitle` (lines 174–179): remove the `vm.includeAll ? ... : ...` branch. The remaining message can just be `"Nothing to show right now."` (with the active-hours branch unchanged).

Leave `APIClient.slots(objectId:includeAll:cursor:limit:)` as-is — the parameter still has a valid default and could be useful later; removing it is scope creep.

### 4. Remove the duplicate chevron

**File:** `sssb-laundry/SlotsView.swift`, `SlotRow.body` (lines 230–239)

Remove only the `else if slot.bookable { Image(systemName: "chevron.right") ... }` branch. The `NavigationLink` wrapping each row already renders its own disclosure chevron, so the bookable case falls through to no trailing icon and gets the NavigationLink chevron alone.

Keep:
- `Image(systemName: "checkmark.seal.fill")` for `slot.bookedByMe`
- `Image(systemName: "lock.fill")` for the unbookable case

After the edit the `if/else if/else` becomes an `if/else`:

```swift
if slot.bookedByMe {
    Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(.green)
} else if !slot.bookable {
    Image(systemName: "lock.fill")
        .foregroundStyle(.tertiary)
}
```

### 5. Sub-text shows only bookable group names

**File:** `sssb-laundry/SlotsView.swift`, `SlotRow` (lines 256–268)

- Change `groupsSummary` to filter groups by `status == "bookable"` and join just the names:

```swift
private var groupsSummary: String {
    slot.groups
        .filter { $0.status == "bookable" }
        .map(\.name)
        .joined(separator: ", ")
}
```

- Delete the now-unused `humanStatus(_:)` helper (lines 260–268).
- If `groupsSummary` is empty (no bookable groups), `Text("")` would still render an empty row — guard with `if !groupsSummary.isEmpty { Text(groupsSummary)... }` inside the `VStack` at lines 218–226 so the status line sits tight when there are no bookable groups (mostly the already-booked or unavailable case, where showing nothing is cleaner).

---

## Critical files

- `/Users/elias/Downloads/sssb-laundry/sssb-laundry/APIClient.swift` — add `defaultBaseURL`, convert `baseURL` to a computed `var` reading UserDefaults.
- `/Users/elias/Downloads/sssb-laundry/sssb-laundry/ProfileView.swift` — add Advanced section with API URL field; remove end-after-start warning; update active-hours footer text.
- `/Users/elias/Downloads/sssb-laundry/sssb-laundry/SlotsView.swift` — remove "All" toolbar + onChange + `includeAll` prop + `includeAll:` args; rewrite `visibleSlots` for wrap-around; remove explicit `chevron.right`; simplify `groupsSummary` to bookable-only names and drop `humanStatus`.

## Reused pieces (don't reinvent)

- `@AppStorage` string pattern — mirror `objectId` in `Session.swift:12`.
- `APIClient.shared` singleton stays the singleton; only its URL source changes. No changes needed in `Session.swift` or any view model.
- Existing `Section`/`labeledRow` idioms in `ProfileView.swift` — reuse them for the Advanced section's layout.

## Verification

1. **API URL setting**
   - Build & run in Xcode simulator. Open Profile → Advanced, leave blank → app should still hit the production Workers URL (visible in the `[API]` DEBUG prints from `APIClient.swift:59`).
   - Paste a bogus URL like `https://example.invalid` → pull-to-refresh on Slots; expect a failure state. Clear the field → next refresh succeeds.
   - Paste the production URL explicitly (same as default) → everything still works.
2. **Active hours wrap-around**
   - In Profile, set From `22` / To `02`. Confirm the orange warning is gone and the footer now mentions wrap-around.
   - Return to Slots. Confirm only slots starting ≥ 22 or ending ≤ 02 appear.
   - Set From `08` / To `17` (normal case) — unchanged behaviour.
   - Set From `00` / To `24` — filtering disabled, all slots visible.
3. **"All" toggle removed**
   - Slots tab top-right should have no toggle. Empty-state subtitle no longer mentions "Show all".
4. **Single chevron**
   - A bookable slot row shows exactly one chevron (from NavigationLink). A booked-by-you row shows a green checkmark + the NavigationLink chevron. An unbookable row shows a lock + the NavigationLink chevron.
5. **Group names sub-text**
   - A slot with groups `[{name: "A", status: "bookable"}, {name: "B", status: "taken"}]` shows `"A"` as sub-text (no `"· free"`, no `"B"`).
   - A slot with no bookable groups shows no sub-text line (only the status label on top).
6. **Tests** — no existing test coverage beyond empty templates; run `Cmd+U` to confirm the project still builds and the template tests pass.
