# Laundry Booking API (Frontend Integration)

Structured JSON API contract for frontend clients.

## Base URL

Configured per environment, for example:

`http://localhost:3000`

## Authentication

- Header required on every request: `X-Object-Id`
- Object id format in this API: string, often in format 1234-5678-901
- Do not hard-code or commit object ids in frontend code or fixtures

## Domain Rules to Surface in UI

- Categories are transparent in this API (frontend does not send category id)
- A booking request targets one canonical timeslot and 1-2 groups in that same timeslot
- Maximum groups per booking/cancellation request: `2`
- Timeslot group ids must be unique positive integers
- Bookings that are not activated within 15 minutes of timeslot start are automatically cancelled and become bookable again
- Available groups and time structures vary by object id/location
- Timeslots may span midnight

## Time Semantics

- Timezone: `Europe/Stockholm`
- `date` query parameter uses `YYYY-MM-DD`
- `week.fromDate`/`week.toDate` are local Stockholm dates
- `startAt`/`endAt` are ISO datetime strings with timezone offset

## Endpoints

### `GET /health`

Response:

```json
{ "ok": true }
```

### `GET /timeslots?date=YYYY-MM-DD`

Returns the full week containing `date`.

Headers:

- `X-Object-Id: <object-id>`

Response shape:

```json
{
  "week": {
    "fromDate": "2026-04-27",
    "toDate": "2026-05-03",
    "timezone": "Europe/Stockholm"
  },
  "groups": [{ "id": 162, "location": "Domus Tvättstuga", "name": "Grupp 1" }],
  "timeslots": [
    {
      "id": "ts_...",
      "startAt": "2026-04-27T07:00:00.000+02:00",
      "endAt": "2026-04-27T10:00:00.000+02:00",
      "localDate": "2026-04-27",
      "startTime": "07:00",
      "endTime": "10:00",
      "spansMidnight": false,
      "groups": [
        {
          "groupId": 162,
          "status": "bookable",
          "canBook": true,
          "canCancel": false
        }
      ]
    }
  ]
}
```

`timeslots[].groups[].status` values:

- `bookable`: user can potentially book this group/time
- `own`: currently booked by this object id
- `unavailable`: not bookable for this group/time

Week cursoring:

- To load next week, call `/timeslots` with a date in that week (recommended: `week.fromDate + 7 days`)

### `POST /timeslots/:timeslotId/book`

Books one canonical timeslot for 1-2 groups.

Headers:

- `X-Object-Id: <object-id>`

Body:

```json
{ "groupIds": [162, 163] }
```

### `POST /timeslots/:timeslotId/cancel`

Cancels one canonical timeslot for 1-2 groups.

Headers:

- `X-Object-Id: <object-id>`

Body:

```json
{ "groupIds": [162] }
```

## Action Responses (`book` and `cancel`)

Response shape:

```json
{
  "timeslotId": "ts_...",
  "overallStatus": "partial_success",
  "results": [
    {
      "groupId": 162,
      "status": "booked",
      "message": "Booked"
    },
    {
      "groupId": 163,
      "status": "failed",
      "message": "Booking did not succeed",
      "error": {
        "code": "BOOK_FAILED",
        "message": "Booking did not succeed",
        "details": {}
      }
    }
  ]
}
```

`overallStatus`:

- `success`: all groups ended in successful/idempotent status
- `partial_success`: mixed successful and failed outcomes
- `failed`: all groups failed

Successful/idempotent per-group statuses:

- `book`: `booked`, `already_booked`
- `cancel`: `cancelled`, `not_booked`

## Timeslot ID

- `timeslotId` is opaque to clients and returned by `GET /timeslots`
- Frontend must not construct or parse ids; always use ids from API responses

## Error Format

All handled errors are structured:

```json
{
  "error": {
    "code": "INVALID_GROUP_IDS",
    "message": "groupIds must contain 1-2 group ids",
    "details": {}
  }
}
```

Unknown/unhandled errors:

```json
{
  "error": {
    "code": "UNKNOWN_ERROR",
    "message": "Unknown error"
  }
}
```

Common client-facing error codes:

- `MISSING_OBJECT_ID`
- `MISSING_DATE`
- `INVALID_DATE`
- `INVALID_TIMESLOT_ID`
- `INVALID_GROUP_IDS`
- `AUTH_FAILED`
- `UNKNOWN_ERROR`

## Frontend Integration Notes

- Always fetch `/timeslots` before booking/cancelling to get valid `timeslotId` and group ids
- Use per-group `results[]` to render partial success/failure states
- After book/cancel, refresh the week to reflect latest state changes
- Handle `AUTH_FAILED` as a recoverable user-visible auth issue for the supplied object id
