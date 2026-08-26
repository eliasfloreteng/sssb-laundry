import { DateTime } from "luxon";
import { AptusClient, hashObjectId, type LoggerLike } from "./aptus-client.js";
import { ApnsClient, loadApnsConfig, type ApnsRequest } from "./apns.js";
import {
  Store,
  decodeGroupIds,
  nowSeconds,
  type BookingRow,
  type DeviceRow,
  type NotificationLabels,
  type OutboxRow,
  type PushEnvironment
} from "./db.js";
import { encodeTimeslotId } from "./timeslot-id.js";
import { STOCKHOLM_TZ, type TimeslotsResponse } from "./types.js";

/** A booking auto-cancels 15 minutes after start if the machine is not activated. */
const GRACE_SECONDS = 15 * 60;

const SENDER_INTERVAL_MS = 30_000;
const MAX_SEND_ATTEMPTS = 8;

/** One timeslot the object id currently holds, with every group it holds in it. */
interface OwnedSlot {
  startAt: string;
  endAt: string;
  groups: { groupId: number; groupName: string | null; location: string | null }[];
}

export interface PushServiceOptions {
  store: Store;
  aptus: AptusClient;
  apns: ApnsClient;
  logger?: LoggerLike;
  pollMinutes?: number;
  pollWeeks?: number;
}

export class PushService {
  private readonly store: Store;
  private readonly aptus: AptusClient;
  private readonly apns: ApnsClient;
  private readonly logger?: LoggerLike;
  private readonly pollMinutes: number;
  private readonly pollWeeks: number;
  private timers: ReturnType<typeof setInterval>[] = [];
  private polling = false;
  private sending = false;

  constructor(options: PushServiceOptions) {
    this.store = options.store;
    this.aptus = options.aptus;
    this.apns = options.apns;
    this.logger = options.logger;
    this.pollMinutes = options.pollMinutes ?? Number(process.env.PUSH_POLL_MINUTES ?? 10);
    this.pollWeeks = options.pollWeeks ?? Number(process.env.PUSH_POLL_WEEKS ?? 3);
  }

  start(): void {
    this.timers.push(setInterval(() => void this.sendDue(), SENDER_INTERVAL_MS));
    this.timers.push(setInterval(() => void this.pollAll(), this.pollMinutes * 60_000));
    for (const timer of this.timers) timer.unref?.();
    // The container restarts on every deploy, so catch up straight away rather
    // than leaving a poll interval's worth of reminders unscheduled.
    void this.sendDue();
    void this.pollAll();
  }

  stop(): void {
    for (const timer of this.timers) clearInterval(timer);
    this.timers = [];
    this.apns.close();
  }

  // --- route hooks -----------------------------------------------------

  registerDevice(device: {
    token: string;
    objectId: string;
    environment: PushEnvironment;
    enabled: boolean;
    alertMinutes: number | null;
    secondAlertMinutes: number | null;
  }): void {
    const previous = this.store.getDevice(device.token);
    this.store.upsertDevice(device);
    // A token that moved to another object id must not keep the old one's
    // queued reminders.
    if (previous && previous.objectId !== device.objectId) {
      this.store.deletePendingRemindersForDevice(device.token);
    }
    this.onDeviceUpdated(device.token);
  }

  unregisterDevice(token: string): void {
    this.store.deleteDevice(token);
  }

  /** Test-only: queue a reminder that is due immediately for every enabled device. */
  enqueueTestNotification(objectId: string): number {
    const devices = this.store.devicesForObject(objectId);
    const start = DateTime.now().setZone(STOCKHOLM_TZ);
    const end = start.plus({ hours: 3 });
    const labels: NotificationLabels = {
      machines: ["Test machine"],
      location: "",
      dayLabel: start.toFormat("ccc d LLL"),
      startTime: start.toFormat("HH:mm"),
      endTime: end.toFormat("HH:mm")
    };
    for (const device of devices) {
      this.store.enqueue({
        token: device.token,
        kind: "reminder",
        objectId,
        startAt: start.toISO()!,
        endAt: end.toISO()!,
        groupIds: [0],
        labels,
        offsetMinutes: 0,
        fireAt: nowSeconds()
      });
    }
    void this.sendDue();
    return devices.length;
  }

  onBooked(
    objectId: string,
    startAt: string,
    endAt: string,
    groupIds: number[],
    originToken: string | null
  ): void {
    for (const groupId of groupIds) {
      this.store.insertBooking({
        objectId,
        startAt,
        endAt,
        groupId,
        groupName: null,
        location: null,
        originToken,
        announcedAt: null
      });
    }
    // The poll resolves group names, schedules reminders and fans the
    // announcement out to the other devices on this object id.
    void this.pollObject(objectId);
  }

