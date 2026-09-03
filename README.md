# SSSB Laundry

Book laundry timeslots in SSSB student housing from your phone, instead of from the
Aptus terminal in the basement.

Two halves of one product, in one repo:

| Path            | What it is                                                                   |
| --------------- | ---------------------------------------------------------------------------- |
| [`app/`](./app) | Native iOS app — SwiftUI, iOS 26+, with a Live Activity and push reminders    |
| [`api/`](./api) | The backend it talks to — Bun + Fastify, wrapping SSSB's Aptus Portal in JSON |

The app is distributed through TestFlight under `se.floreteng.SSSBLaundry`; the API runs
at `https://sssb-laundry.eliasf.se`.

That same host serves the app's landing page at its root, out of
[`api/site`](./api/site) — one static page, no build step.

## What it does

- The whole week of timeslots for your apartment, with infinite scroll into future weeks
- Book or cancel 1–2 laundry groups in a single action, with per-group results
- The booking rules SSSB publishes for your laundry room, picked by street address
- Push reminders before a booking — sent by the server, so a booking someone else in the
  apartment made still reaches your phone with the app closed, and taken back down again
  if the booking is cancelled
- A Live Activity in the hour before the slot, counting down to the start and then
  through the 15 minutes before the session is released again
- Optional calendar event with a reminder at the timeslot start

Sign-in is the SSSB **object number** (`1234-5678-901`) — SSSB's own word for it, and
what Aptus uses as both username and password. It is stored on the device and sent as
the `X-Object-Id` header.

## Running it

The API:

```sh
cd api
bun install
bun run dev        # http://0.0.0.0:3000
```

The app:

```sh
open app/SSSBLaundry.xcodeproj
```

Then run the `SSSBLaundry` scheme on an iOS 26 simulator or device. Point
`app/SSSBLaundry/Config.swift` at your own API if you are not using the deployed one.

Each half has its own README with the details — [`app/README.md`](./app/README.md) covers
the Xcode project layout and TestFlight releases, [`api/README.md`](./api/README.md) the
endpoints, upstream quirks and environment.

## What spans both halves

There is no generated client and no schema file: the wire format lives in `api/src` and
is hand-mirrored in `app/SSSBLaundry/APIClient.swift` and `Models.swift`. A change to a
route, header, status code or DTO belongs in one commit across both. The rest of this
list is duplicated in code by necessity — changing one side alone is a silent bug, not a
compile error.

- **Notification offsets.** `BookingAlert`'s raw values in
  `app/SSSBLaundry/NotificationSettings.swift` *are* the minutes the server stores as
  `alertMinutes` / `secondAlertMinutes` (`-1` = off, `0` = at start). The app is the
  source of truth and overwrites the server on sync; the server just mirrors.
- **The 15-minute activation grace.** A booking not activated on the machine within 15
  minutes of the start is released upstream. `laundryGracePeriod` in
  `app/Shared/LaundryActivityAttributes.swift` and `GRACE_SECONDS` in
  `api/src/notifications.ts` are the same 15 minutes, spelled twice.
- **`canBook` / `canCancel` are what the app is allowed to offer.** They mirror the book
  button and unbook link Aptus renders, and the API refuses the action without them, so
  the app blocks whatever they rule out instead of sending a request that can only come
  back as an error. `app/SSSBLaundry/BookingRules.swift` holds that line on the client
  side; the per-room session quota sits deliberately on the other side of it, as a
  warning only.
- **A cancelled booking retracts its notifications.** Nothing on the server can reach
  into Notification Center, so a slot that stops existing is pushed as a silent
  `kind: "cancelled"` payload and the app clears every notification it has already been
  given whose `startAt` matches. That match is the contract: `startAt` stays in every
  payload, the app carries `UIBackgroundModes = remote-notification` for the silent push
  to arrive at all, and both sides count only a slot with no groups left as cancelled —
  dropping one group of two leaves a booking the notification still describes.
- **`timeslotId` is opaque and content-derived** from `{startAt, endAt}` only. It carries
  no user or group identity, so the server regenerates it at send time and the app must
  never construct, parse or persist it — always use the id from the latest
  `GET /timeslots`.
- **Europe/Stockholm, always.** Portal dates arrive without a timezone, timeslots can
  span midnight, and DST is real. Neither side may fall back to the device's timezone.
- **Object ids are sensitive.** They are username *and* password upstream. Never commit
  a real one (fixtures included), never log one. This repo is public.

## Deploying

The two halves ship on different tracks, and a push to `main` only moves one of them.

**API** — `compose.yaml` at the root builds `./api`:

```sh
docker compose up -d --build
```

Production is a checkout of this repo on the VPS. The Traefik labels and the APNs
credentials live beside it in untracked `compose.override.yaml` and `.env`; the override
also replaces the published port. `./data` is a bind mount and must be writable by uid
1000 — losing it drops every device token and queued reminder.

**App** — TestFlight, uploaded from Xcode. Nothing about a push to `main` ships an app
build; see [`app/README.md`](./app/README.md).
