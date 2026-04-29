# SSSB Laundry

A native iOS app for browsing and booking laundry timeslots in SSSB student housing. Built with SwiftUI.

## Features

- View the full week of laundry timeslots for your apartment
- Book or cancel 1–2 groups per timeslot in a single action
- Filter the list to active hours and to a subset of laundry groups (useful when an object id covers multiple buildings)
- Add bookings to the system calendar with a reminder at the timeslot start
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
  ObjectIdStore.swift      UserDefaults wrapper for the object id
  Config.swift             Base URL
```

## Tests

`SSSBLaundryTests` and `SSSBLaundryUITests` targets are scaffolded but currently empty.
