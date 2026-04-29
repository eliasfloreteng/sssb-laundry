# SSSB Laundry API (Aptus wrapper)

Minimal structured JSON API that wraps SSSB Aptus laundry booking.

## Run

```bash
bun install
bun run dev
```

Server defaults to `http://0.0.0.0:3000`.

Set `LOG_LEVEL` for verbosity (`info` default, `debug` for upstream request traces):

```bash
LOG_LEVEL=debug bun run dev
```

## Auth

Pass the object id in every request:

```http
X-Object-Id: <OBJECT_ID>
```

The server reuses upstream sessions per object id and reauthenticates when expired.

## Endpoints

### `GET /timeslots?date=YYYY-MM-DD`
Returns canonical timeslots for the week containing `date` (Europe/Stockholm).

### `POST /timeslots/:timeslotId/book`
Body:

```json
{
  "groupIds": [162, 163]
}
```

Books the same timeslot for 1-2 groups and returns per-group results.

### `POST /timeslots/:timeslotId/cancel`
Body:

```json
{
  "groupIds": [162]
}
```

Cancels the same timeslot for 1-2 groups and returns per-group results.

## Error format

```json
{
  "error": {
    "code": "INVALID_GROUP_IDS",
    "message": "groupIds must contain 1-2 group ids",
    "details": {},
    "upstream": {}
  }
}
```

Unknown failures return `code: "UNKNOWN_ERROR"`.
