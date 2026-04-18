# SSSB Laundry

A SwiftUI iOS app for browsing and booking laundry time slots at SSSB (Stockholms Studentbostäder) housing.

## Overview

The app talks to a backend at `https://sssb-laundry-api.eliasfloreteng.workers.dev` (a Cloudflare Workers API that proxies the SSSB booking system). Authentication is done with the tenant's apartment/object number, which is stored locally via `@AppStorage` and sent as the `X-Object-Id` header on every request.

## Features

- Sign in with an SSSB apartment number
- Browse available laundry slots with pagination
- Book a slot for group 1, group 2, both, or any
- View current and upcoming bookings
- Cancel individual bookings or all bookings on a slot
- Profile view with account info and configurable active hours

## Project Structure

- [sssb_laundryApp.swift](sssb-laundry/sssb_laundryApp.swift) — app entry point, injects `Session` into the environment
- [Session.swift](sssb-laundry/Session.swift) — `@MainActor ObservableObject` that owns auth state and the `MeResponse`
- [APIClient.swift](sssb-laundry/APIClient.swift) — single shared client that handles all HTTP requests and JSON decoding
- [Models.swift](sssb-laundry/Models.swift) — `Codable` models (`Slot`, `Booking`, `MeResponse`, `APIError`, etc.)
- [ContentView.swift](sssb-laundry/ContentView.swift) — `RootView` routes between `SignInView` and `MainTabView`
- [MainTabView.swift](sssb-laundry/MainTabView.swift) — tab bar with Slots, Bookings, and Profile tabs
- [SlotsView.swift](sssb-laundry/SlotsView.swift) / [SlotDetailView.swift](sssb-laundry/SlotDetailView.swift) — slot browsing and booking
- [BookingsView.swift](sssb-laundry/BookingsView.swift) — current and historical bookings
- [ProfileView.swift](sssb-laundry/ProfileView.swift) — account info, active-hours setting, sign-out
- [SignInView.swift](sssb-laundry/SignInView.swift) — apartment-number entry screen

## Requirements

- Xcode 15+
- iOS 17+ target
- A valid SSSB apartment/object number

## Building

Open `sssb-laundry.xcodeproj` in Xcode and run the `sssb-laundry` scheme on a simulator or device.

## API

All endpoints require the `X-Object-Id` header:

- `GET /me` — tenant info
- `GET /slots` — list bookable slots (supports `cursor`, `limit`, `include=all`)
- `POST /slots/{date}/{passNo}/book` — book a slot (body: `{ "prefer": "both" | "1" | "2" | "any" }`)
- `GET /bookings` — current bookings
- `GET /bookings/history` — historical bookings (paginated)
- `DELETE /bookings/{id}` — cancel one booking
- `DELETE /slots/{date}/{passNo}/bookings` — cancel all bookings on a slot
