# sssb-laundry

Both halves of one product: a native iOS app for booking SSSB laundry timeslots, and
the HTTP API it talks to (a wrapper around SSSB's Aptus Portal).

```
app/    SwiftUI iOS app + widget extension (Xcode 26, iOS 26+)  -> app/AGENTS.md
api/    Bun + Fastify HTTP API, SQLite, APNs                    -> api/AGENTS.md
docs/   api-spec.md, the HTTP contract between the two
compose.yaml  Deploy entrypoint for api/ (see Deployment below)
```

Work in the half you are changing and read that half's `AGENTS.md` first. This file is
only for what spans both — the things that used to be two repos silently disagreeing.

## The contract

`docs/api-spec.md` is the single description of the wire format. It used to exist as a
hand-maintained copy on each side; there is one now, and it is not generated from the
code. **A change to a route, header, status code or DTO in `api/src` must land in the
same commit as the matching change to `docs/api-spec.md` and to `app/SSSBLaundry/`
(`APIClient.swift`, `Models.swift`).** The whole point of the merge is that this is now
possible in one commit — do it.

## Shared invariants

These are duplicated in code on both sides by necessity. Changing one without the other
is a silent bug, not a compile error.

- **Notification offsets.** `BookingAlert`'s raw values in
  `app/SSSBLaundry/NotificationSettings.swift` *are* the minutes the server stores as
  `alertMinutes` / `secondAlertMinutes` (`-1` = off, `0` = at start). The app is the
  source of truth and overwrites the server on sync; the server just mirrors.
- **The 15-minute activation grace.** A booking not activated on the machine within 15
  minutes of the start is released upstream. `laundryGracePeriod` in
  `app/Shared/LaundryActivityAttributes.swift` and `GRACE_SECONDS` in
  `api/src/notifications.ts` are the same 15 minutes, spelled twice.
- **`timeslotId` is opaque and content-derived** from `{startAt, endAt}` only
  (`api/src/timeslot-id.ts`). It carries no user or group identity, so the server
  regenerates it at send time and the app must never construct, parse or persist it —
  always use the id from the latest `GET /timeslots`.
- **Europe/Stockholm, always.** Portal dates arrive without a timezone, timeslots can
  span midnight, and DST is real. Neither side may fall back to the device's timezone.
- **Object ids are sensitive.** They are username *and* password upstream. Never commit
  a real one (fixtures included), never log one — the server hashes via `hashObjectId()`.
  This repo is public.

## Deployment

The two halves ship on different tracks, and a push to `main` only moves one of them.

- **API:** `compose.yaml` at the repo root, built from `./api`. Production is
  `ssh oracle-arm-01`, stack directory `/opt/stacks/sssb-laundry-api`, which is a
  checkout of this repo. Host-specific bits (Traefik labels, the APNs identifiers and
  signing key) live there untracked in `compose.override.yaml` and `.env`.
- **App:** TestFlight, uploaded from Xcode. See "Publishing an update to TestFlight" in
  `app/README.md`. Nothing about a push to `main` ships an app build.

## Working here

- Do not rewrite published history; the repo is public and commits are referenced from
  issues and from `app/AGENTS.md`.
- Several branches predate the merge and still have the app's files at the repo root.
  Rebasing one onto `main` needs the moves applied first; `git merge -X find-renames`
  handles most of it.
