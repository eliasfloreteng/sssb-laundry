# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS app for booking and managing laundry sessions at SSSB (Stockholm student housing). It communicates with the AptusPortal web app by scraping and parsing its HTML responses — there is no REST API.

## Build & Run

Open `laundry.xcodeproj` in Xcode 16+, resolve SPM packages, build and run. Target: iOS 26.2+.

```bash
# Build from CLI
xcodebuild -project laundry.xcodeproj -scheme laundry -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -project laundry.xcodeproj -scheme laundry -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Architecture

MVVM with a service layer. Uses Swift `@Observable` macro (not Combine/ObservableObject). ViewModels are injected via SwiftUI `.environment()`.

**Data flow:** Views → ViewModels → `AptusService` (singleton actor) → HTTP requests to AptusPortal → `HTMLParser` (SwiftSoup) → Model structs

- `AptusService` is a Swift `actor` (thread-safe singleton) that manages all HTTP communication including cookie-based session management
- `HTMLParser` is a stateless enum with static methods that parse HTML responses using SwiftSoup CSS selectors
- `KeychainService` stores credentials as `username:password` in a single keychain entry
- `PasswordEncoder` XOR-encodes passwords with a server-provided salt

**Auth flow:** GET login page → extract `PasswordSalt` + `__RequestVerificationToken` → XOR-encode password → POST login → verify `.ASPXAUTH` cookie. Session expiry is detected when responses redirect to the login page, triggering automatic re-authentication using stored keychain credentials.

## Key Patterns

- All network calls go through `fetchHTML()` / `fetchAJAX()` private helpers in `AptusService`, which handle session expiry detection and one retry with re-authentication
- Booking actions (book/unbook) return a feedback message string parsed from `FeedbackDialog('...')` in the response HTML
- `CalendarViewModel` is shared between the Quick Book (FirstAvailableView) and Calendar (WeekCalendarView) tabs
- Laundry groups (Grupp 1 id=185, Grupp 2 id=186) have hardcoded fallback defaults in `CalendarViewModel`
- `TimeSlot.Status` enum: `.available` (green/bookable), `.own` (blue/user's booking), `.unavailable` (gray/taken)

## Dependencies

- **SwiftSoup** — HTML parsing (SPM)
- LRUCache, swift-atomics — transitive dependencies
