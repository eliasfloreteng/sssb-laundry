# sssb-laundry-api

Always use Bun.

This is a minimal structued HTTP API for booking laundry sessions at SSSB that wraps their Aptus Portal laundry booking service.

Find example requests in the `./requests` directory. This directory is gitignored as it contains sensitive authentication details

# Requirements

- Timeslots are the canonical entities.
- Available actions: viewing timeslots, booking a timeslot, cancelling a booking.
- Data (for example dates and times) extracted should be parsed and structured (not simply strings).
- Authentication should consist of only supplying the object id to each request as a header, the underlying sessions should be reused and reauthenticated if expired.
- The categories should be completely transparent (does not need to be supplied) as most cases it has only one called something like "Laundry" or "Tvätt".
- Do not draw assumptions or hard-code unknown details. Rather ask or interview if unsure.
- Use a DOM/HTML parser for extracting structured information from the responses and use only RegEx if more appropriate.
- Multiple groups (up to two) should be able to be booked for a timeslot with a single request.
- If the booking for one group fails, a partial success should be returned with the successful and failed bookings.
- Errors should also be returned in a structured format with handling of unknown errors.
- Focus on brevity and being concise in the implementation.
- The application is stateless for the booking endpoints (sessions live in memory only). Push notifications are the one exception: device tokens, known bookings and the notification outbox are persisted in SQLite.
- The list of timeslots should be able to return a cursor (date) for the next week of timeslots.
- Cancellations should support multiple groups. Same partial success/failure handling as for bookings.
- For the password encoding implement the same logic as the upstream application.
- Do not include any object ids in the repository as they are considered sensitive.

# Notes about Aptus API

## Invariants

- Only one timeslot can be booked at a time but for up to two groups for that same timeslot.
- Times that are not activated (by going into the laundry room) within 15 minutes of start are automatically cancelled and available for anyone to book again.
- Number of locations (groups) can vary, some object ids (logins/locations) only have two groups and some have up to nine or more (for different buildings).
- The timeslots structure/times vary between object ids (logins/locations).
- Timeslots can span across midnight.

## Technical details

> The upstream (`https://sssb.aptustotal.se/AptusPortal/`) is an ASP.NET MVC HTML app with short session lifetimes, XOR-encoded client-side passwords, and a location-specific set of "laundry groups".

- Multiple requests to the underlying Aptus API may be needed to fullfil a single client request.
- The object id is both username and password for login.
- All responses return HTML.
- All times are in Europe/Stockholm (dates from the portal are without timezone). Be aware of DST.
- Anti-forgery is only enforced on `POST /Account/Login`; other endpoints are plain GETs.
- `__RequestVerificationToken` cookie and form value must come from the same GET; do not mix them across requests.
- The server responds with **empty body** to requests without a `User-Agent`. Always set one.
- Some endpoints redirect to `/Account/Error` when they receive `X-Requested-With: XMLHttpRequest` without a matching `Referer`.
- All cookies `ASP.NET_SessionId`, `__RequestVerificationToken_L0FwdHVzUG9ydGFs0` and `.ASPXAUTH` need to be sent on subsequent requests.
- The `passDate` param at `/AptusPortal/CustomerBooking/BookingCalendar` dictates which week of timesslots to show. It is usually the monday of that week but any date from that week works.

# Push notifications

Server-driven APNs, because bookings made by anyone else on the same object id must
notify even when the app is never opened (and because Live Activities will need the
same channel later).

- `src/db.ts` — `bun:sqlite` store (`DB_PATH`, default `./data/laundry.db`, WAL). Tables:
  `devices`, `bookings`, `outbox`, `objects`. In Docker it lives on the `laundry-data`
  volume; without that volume every redeploy silently drops every queued reminder.
- `src/apns.ts` — zero-dependency APNs client: ES256 JWT via `node:crypto`
  (`dsaEncoding: "ieee-p1363"` is raw R‖S, which is what JOSE wants — DER is rejected),
  HTTP/2 via `node:http2`. Provider tokens are cached for 40 min (Apple refuses
  refreshes under 20 min and tokens over 60 min).
- `src/notifications.ts` — the poller and sender. Started only by `startServer()`;
  `buildServer()` must stay timer-free because tests call it directly.

## Invariants

- **A failed scrape is not "the bookings vanished".** `pollObject` aborts and changes
  nothing on upstream error. Deleting on a failed fetch would drop pending reminders
  and re-announce everything once the fetch recovered.
- **The first poll of an object id never announces.** Bookings found then already
  exist as far as the user is concerned; `objects.first_polled_at` is what tells a
  cold start from a genuine new booking.
- **Bookings are keyed `(object_id, start_at, group_id)`, never by `timeslotId`.**
  A timeslot id is content-derived from `{startAt, endAt}` and carries no user or
  group identity, so it is regenerated at send time via `encodeTimeslotId`.
- **The booking device is skipped on announcement.** `POST /book` reads an optional
  `X-Device-Token` header and stores it as `bookings.origin_token`.
- Object ids and device tokens are never logged. Use `hashObjectId()`.
- `410`/`BadDeviceToken`/`Unregistered` deletes the device row. Never retry those.

## Endpoints

- `PUT /notifications/device` — `{ deviceToken, environment, enabled, alertMinutes,
  secondAlertMinutes }`. Upserts and rebuilds that device's reminders immediately.
- `DELETE /notifications/device` — `{ deviceToken }`.
- `POST /notifications/test` — dev only (`NODE_ENV !== "production"`), fires a
  reminder at every enabled device for the calling object id.

## Environment

`PUSH_ENABLED=true` plus `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and either
`APNS_KEY_P8` (inline PEM, `\n`-escaped — the production path) or `APNS_KEY_PATH`
(dev; the key lives in the gitignored `secrets/`). Tunables: `PUSH_POLL_MINUTES`
(default 10), `PUSH_POLL_WEEKS` (default 3). Polling is expensive — one
`listTimeslots` is categories + groups + one BookingCalendar per group.

On this deployment the four identifiers live in `compose.yaml` (the repo is private and
none of them is a credential); `APNS_KEY_P8` alone lives in the gitignored `.env`, pulled
in via `env_file`. Regenerate it from the `.p8` after a key rotation:

```sh
bun -e 'const f=require("fs");const k=f.readFileSync("secrets/AuthKey_<KEYID>.p8","utf8").trim();
f.writeFileSync(".env",`APNS_KEY_P8=${k.replace(/\r?\n/g,"\\n")}\n`)'
```

A bind mount of `secrets/` is not an option here: the container runs as uid 1000 (`bun`)
and the host key is 0640 owned by uid 1001.