  onCancelled(objectId: string, startAt: string, groupIds: number[]): void {
    for (const groupId of groupIds) {
      this.store.deleteBooking(objectId, startAt, groupId);
    }
    if (this.store.knownBookings(objectId).every((b) => b.startAt !== startAt)) {
      this.retract(objectId, startAt);
    }
    void this.pollObject(objectId);
  }

  /** Alert offsets changed — rebuild that device's reminders now, not in ten minutes. */
  onDeviceUpdated(token: string): void {
    const device = this.store.getDevice(token);
    if (!device) return;
    this.store.deletePendingRemindersForDevice(token);
    if (!device.enabled) return;
    for (const slot of groupBookings(this.store.knownBookings(device.objectId))) {
      this.scheduleReminders(device, slot);
    }
    // A device that has never been polled for would otherwise wait a full
    // interval before its first reminders appear.
    if (!this.store.hasPolled(device.objectId)) void this.pollObject(device.objectId);
  }

  // --- polling ---------------------------------------------------------

  async pollAll(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      this.store.pruneExpiredBookings(DateTime.now().toISO() ?? new Date().toISOString());
      // Serialised on purpose: each listTimeslots is already N+2 requests
      // against a fragile ASP.NET portal.
      for (const objectId of this.store.enabledObjectIds()) {
        await this.pollObject(objectId);
      }
    } finally {
      this.polling = false;
    }
  }

  async pollObject(objectId: string): Promise<void> {
    const devices = this.store.devicesForObject(objectId);
    if (devices.length === 0) return;

    let owned: OwnedSlot[];
    try {
      owned = await this.fetchOwnedSlots(objectId);
    } catch (error) {
      // A failed scrape is not "the bookings vanished". Changing nothing keeps
      // pending reminders alive and stops a recovery from re-announcing.
      this.logger?.warn?.(
        { objectKey: hashObjectId(objectId), err: describe(error) },
        "Push poll failed, leaving stored bookings untouched"
      );
      return;
    }

    const isFirstPoll = this.store.markPolled(objectId);
    const known = this.store.knownBookings(objectId);
    const knownByKey = new Map(known.map((b) => [`${b.startAt}#${b.groupId}`, b]));
    const seen = new Set<string>();

    for (const slot of owned) {
      const groupIds = slot.groups.map((g) => g.groupId).sort((a, b) => a - b);
      let changed = false;

      for (const group of slot.groups) {
        const key = `${slot.startAt}#${group.groupId}`;
        seen.add(key);
        const existing = knownByKey.get(key);
        if (!existing) changed = true;
        this.store.insertBooking({
          objectId,
          startAt: slot.startAt,
          endAt: slot.endAt,
          groupId: group.groupId,
          groupName: group.groupName,
          location: group.location,
          originToken: existing?.originToken ?? null,
          // Bookings found on the very first poll already exist as far as the
          // user is concerned — announcing them would spam on opt-in.
          announcedAt: existing?.announcedAt ?? (isFirstPoll ? nowSeconds() : null)
        });
      }

      // The group set changed, so any queued push carries a stale group list.
      if (changed) this.store.deletePendingForBooking(objectId, slot.startAt);

      const labels = buildLabels(slot);
      for (const device of devices) {
        this.scheduleReminders(device, { startAt: slot.startAt, endAt: slot.endAt, groupIds, labels });
      }

      this.announce(objectId, slot, groupIds, labels, devices, isFirstPoll);
    }

    const dropped = new Set<string>();
    for (const booking of known) {
      const key = `${booking.startAt}#${booking.groupId}`;
      if (seen.has(key)) continue;
      this.store.deleteBooking(objectId, booking.startAt, booking.groupId);
      dropped.add(booking.startAt);
    }
    for (const startAt of dropped) {
      // One group of a two-group slot going away leaves the booking standing,
      // so only a slot with nothing left behind is a cancellation.
      const gone = this.store.knownBookings(objectId).every((b) => b.startAt !== startAt);
      if (gone) this.retract(objectId, startAt);
      else this.store.deletePendingForBooking(objectId, startAt);
    }
  }

  /** Fans a newly seen booking out to every device except the one that made it. */
  private announce(
    objectId: string,
    slot: OwnedSlot,
    groupIds: number[],
    labels: NotificationLabels,
    devices: DeviceRow[],
    isFirstPoll: boolean
  ): void {
    if (isFirstPoll) return;
    const rows = this.store
      .knownBookings(objectId)
      .filter((b) => b.startAt === slot.startAt && b.announcedAt === null);
    if (rows.length === 0) return;

    const origins = new Set(rows.map((r) => r.originToken).filter(Boolean) as string[]);
    for (const device of devices) {
      if (origins.has(device.token)) continue;
      this.store.enqueue({
        token: device.token,
        kind: "new_booking",
        objectId,
        startAt: slot.startAt,
        endAt: slot.endAt,
        groupIds,
        labels,
        offsetMinutes: null,
        fireAt: nowSeconds()
      });
    }
    for (const row of rows) {
      this.store.markAnnounced(objectId, row.startAt, row.groupId);
    }
  }

  /**
   * A booking is gone: drop its queued pushes, and ask every device that already
   * got one to take the delivered notification back down. Forgetting what was
   * sent is what makes retracting twice a no-op instead of a second push.
   */
  private retract(objectId: string, startAt: string): void {
    const delivered = this.store.sentForBooking(objectId, startAt);
    this.store.deletePendingForBooking(objectId, startAt);
    this.store.deleteSentForBooking(objectId, startAt);

    // One retraction per device, however many notifications it received: the
    // app clears every notification it holds for the booking.
    const perDevice = new Map(delivered.map((row) => [row.token, row]));
    for (const row of perDevice.values()) {
      this.store.enqueue({
        token: row.token,
        kind: "cancelled",
        objectId,
        startAt,
        endAt: row.endAt,
        groupIds: decodeGroupIds(row.groupIds),
        labels: JSON.parse(row.labels) as NotificationLabels,
        offsetMinutes: null,
        fireAt: nowSeconds()
      });
    }
    // A stale reminder on the lock screen is worth more than a poll interval of
    // patience, so don't wait for the sender's next tick.
    if (perDevice.size > 0) void this.sendDue();
  }

  private scheduleReminders(
    device: DeviceRow,
    slot: { startAt: string; endAt: string; groupIds: number[]; labels: NotificationLabels }
  ): void {
    const startEpoch = toEpoch(slot.startAt);
    if (startEpoch === null) return;
    const now = nowSeconds();

    for (const offset of activeOffsets(device)) {
      const fireAt = startEpoch - offset * 60;
      if (fireAt <= now) continue;
      this.store.enqueue({
        token: device.token,
        kind: "reminder",
        objectId: device.objectId,
        startAt: slot.startAt,
        endAt: slot.endAt,
        groupIds: slot.groupIds,
        labels: slot.labels,
        offsetMinutes: offset,
        fireAt
      });
    }
  }

  private async fetchOwnedSlots(objectId: string): Promise<OwnedSlot[]> {
    const slots: OwnedSlot[] = [];
    const nowIso = DateTime.now().setZone(STOCKHOLM_TZ);
    let date = nowIso.toFormat("yyyy-MM-dd");

    for (let week = 0; week < this.pollWeeks; week += 1) {
      const response: TimeslotsResponse = await this.aptus.listTimeslots(objectId, date);
      const groupsById = new Map(response.groups.map((g) => [g.id, g]));

      for (const timeslot of response.timeslots) {
        const own = timeslot.groups.filter((g) => g.status === "own");
        if (own.length === 0) continue;
        const end = toEpoch(timeslot.endAt);
        if (end !== null && end <= nowSeconds()) continue;
        slots.push({
          startAt: timeslot.startAt,
          endAt: timeslot.endAt,
          groups: own.map((g) => ({
            groupId: g.groupId,
            groupName: groupsById.get(g.groupId)?.name ?? null,
            location: groupsById.get(g.groupId)?.location ?? null
          }))
        });
      }

      const next = DateTime.fromISO(response.week.toDate, { zone: STOCKHOLM_TZ }).plus({ days: 1 });
      if (!next.isValid) break;
      date = next.toFormat("yyyy-MM-dd");
    }

    return dedupeSlots(slots);
  }

  // --- sending ---------------------------------------------------------

  async sendDue(): Promise<void> {
    // Retractions and the test endpoint both kick this off between ticks, and
    // two runs over the same due rows would deliver each of them twice.
    if (this.sending) return;
    this.sending = true;
    try {
      for (const row of this.store.dueNotifications()) {
        await this.deliver(row);
      }
    } finally {
      this.sending = false;
    }
  }

  private async deliver(row: OutboxRow): Promise<void> {
    const labels = JSON.parse(row.labels) as NotificationLabels;
    const groupIds = decodeGroupIds(row.groupIds);

    const outcome = await this.apns.send({
      token: row.token,
      environment: row.environment,
      payload: buildPayload(row, labels, groupIds),
      ...deliveryOptions(row)
    });

    if (outcome.kind === "sent") {
      this.store.markSent(row.id);
      return;
    }
    if (outcome.kind === "unregistered") {
      this.logger?.info?.({ reason: outcome.reason }, "Dropping unregistered device token");
      this.store.deleteDevice(row.token);
      return;
    }

    this.store.markFailed(row.id, `${outcome.status} ${outcome.reason}`);
    if (!outcome.retryable || row.attempts + 1 >= MAX_SEND_ATTEMPTS) {
      this.logger?.warn?.(
        { status: outcome.status, reason: outcome.reason, kind: row.kind },
        "Giving up on notification"
      );
      this.store.dropNotification(row.id);
    }
  }
}

