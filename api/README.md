# SSSB Laundry API (Aptus wrapper)

Minimal structured JSON API that wraps SSSB's Aptus Portal laundry booking. Its only
client is the iOS app in [`../app`](../app), and there is no separate spec — `src/` is
the contract, so a route or DTO change lands together with the app's `APIClient.swift`
and `Models.swift` (see [`../README.md`](../README.md)).

## Run

```bash
cd api
bun install
bun run dev        # http://0.0.0.0:3000
```

`LOG_LEVEL` sets verbosity (`info` default, `debug` traces upstream requests). Example
requests against Aptus live in the gitignored `requests/` — they carry real object ids.

## Auth

Every request carries the object id, which is username *and* password upstream:

```http
X-Object-Id: <OBJECT_ID>
```

Sessions are reused per object id and reauthenticated when they expire. Booking is
otherwise stateless; only push state is persisted.

## Endpoints

| Route                              | What it does                                                |
| ---------------------------------- | ----------------------------------------------------------- |
| `GET /timeslots?date=YYYY-MM-DD`   | The week containing `date`, in Europe/Stockholm              |
| `POST /timeslots/:id/book`         | `{ groupIds: [162, 163] }` — 1–2 groups, per-group results   |
| `POST /timeslots/:id/cancel`       | Same body and result shape                                   |
| `PUT`/`DELETE /notifications/device` | Register or drop a device and its reminder preferences     |
| `POST /notifications/test`         | Fires a reminder at this object id's devices (non-prod only) |
| `GET /health`                      | Liveness, used by the container healthcheck                  |

There is no pagination cursor: the next page is `week.toDate + 1 day`, and an empty
`timeslots` is the end of what this object id may book.

Per-group results mix success and failure — a booking that succeeds for one group and
fails for the other is a `200` with both outcomes, not an error. Errors are
`{ "error": { code, message, details, upstream } }`, with `UNKNOWN_ERROR` as the
catch-all.

Categories are deliberately not part of the API. Upstream has one per location (usually
"Tvätt") and the client should never learn about them.

## Upstream quirks

Aptus (`https://sssb.aptustotal.se/AptusPortal/`) is an ASP.NET MVC HTML app. These are
its behaviors, not ours, and they are the reason the client looks the way it does:

- **No `User-Agent`, empty body.** Always send one.
- **An expired session has two shapes.** With no cookies the portal redirects to
  `/Account/Login`; with a stale `.ASPXAUTH` after session state is gone it redirects to
  `/Account/LogOff` instead. A long-lived cached session only ever hits the second one,
  so both must trigger reauthentication.
- **Anti-forgery is only enforced on `POST /Account/Login`**, and the
  `__RequestVerificationToken` cookie and form value must come from the same GET. Don't
  mix them across requests.
- Some endpoints redirect to `/Account/Error` when they get `X-Requested-With:
  XMLHttpRequest` without a matching `Referer`.
- `passDate` on `BookingCalendar` picks the week — any date within it works.
- Responses are HTML, and one client request usually costs several upstream ones
  (categories + groups + one calendar per group).
- **`canBook` / `canCancel` are Aptus's own answer**, not ours: they are the presence of
  a book button and of an unbook link in the calendar HTML. Without one, the action is
  refused here (`not_bookable`, `NOT_CANCELLABLE`) without the portal ever being asked —
  a passed timeslot and a session already running are the everyday cases, and the app
  offers neither.
- One booking covers up to two groups, and one or two sessions may be held at a time
  depending on the laundry room. A slot not activated at the machine within 15 minutes of
  the start is released to everyone again — which frees the quota, as does the booked
  slot simply starting.
- The number of groups, and the shape of the timeslots themselves, varies by object id —
  some cover nine buildings. Don't hard-code either.

## Push notifications

Server-driven APNs, because a booking made by anyone else on the same object id must
notify even when the app is never opened. `src/notifications.ts` polls, `src/apns.ts`
sends, `src/db.ts` stores. Timers start in `startServer()` only — `buildServer()` stays
timer-free so tests can call it directly.

- **A failed scrape is not "the bookings vanished".** `pollObject` aborts and changes
  nothing on upstream error; deleting would drop pending reminders and re-announce
  everything once the fetch recovered.
- **The first poll of an object id never announces.** What it finds already exists as far
  as the user is concerned; `objects.first_polled_at` separates a cold start from a new
  booking.
- **Bookings are keyed `(object_id, start_at, group_id)`, never by `timeslotId`** — that
  id carries no user or group identity and is regenerated at send time.
- The booking device is skipped when announcing: `POST /book` stores the optional
  `X-Device-Token` header as `bookings.origin_token`.
- Object ids and device tokens are never logged — hash with `hashObjectId()`.
- `410` / `BadDeviceToken` / `Unregistered` deletes the device row. Never retry those.

### Environment

`PUSH_ENABLED=true` plus `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and either
`APNS_KEY_P8` (inline PEM, `\n`-escaped — the production path) or `APNS_KEY_PATH` (dev;
the key lives in the gitignored `secrets/`). Without them the server logs one warning and
runs without notifications. Tunables: `PUSH_POLL_MINUTES` (default 10), `PUSH_POLL_WEEKS`
(default 3) — polling is expensive, so leave them alone unless you mean it.

The repo is public, so those live in the gitignored `.env` beside `../compose.yaml`,
which is what `env_file` pulls in. After a key rotation:

```sh
bun -e 'const f=require("fs");const k=f.readFileSync("secrets/AuthKey_<KEYID>.p8","utf8").trim();
f.appendFileSync("../.env",`APNS_KEY_P8=${k.replace(/\r?\n/g,"\\n")}\n`)'
```

A bind mount of `secrets/` into the container is not an option: it runs as uid 1000
(`bun`) and the host key is `0640` owned by uid 1001.

## Deploy

`compose.yaml` at the repo root builds this directory as its context:

```bash
cd .. && docker compose up -d --build
```

SQLite lives on the `./data` bind mount next to it — device tokens and queued reminders
must survive a redeploy.
