# SSSB Laundry

Book laundry timeslots in SSSB student housing from your phone, instead of from the
Aptus terminal in the basement.

Two halves of one product, in one repo:

| Path            | What it is                                                                       |
| --------------- | -------------------------------------------------------------------------------- |
| [`app/`](./app) | Native iOS app — SwiftUI, iOS 26+, with a Live Activity and push reminders        |
| [`api/`](./api) | The backend it talks to — Bun + Fastify, wrapping SSSB's Aptus Portal in JSON     |
| [`docs/`](./docs) | [`api-spec.md`](./docs/api-spec.md), the HTTP contract between the two           |

The app is distributed through TestFlight under `se.floreteng.SSSBLaundry`; the API runs
at `https://sssb-laundry.eliasf.se`.

## What it does

- The whole week of timeslots for your apartment, with infinite scroll into future weeks
- Book or cancel 1–2 laundry groups in a single action, with per-group results
- Push reminders before a booking — sent by the server, so a booking someone else in the
  apartment made still reaches your phone with the app closed
- A Live Activity in the hour before the slot, counting down to the start and then
  through the 15 minutes before the machine is released again
- Optional calendar event with a reminder at the timeslot start

Sign-in is the SSSB **object id** (`1234-5678-901`), which is what Aptus itself uses as
both username and password. It is stored on the device and sent as `X-Object-Id`.

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
endpoints and environment.

## Deploying the API

`compose.yaml` at the root builds `./api`:

```sh
docker compose up -d --build
```

Production is a checkout of this repo on the VPS, with the Traefik labels and the APNs
credentials kept beside it in untracked `compose.override.yaml` and `.env`.