// --- payloads ----------------------------------------------------------

export function buildPayload(
  row: Pick<OutboxRow, "kind" | "startAt" | "endAt" | "groupIds" | "offsetMinutes">,
  labels: NotificationLabels,
  groupIds: number[]
): unknown {
  if (row.kind === "cancelled") {
    return {
      // Silent: this push exists to take a notification down, not to add one.
      aps: { "content-available": 1 },
      kind: row.kind,
      timeslotId: encodeTimeslotId(row.startAt, row.endAt),
      groupIds,
      startAt: row.startAt
    };
  }

  const machines = labels.machines.length > 0 ? labels.machines.join(", ") : "";
  const when = `${labels.dayLabel} ${labels.startTime}–${labels.endTime}`;

  // Titles and bodies travel as APNs localization keys rather than as finished
  // sentences: the app bundle holds both languages, so the notification comes
  // out in whatever language iOS is showing the app in — including a language
  // picked per-app in Settings, which the server has no way of knowing.
  const title = row.kind === "reminder" ? reminderTitle(row.offsetMinutes) : { key: TITLE_NEW_BOOKING };
  const body = bodyAlert(when, machines, row.kind === "reminder" ? row.offsetMinutes : undefined);

  const aps: Record<string, unknown> = {
    alert: {
      "title-loc-key": title.key,
      ...(title.args ? { "title-loc-args": title.args } : {}),
      "loc-key": body.key,
      "loc-args": body.args
    },
    sound: "default",
    "thread-id": threadId(row.startAt, row.groupIds)
  };
  if (row.kind === "reminder") {
    aps["interruption-level"] = "time-sensitive";
    aps["relevance-score"] = 1.0;
  }

  return {
    aps,
    kind: row.kind,
    // Regenerated at send time — an opaque timeslot id is never persisted.
    timeslotId: encodeTimeslotId(row.startAt, row.endAt),
    groupIds,
    startAt: row.startAt
  };
}

