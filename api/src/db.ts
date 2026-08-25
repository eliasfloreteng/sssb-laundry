import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type PushEnvironment = "sandbox" | "production";
export type NotificationKind = "reminder" | "new_booking";

export interface DeviceRow {
  token: string;
  objectId: string;
  environment: PushEnvironment;
  enabled: boolean;
  alertMinutes: number | null;
  secondAlertMinutes: number | null;
}

/** One booked (timeslot, group) pair. Bookings are per group; notifications are per timeslot. */
export interface BookingRow {
  objectId: string;
  startAt: string;
  endAt: string;
  groupId: number;
  groupName: string | null;
  location: string | null;
  originToken: string | null;
  /** Set once the "new booking" fan-out has happened, so it only ever fires once. */
  announcedAt: number | null;
}

export interface OutboxRow {
  id: number;
  token: string;
  kind: NotificationKind;
  objectId: string;
  environment: PushEnvironment;
  startAt: string;
  endAt: string;
  groupIds: string;
  labels: string;
  offsetMinutes: number | null;
  fireAt: number;
  attempts: number;
}

/** Everything a notification needs to render, resolved when the booking is recorded. */
export interface NotificationLabels {
  machines: string[];
  location: string;
  dayLabel: string;
  startTime: string;
  endTime: string;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  token                TEXT PRIMARY KEY,
  object_id            TEXT NOT NULL,
  environment          TEXT NOT NULL,
  enabled              INTEGER NOT NULL DEFAULT 1,
  alert_minutes        INTEGER,
  second_alert_minutes INTEGER,
  created_at           INTEGER NOT NULL,
  updated_at           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_object ON devices(object_id) WHERE enabled = 1;

CREATE TABLE IF NOT EXISTS bookings (
  object_id     TEXT NOT NULL,
  start_at      TEXT NOT NULL,
  end_at        TEXT NOT NULL,
  group_id      INTEGER NOT NULL,
  group_name    TEXT,
  location      TEXT,
  first_seen_at INTEGER NOT NULL,
  origin_token  TEXT,
  announced_at  INTEGER,
  PRIMARY KEY (object_id, start_at, group_id)
);
CREATE INDEX IF NOT EXISTS idx_bookings_object ON bookings(object_id);

-- Poll history per object id. Its only job is to tell a first-ever poll from a
-- later one: bookings found on the first poll already exist as far as the user
-- is concerned and must not be announced as new.
CREATE TABLE IF NOT EXISTS objects (
  object_id      TEXT PRIMARY KEY,
  first_polled_at INTEGER NOT NULL,
  last_polled_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  token          TEXT NOT NULL REFERENCES devices(token) ON DELETE CASCADE,
  kind           TEXT NOT NULL,
  object_id      TEXT NOT NULL,
  start_at       TEXT NOT NULL,
  end_at         TEXT NOT NULL,
  group_ids      TEXT NOT NULL,
  labels         TEXT NOT NULL,
  offset_minutes INTEGER,
  fire_at        INTEGER NOT NULL,
  sent_at        INTEGER,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT,
  UNIQUE (token, kind, start_at, group_ids, offset_minutes)
);
CREATE INDEX IF NOT EXISTS idx_outbox_due ON outbox(fire_at) WHERE sent_at IS NULL;
`;

export class Store {
  private readonly db: Database;

  constructor(path = process.env.DB_PATH ?? "./data/laundry.db") {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new Database(path, { create: true });
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA busy_timeout = 5000");
    this.db.exec("PRAGMA foreign_keys = ON");
    this.db.exec(SCHEMA);
  }

  close(): void {
    this.db.close();
  }

  // --- devices ---------------------------------------------------------

  upsertDevice(device: DeviceRow): void {
    const now = nowSeconds();
    this.db
      .query(
        `INSERT INTO devices (token, object_id, environment, enabled, alert_minutes, second_alert_minutes, created_at, updated_at)
         VALUES ($token, $objectId, $environment, $enabled, $alert, $second, $now, $now)
         ON CONFLICT(token) DO UPDATE SET
           object_id            = excluded.object_id,
           environment          = excluded.environment,
           enabled              = excluded.enabled,
           alert_minutes        = excluded.alert_minutes,
           second_alert_minutes = excluded.second_alert_minutes,
           updated_at           = excluded.updated_at`
      )
      .run({
        $token: device.token,
        $objectId: device.objectId,
        $environment: device.environment,
        $enabled: device.enabled ? 1 : 0,
        $alert: device.alertMinutes,
        $second: device.secondAlertMinutes,
        $now: now
      });
  }

  deleteDevice(token: string): void {
    this.db.query("DELETE FROM devices WHERE token = ?").run(token);
  }

  getDevice(token: string): DeviceRow | null {
    const row = this.db.query("SELECT * FROM devices WHERE token = ?").get(token) as
      | Record<string, unknown>
      | null;
    return row ? toDevice(row) : null;
  }

  /** Enabled devices for an object id — the audience for any push about it. */
  devicesForObject(objectId: string): DeviceRow[] {
    const rows = this.db
      .query("SELECT * FROM devices WHERE object_id = ? AND enabled = 1")
      .all(objectId) as Record<string, unknown>[];
    return rows.map(toDevice);
  }

  /** Object ids worth polling: those with at least one enabled device. */
  enabledObjectIds(): string[] {
    const rows = this.db
      .query("SELECT DISTINCT object_id FROM devices WHERE enabled = 1")
      .all() as { object_id: string }[];
    return rows.map((r) => r.object_id);
  }

  // --- bookings --------------------------------------------------------

  knownBookings(objectId: string): BookingRow[] {
    const rows = this.db
      .query("SELECT * FROM bookings WHERE object_id = ?")
      .all(objectId) as Record<string, unknown>[];
    return rows.map(toBooking);
  }

  insertBooking(booking: BookingRow): void {
    this.db
      .query(
        `INSERT INTO bookings (object_id, start_at, end_at, group_id, group_name, location, first_seen_at, origin_token, announced_at)
         VALUES ($objectId, $startAt, $endAt, $groupId, $groupName, $location, $now, $originToken, $announcedAt)
         ON CONFLICT(object_id, start_at, group_id) DO UPDATE SET
           end_at     = excluded.end_at,
           group_name = COALESCE(excluded.group_name, bookings.group_name),
           location   = COALESCE(excluded.location, bookings.location)`
      )
      .run({
        $objectId: booking.objectId,
        $startAt: booking.startAt,
        $endAt: booking.endAt,
        $groupId: booking.groupId,
        $groupName: booking.groupName,
        $location: booking.location,
        $now: nowSeconds(),
        $originToken: booking.originToken,
        $announcedAt: booking.announcedAt
      });
  }

  markAnnounced(objectId: string, startAt: string, groupId: number): void {
    this.db
      .query(
        "UPDATE bookings SET announced_at = ? WHERE object_id = ? AND start_at = ? AND group_id = ?"
      )
      .run(nowSeconds(), objectId, startAt, groupId);
  }

  /** True the first time an object id is polled — used to suppress the initial announce burst. */
  markPolled(objectId: string): boolean {
    const now = nowSeconds();
    const existing = this.db
      .query("SELECT object_id FROM objects WHERE object_id = ?")
      .get(objectId);
    if (existing) {
      this.db.query("UPDATE objects SET last_polled_at = ? WHERE object_id = ?").run(now, objectId);
      return false;
    }
    this.db
      .query("INSERT INTO objects (object_id, first_polled_at, last_polled_at) VALUES (?, ?, ?)")
      .run(objectId, now, now);
    return true;
  }

  hasPolled(objectId: string): boolean {
    return Boolean(this.db.query("SELECT object_id FROM objects WHERE object_id = ?").get(objectId));
  }

  deleteBooking(objectId: string, startAt: string, groupId: number): void {
    this.db
      .query("DELETE FROM bookings WHERE object_id = ? AND start_at = ? AND group_id = ?")
      .run(objectId, startAt, groupId);
  }

  /** Drops bookings whose timeslot has already ended, with their unsent pushes. */
  pruneExpiredBookings(beforeIso: string): void {
    this.db.query("DELETE FROM bookings WHERE end_at < ?").run(beforeIso);
    this.db.query("DELETE FROM outbox WHERE sent_at IS NULL AND end_at < ?").run(beforeIso);
  }

  // --- outbox ----------------------------------------------------------

  /**
   * Idempotent by (token, kind, start_at, group_ids, offset) so re-polling an
   * unchanged booking never re-notifies.
   */
  enqueue(entry: {
    token: string;
    kind: NotificationKind;
    objectId: string;
    startAt: string;
    endAt: string;
    groupIds: number[];
    labels: NotificationLabels;
    offsetMinutes: number | null;
    fireAt: number;
  }): void {
    this.db
      .query(
        `INSERT OR IGNORE INTO outbox
           (token, kind, object_id, start_at, end_at, group_ids, labels, offset_minutes, fire_at)
         VALUES ($token, $kind, $objectId, $startAt, $endAt, $groupIds, $labels, $offset, $fireAt)`
      )
      .run({
        $token: entry.token,
        $kind: entry.kind,
        $objectId: entry.objectId,
        $startAt: entry.startAt,
        $endAt: entry.endAt,
        $groupIds: encodeGroupIds(entry.groupIds),
        $labels: JSON.stringify(entry.labels),
        $offset: entry.offsetMinutes,
        $fireAt: entry.fireAt
      });
  }

  dueNotifications(now = nowSeconds(), limit = 100): OutboxRow[] {
    const rows = this.db
      .query(
        `SELECT o.*, d.environment AS environment
           FROM outbox o
           JOIN devices d ON d.token = o.token
          WHERE o.sent_at IS NULL AND o.fire_at <= ? AND d.enabled = 1
          ORDER BY o.fire_at
          LIMIT ?`
      )
      .all(now, limit) as Record<string, unknown>[];
    return rows.map(toOutbox);
  }

  markSent(id: number): void {
    this.db.query("UPDATE outbox SET sent_at = ? WHERE id = ?").run(nowSeconds(), id);
  }

  markFailed(id: number, error: string): void {
    this.db
      .query("UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?")
      .run(error.slice(0, 500), id);
  }

  dropNotification(id: number): void {
    this.db.query("DELETE FROM outbox WHERE id = ?").run(id);
  }

  /** Unsent pushes for one booking — used when it is cancelled or disappears. */
  deletePendingForBooking(objectId: string, startAt: string): void {
    this.db
      .query("DELETE FROM outbox WHERE sent_at IS NULL AND object_id = ? AND start_at = ?")
      .run(objectId, startAt);
  }

  /** Unsent reminders for one device — used when its alert offsets change. */
  deletePendingRemindersForDevice(token: string): void {
    this.db
      .query("DELETE FROM outbox WHERE sent_at IS NULL AND kind = 'reminder' AND token = ?")
      .run(token);
  }

  transaction<T>(fn: () => T): T {
    return this.db.transaction(fn)();
  }
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export function encodeGroupIds(groupIds: number[]): string {
  return [...groupIds].sort((a, b) => a - b).join(",");
}

export function decodeGroupIds(raw: string): number[] {
  return raw
    .split(",")
    .filter(Boolean)
    .map(Number);
}

function toDevice(row: Record<string, unknown>): DeviceRow {
  return {
    token: row.token as string,
    objectId: row.object_id as string,
    environment: row.environment as PushEnvironment,
    enabled: Boolean(row.enabled),
    alertMinutes: (row.alert_minutes as number | null) ?? null,
    secondAlertMinutes: (row.second_alert_minutes as number | null) ?? null
  };
}

function toBooking(row: Record<string, unknown>): BookingRow {
  return {
    objectId: row.object_id as string,
    startAt: row.start_at as string,
    endAt: row.end_at as string,
    groupId: row.group_id as number,
    groupName: (row.group_name as string | null) ?? null,
    location: (row.location as string | null) ?? null,
    originToken: (row.origin_token as string | null) ?? null,
    announcedAt: (row.announced_at as number | null) ?? null
  };
}

function toOutbox(row: Record<string, unknown>): OutboxRow {
  return {
    id: row.id as number,
    token: row.token as string,
    kind: row.kind as NotificationKind,
    objectId: row.object_id as string,
    environment: row.environment as PushEnvironment,
    startAt: row.start_at as string,
    endAt: row.end_at as string,
    groupIds: row.group_ids as string,
    labels: row.labels as string,
    offsetMinutes: (row.offset_minutes as number | null) ?? null,
    fireAt: row.fire_at as number,
    attempts: row.attempts as number
  };
}
