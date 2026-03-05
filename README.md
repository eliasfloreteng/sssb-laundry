# SSSB Laundry

iOS app for booking and managing laundry sessions at SSSB residences. Communicates with the AptusPortal web app by parsing its HTML responses.

## Features

- **My Bookings** — View active bookings with pull-to-refresh, cancel with confirmation
- **Quick Book** — See the next 10 available slots across all groups, book with one tap
- **Calendar** — Weekly grid view with Grupp 1/Grupp 2 picker, week navigation, color-coded slots (green=available, blue=yours, gray=taken)
- **Auto-login** — Optional Keychain-stored credentials with "Remember me" toggle

## Architecture

MVVM + Service layer, targeting iOS 26.2+.

```
Models/          Data types (Booking, TimeSlot, LaundryGroup, WeekCalendar)
Services/        AptusService (networking), HTMLParser (SwiftSoup), KeychainService, PasswordEncoder
ViewModels/      AuthViewModel, BookingsViewModel, CalendarViewModel
Views/           LoginView, MainTabView, BookingsView, FirstAvailableView, WeekCalendarView
```

## Dependencies

- [SwiftSoup](https://github.com/scinfu/SwiftSoup) — HTML parsing (SPM)

## Auth Flow

1. `GET /Account/Login` → extract `PasswordSalt` and `__RequestVerificationToken`
2. XOR-encode password with salt
3. `POST /Account/Login` → verify `.ASPXAUTH` cookie is set
4. Session expiry detected via redirect to login page

## Building

Open `laundry/laundry.xcodeproj` in Xcode 16+, resolve packages, and run on a simulator or device.

## New features

- [x] Automatically re-authenticate when session expires and the app is still open
- [x] Loading indicators and error display
- [ ] Notification before booking (with live updating time and time sensitive)
- [ ] Dates displayed in relative time when close (parse dates)
- [ ] Splash screen with more info and not just white
- [ ] Also display previous bookings (history)
- [ ] Allow pull to refresh when pages are empty
- [ ] Wash timer for when to take out the clothes
- [ ] Notification on unclaimed bookings from others, they expire if not claimed after 15 minutes (only if at home)
- [ ] Replace br tags in responses with newlines