/** How APNs should carry each kind: a collapsing alert, or a silent wake-up. */
function deliveryOptions(
  row: Pick<OutboxRow, "kind" | "startAt" | "endAt" | "groupIds">
): Pick<ApnsRequest, "pushType" | "priority" | "collapseId" | "expiration"> {
  const startEpoch = toEpoch(row.startAt) ?? nowSeconds();
  if (row.kind === "cancelled") {
    // A background push is the only way to reach into an already delivered
    // notification, and APNs rejects one sent at priority 10. Worth attempting
    // until the slot is over — that is how long the stale reminder would sit
    // on the lock screen.
    return { pushType: "background", priority: 5, expiration: toEpoch(row.endAt) ?? startEpoch };
  }
  return {
    collapseId: threadId(row.startAt, row.groupIds),
    // Never let a reminder land after the booking has already been released.
    expiration: startEpoch + GRACE_SECONDS
  };
}

/**
 * The keys the app's string catalog answers to. They are spelled out here so a
 * grep for the key finds both ends of the contract; the app has a matching
 * entry, marked manual so string extraction does not sweep it away for being
 * absent from the Swift source.
 *
 * Singular and plural are separate keys rather than one with a count, because
 * `loc-args` are plain strings and never satisfy a plural rule.
 */
export const TITLE_NEW_BOOKING = "notification.title.newBooking";
export const TITLE_STARTS_NOW = "notification.title.startsNow";

/** A localization key and the strings substituted into it, if any. */
export interface LocAlert {
  key: string;
  args?: string[];
}

function reminderTitle(offsetMinutes: number | null): LocAlert {
  if (offsetMinutes === null || offsetMinutes === 0) return { key: TITLE_STARTS_NOW };
  const lead = leadUnit(offsetMinutes);
  return {
    key: `notification.title.in.${lead.unit}${lead.count === 1 ? "" : "s"}`,
    args: [String(lead.count)]
  };
}

/**
 * The body is one line of data — day, time, machines — optionally followed by
 * the grace-period warning. Which of the four templates applies is decided
 * here; the wording of each lives in the app.
 */
