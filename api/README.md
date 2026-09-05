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
| `GET /status`                      | Whether Aptus itself still answers — `503` when it does not  |
| `GET /`                            | The app's landing page, static from `site/`                  |
| `GET /invite`                      | An invite, for visitors who do *not* have the app installed  |
| `GET /.well-known/apple-app-site-association` | What makes `/invite` a universal link       |

`site/` is served by `@fastify/static` at the root: hand-written `index.html` and
`invite.html`, the association file, and the app icon copied from
`app/SSSBLaundry/Assets.xcassets`. Every route above is registered explicitly and so
wins over the wildcard the plugin installs. Nothing about it is generated, and it loads
no fonts or scripts from anywhere else.

`apple-app-site-association` needs a route of its own for two reasons: iOS fetches it
only from `/.well-known/`, and it must come back as `application/json`, which the static
plugin will not do for a file with no extension. It names the App ID the entitlement in
`app/SSSBLaundry/SSSBLaundry.entitlements` has to match, and the one path it claims.

**An invite never carries the object number to this server.** The number rides in the
URL *fragment* — `/invite#1234-5678-901` — which no browser sends anywhere, so it stays
out of the access log while still reaching the app, because iOS hands the whole URL over
when it opens a universal link. `invite.html` reads it in the browser and, on the way to
TestFlight, copies the link to the clipboard: that copy is the only thing that survives
an install, and it is what the app's sign-in screen offers to paste.

There is no pagination cursor: the next page is `week.toDate + 1 day`, and an empty
`timeslots` is the end of what this object id may book.

Per-group results mix success and failure — a booking that succeeds for one group and
fails for the other is a `200` with both outcomes, not an error. Errors are
`{ "error": { code, message, details, upstream } }`, with `UNKNOWN_ERROR` as the
catch-all.

Categories are deliberately not part of the API. Upstream has one per location (usually
"Tvätt") and the client should never learn about them.

## Is upstream still there?

Everything below is a wrapper around someone else's HTML, so the failure that
matters most is one this server cannot cause and would not otherwise notice: SSSB's
portal goes down, or changes its markup, and the app stops working while the process
stays perfectly healthy. `src/upstream-check.ts` is a timer that answers that
question, and `GET /status` is where the answer is published:

```json
{ "ok": true, "upstream": { "state": "ok", "checkedAt": "…", "groups": 2, "timeslots": 84, … } }
```

- **The probe is `listTimeslots` for the current week and nothing else.** It runs
  against a real object id on a schedule, so it is read-only by construction: the
  probe is typed against a `TimeslotsSource` that has no `bookTimeslot` on it, and
  reaching for one is a compile error rather than a booking on someone's account.
  Nothing it does can queue a push either — reminders are announced from the poll in
  `notifications.ts` and from the book/cancel routes, and this touches neither.
- **An empty week is a failure**, `UPSTREAM_EMPTY`. A portal that changed its HTML
  answers `200` with nothing parsed out of it, which is the quiet break worth
  catching; the current week always has groups and slots in it.
- **One failure is not an outage.** Aptus drops requests on its own, so `/status`
  stays `200` and `degraded` until `UPSTREAM_CHECK_FAILURES` probes fail in a row.
  Monitor-side retries cannot do this job: the result only changes once per interval,
  so a retry a minute later just reads the same answer.
- **`/status` never probes on demand.** It reports the last result. The endpoint is
  public and upstream is fragile, so a visitor must not be able to pull on it.
- **A dead timer is an outage too.** No probe within three intervals is `stale`, and
  `stale` is a `503` — otherwise a check that stopped running would read as healthy
  forever.
- **`/health` deliberately knows none of this.** It is the container healthcheck, and
  a portal outage is not a reason to call this process sick. Two endpoints, two
  monitors, two meanings.

Uptime Kuma watches both: *SSSB Laundry API* on `/health`, *SSSB Laundry Upstream* on
`/status`.

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
- **A cancellation takes back what was already delivered.** `retract()` queues a silent
  `cancelled` push for each device the booking's notifications actually reached, then
  forgets they were sent — which is what makes retracting the same slot twice a no-op.
  APNs carries it as push type `background` at priority 5; an alert push can add a
  notification but never remove one.
- Sent outbox rows are kept until the timeslot ends, because they are the record of what
  there is to retract. `pruneExpiredBookings` drops them with the booking.
- Object ids and device tokens are never logged — hash with `hashObjectId()`.
- `410` / `BadDeviceToken` / `Unregistered` deletes the device row. Never retry those.

### Environment

`PUSH_ENABLED=true` plus `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and either
`APNS_KEY_P8` (inline PEM, `\n`-escaped — the production path) or `APNS_KEY_PATH` (dev;
the key lives in the gitignored `secrets/`). Without them the server logs one warning and
runs without notifications. Tunables: `PUSH_POLL_MINUTES` (default 10), `PUSH_POLL_WEEKS`
(default 3) — polling is expensive, so leave them alone unless you mean it.

The upstream check reads `UPSTREAM_CHECK_OBJECT_ID`, which is what enables it — unset,
it logs one warning and `/status` reports `disabled`. It belongs in the same gitignored
`.env`, because an object id is a credential. `UPSTREAM_CHECK_MINUTES` (default 15) and
`UPSTREAM_CHECK_FAILURES` (default 2) tune it; every probe is a login plus a calendar
per group, so the interval is not free.

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