function bodyAlert(when: string, machines: string, offsetMinutes?: number | null): LocAlert {
  // Close to the start the grace period is the actionable part of the message.
  const activate = offsetMinutes !== undefined && (offsetMinutes === null || offsetMinutes <= 15);
  const suffix = activate ? ".activate" : "";
  return machines
    ? { key: `notification.body.machines${suffix}`, args: [when, machines] }
    : { key: `notification.body${suffix}`, args: [when] };
}

/** The offset as a whole number of the largest unit that divides it. */
export function leadUnit(minutes: number): { count: number; unit: string } {
  if (minutes % 10080 === 0) return { count: minutes / 10080, unit: "week" };
  if (minutes % 1440 === 0) return { count: minutes / 1440, unit: "day" };
  if (minutes % 60 === 0) return { count: minutes / 60, unit: "hour" };
  return { count: minutes, unit: "minute" };
}


function threadId(startAt: string, groupIds: string): string {
  return `booking.${toEpoch(startAt) ?? startAt}-${groupIds.replace(/,/g, "_")}`;
}

// --- helpers -----------------------------------------------------------

export function buildLabels(slot: OwnedSlot): NotificationLabels {
  const start = DateTime.fromISO(slot.startAt).setZone(STOCKHOLM_TZ);
  const end = DateTime.fromISO(slot.endAt).setZone(STOCKHOLM_TZ);
  const locations = new Set(slot.groups.map((g) => g.location).filter(Boolean) as string[]);
  return {
    machines: slot.groups
      .slice()
      .sort((a, b) => a.groupId - b.groupId)
      .map((g) => g.groupName ?? `Group ${g.groupId}`),
    location: locations.size === 1 ? [...locations][0]! : "",
    dayLabel: start.isValid ? start.toFormat("ccc d LLL") : slot.startAt,
    startTime: start.isValid ? start.toFormat("HH:mm") : "",
    endTime: end.isValid ? end.toFormat("HH:mm") : ""
  };
}

/** The distinct, enabled offsets for a device, mirroring the app's two pickers. */
export function activeOffsets(device: DeviceRow): number[] {
  const raw = [device.alertMinutes, device.secondAlertMinutes];
  const seen = new Set<number>();
  const offsets: number[] = [];
  for (const value of raw) {
    if (value === null || value < 0) continue;
    if (seen.has(value)) continue;
    seen.add(value);
    offsets.push(value);
  }
  return offsets;
}

/** Collapses per-group booking rows back into one entry per timeslot. */
export function groupBookings(
  bookings: BookingRow[]
): { startAt: string; endAt: string; groupIds: number[]; labels: NotificationLabels }[] {
  const byStart = new Map<string, BookingRow[]>();
  for (const booking of bookings) {
    const list = byStart.get(booking.startAt);
    if (list) list.push(booking);
    else byStart.set(booking.startAt, [booking]);
  }
  return [...byStart.values()].map((rows) => {
    const slot: OwnedSlot = {
      startAt: rows[0]!.startAt,
      endAt: rows[0]!.endAt,
      groups: rows.map((r) => ({
        groupId: r.groupId,
        groupName: r.groupName,
        location: r.location
      }))
    };
    return {
      startAt: slot.startAt,
      endAt: slot.endAt,
      groupIds: rows.map((r) => r.groupId).sort((a, b) => a - b),
      labels: buildLabels(slot)
    };
  });
}

function dedupeSlots(slots: OwnedSlot[]): OwnedSlot[] {
  const byStart = new Map<string, OwnedSlot>();
  for (const slot of slots) {
    const existing = byStart.get(slot.startAt);
    if (!existing) {
      byStart.set(slot.startAt, slot);
      continue;
    }
    const ids = new Set(existing.groups.map((g) => g.groupId));
    for (const group of slot.groups) {
      if (!ids.has(group.groupId)) existing.groups.push(group);
    }
  }
  return [...byStart.values()];
}

export function toEpoch(iso: string): number | null {
  const parsed = DateTime.fromISO(iso);
  return parsed.isValid ? Math.floor(parsed.toSeconds()) : null;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Wires the push stack from the environment, or returns null when disabled. */
export function createPushService(
  aptus: AptusClient,
  logger?: LoggerLike
): PushService | null {
  if (process.env.PUSH_ENABLED !== "true") return null;
  const config = loadApnsConfig();
  if (!config) {
    logger?.warn?.({}, "PUSH_ENABLED is set but APNs configuration is incomplete");
    return null;
  }
  const store = new Store();
  return new PushService({ store, aptus, apns: new ApnsClient(config, logger), logger });
}
