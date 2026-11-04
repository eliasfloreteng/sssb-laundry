import { DateTime } from "luxon";
import type { LoggerLike } from "./aptus-client.js";
import type { DibsRow } from "./db.js";
import { DIBS_LIMIT } from "./dibs.js";
import { AppError } from "./errors.js";
import type { Backend } from "./server.js";
import { decodeTimeslotId, encodeTimeslotId } from "./timeslot-id.js";
import {
  STOCKHOLM_TZ,
  type ActionResponse,
  type BookingGroup,
  type CanonicalGroupState,
  type CanonicalTimeslot,
  type GroupActionResult,
  type TimeslotsResponse
} from "./types.js";

/**
 * The object number App Store and Google Play reviewers sign in with. Nobody
 * lives behind it: a request carrying it is answered from memory, here, and
 * never reaches Aptus, the database, the dibs worker or APNs.
 */
export const DEMO_OBJECT_ID = "0000-0000-000";

/** Lenient about separators — a reviewer types it by hand, on whatever keyboard. */
export function isDemoObjectId(objectId: string): boolean {
  return objectId.replace(/\D/g, "") === DEMO_OBJECT_ID.replace(/\D/g, "");
}

/** Sessions held at once, as in the rooms that allow two. A started one no longer counts. */
export const DEMO_SESSION_LIMIT = 2;

/** How far ahead booking is open. A week starting past it comes back empty — the end of the scroll. */
const BOOKING_DAYS = 28;

const GROUPS: readonly BookingGroup[] = [
  { id: 901, location: "Demo Tvättstuga", name: "Grupp 1" },
  { id: 902, location: "Demo Tvättstuga", name: "Grupp 2" }
];

/** One day as SSSB's rooms divide it; the last session runs past midnight. */
const SLOT_TIMES: readonly (readonly [string, string])[] = [
  ["02:00", "04:00"],
  ["04:00", "06:00"],
  ["06:00", "08:30"],
  ["08:30", "11:00"],
  ["11:00", "13:30"],
  ["13:30", "16:00"],
  ["16:00", "18:30"],
  ["18:30", "21:00"],
  ["21:00", "23:30"],
  ["23:30", "02:00"]
];

/** How sought after a start time is — evenings go first, nights hardly at all. */
const POPULARITY: Record<string, number> = {
  "02:00": 0.05,
  "04:00": 0.05,
  "06:00": 0.25,
  "08:30": 0.45,
  "11:00": 0.45,
  "13:30": 0.5,
  "16:00": 0.75,
  "18:30": 0.8,
  "21:00": 0.6,
  "23:30": 0.1
};

const BOOKED = new Set(["booked", "already_booked"]);
const CANCELLED = new Set(["cancelled", "not_booked"]);
const DIBS_GRACE_MS = 20 * 60_000;

type Slot = Omit<CanonicalTimeslot, "id" | "groups" | "priority">;

interface DemoState {
  /** The Stockholm day this state was made on; a new day starts over. */
  seededOn: string;
  /** Groups the demo account holds, by timeslot start. Never an empty set. */
  own: Map<string, Set<number>>;
  /** `startAt#groupId` given up by the demo account — free from then on, whoever held it before. */
  released: Set<string>;
  dibs: DibsRow[];
  /** Timeslot starts, most wanted first. */
  priority: string[];
  nextDibsId: number;
}

/**
 * The laundry room behind the demo object number: one shared, in-memory state
 * that every reviewer sees and that starts over each day.
 *
 * Who else holds a slot is decided by a hash of the slot itself, so the week
 * looks the same on every visit and only fills up as a day comes closer —
 * never the other way round. On top of that sit the demo account's own
 * bookings, the ones it gave up, its dibs and its order of preference.
 * Nothing here ever books anything for real: a dibs stays a place in line.
 */
class DemoLaundry {
  private state: DemoState;

  constructor(
    private readonly now: () => number,
    private readonly logger?: LoggerLike
  ) {
    this.state = this.seed();
  }

  // --- Aptus ------------------------------------------------------------

  listTimeslots(date: string): TimeslotsResponse {
    const state = this.current();
    const monday = parseDate(date).startOf("week");
    const week = {
      fromDate: monday.toISODate()!,
      toDate: monday.plus({ days: 6 }).toISODate()!,
      timezone: STOCKHOLM_TZ
    };
    const groups = GROUPS.map((group) => ({ ...group }));
    if (week.fromDate > this.lastBookableDate()) return { week, groups, timeslots: [] };

    const timeslots = weekSlots(monday).map((slot) => ({
      id: encodeTimeslotId(slot.startAt, slot.endAt),
      ...slot,
      groups: GROUPS.map((group) => this.groupState(state, slot, group.id))
    }));
    return { week, groups, timeslots };
  }

  bookTimeslot(timeslotId: string, groupIds: number[]): ActionResponse {
    const state = this.current();
    const slot = findSlot(timeslotId);
    validateGroupIds(groupIds);

    // One group at a time, as upstream does: the second of a pair sees the first already held.
    const results = groupIds.map((groupId): GroupActionResult => {
      if (!slot) return failure(groupId, "BOOK_SLOT_NOT_FOUND", "Timeslot does not exist in group calendar");
      const group = this.groupState(state, slot, groupId);
      if (group.status === "own") return { groupId, status: "already_booked", message: "Timeslot is already booked" };
      if (!group.canBook) return { groupId, status: "not_bookable", message: "Timeslot is not bookable for this group" };
      hold(state, slot.startAt, groupId);
      state.released.delete(`${slot.startAt}#${groupId}`);
      return { groupId, status: "booked", message: "Booked" };
    });
    return { timeslotId, results, overallStatus: overallStatus(results, BOOKED) };
  }

  cancelTimeslot(timeslotId: string, groupIds: number[]): ActionResponse {
    const state = this.current();
    const slot = findSlot(timeslotId);
    validateGroupIds(groupIds);

    const results = groupIds.map((groupId): GroupActionResult => {
      if (!slot) return failure(groupId, "CANCEL_SLOT_NOT_FOUND", "Timeslot does not exist in group calendar");
      const group = this.groupState(state, slot, groupId);
      if (group.status !== "own") return { groupId, status: "not_booked", message: "Timeslot is not booked for this group" };
      if (!group.canCancel) {
        return failure(groupId, "NOT_CANCELLABLE", "Timeslot cannot be cancelled from upstream response");
      }
      const held = state.own.get(slot.startAt)!;
      held.delete(groupId);
      if (held.size === 0) state.own.delete(slot.startAt);
      state.released.add(`${slot.startAt}#${groupId}`);
      return { groupId, status: "cancelled", message: "Cancelled" };
    });
    if (slot) this.forgetRankIfUnused(state, slot.startAt);
    return { timeslotId, results, overallStatus: overallStatus(results, CANCELLED) };
  }

  // --- dibs -------------------------------------------------------------

  callDibs(timeslotId: string, groupIds: number[], originToken: string | null): DibsRow[] {
    const state = this.current();
    const { startAt, endAt } = decodeTimeslotId(timeslotId);
    if (Date.parse(startAt) <= this.now()) {
      throw new AppError({ statusCode: 409, code: "TOO_LATE", message: "The timeslot has already started" });
    }
    const slot = findSlot(timeslotId);
    if (!slot || slot.endAt !== endAt) {
      throw new AppError({ statusCode: 404, code: "TIMESLOT_NOT_FOUND", message: "Timeslot does not exist" });
    }
    for (const groupId of groupIds) {
      if (!GROUPS.some((group) => group.id === groupId)) {
        throw new AppError({
          statusCode: 400,
          code: "INVALID_GROUP_IDS",
          message: `Group ${groupId} is not part of this timeslot`
        });
      }
      const group = this.groupState(state, slot, groupId);
      const waitable = group.status === "unavailable" || (group.status === "bookable" && !group.canBook);
      if (!waitable) {
        throw new AppError({
          statusCode: 409,
          code: "NOT_TAKEN",
          message: group.status === "own" ? "You already hold this timeslot" : "The timeslot is free — book it instead",
          details: { groupId, status: group.status }
        });
      }
    }

    const held = new Set(state.dibs.map((d) => d.startAt));
    if (!held.has(startAt) && held.size >= DIBS_LIMIT) {
      throw new AppError({
        statusCode: 409,
        code: "DIBS_LIMIT",
        message: `At most ${DIBS_LIMIT} timeslots can be waited on at once`,
        details: { limit: DIBS_LIMIT }
      });
    }

    for (const groupId of groupIds) {
      if (state.dibs.some((d) => d.startAt === startAt && d.groupId === groupId)) continue;
      state.dibs.push({
        id: state.nextDibsId++,
        objectId: DEMO_OBJECT_ID,
        startAt,
        endAt,
        groupId,
        originToken,
        createdAt: Math.floor(this.now() / 1000)
      });
    }
    if (!state.priority.includes(startAt)) state.priority.push(startAt);
    return state.dibs.filter((d) => d.startAt === startAt);
  }

  dropDibs(timeslotId: string, groupIds: number[]): void {
    const state = this.current();
    const { startAt } = decodeTimeslotId(timeslotId);
    state.dibs = state.dibs.filter((d) => d.startAt !== startAt || !groupIds.includes(d.groupId));
    // As live: the rank goes with the last dibs on the slot, booked or not.
    if (!state.dibs.some((d) => d.startAt === startAt)) {
      state.priority = state.priority.filter((s) => s !== startAt);
    }
  }

  dropAllDibs(): void {
    const state = this.current();
    state.dibs = [];
    state.priority = [];
  }

  setPriority(timeslotIds: string[]): void {
    const state = this.current();
    state.priority = [...new Set(timeslotIds.map((id) => decodeTimeslotId(id).startAt))];
  }

  annotate(response: TimeslotsResponse): TimeslotsResponse {
    const state = this.current();
    const rankOf = new Map(state.priority.map((startAt, index) => [startAt, index + 1]));
    const waiting = new Set(state.dibs.map((d) => `${d.startAt}#${d.groupId}`));
    for (const timeslot of response.timeslots) {
      const rank = rankOf.get(timeslot.startAt);
      if (rank !== undefined) timeslot.priority = rank;
      for (const group of timeslot.groups) {
        if (!waiting.has(`${timeslot.startAt}#${group.groupId}`)) continue;
        // Nobody else lines up in the demo, so the demo account is always next.
        group.dibs = true;
        group.dibsQueue = 1;
      }
    }
    return response;
  }

  // --- state ------------------------------------------------------------

  private today(): DateTime {
    return DateTime.fromMillis(this.now(), { zone: STOCKHOLM_TZ }).startOf("day");
  }

  private lastBookableDate(): string {
    return this.today().plus({ days: BOOKING_DAYS - 1 }).toISODate()!;
  }

  /** Today's state: made afresh on a new day, and rid of dibs whose wait is over. */
  private current(): DemoState {
    if (this.state.seededOn !== this.today().toISODate()) this.state = this.seed();
    const cutoff = this.now() - DIBS_GRACE_MS;
    const before = this.state.dibs.length;
    this.state.dibs = this.state.dibs.filter((d) => Date.parse(d.startAt) > cutoff);
    if (this.state.dibs.length !== before) {
      for (const startAt of this.state.priority) this.forgetRankIfUnused(this.state, startAt);
    }
    return this.state;
  }

  /**
   * A fresh day: a booking yesterday afternoon, already behind the account,
   * and one tomorrow evening — so a reviewer sees both, and has one session
   * left before the limit. On a Monday yesterday is last week, out of sight,
   * so the earlier one is this morning's instead.
   */
  private seed(): DemoState {
    const today = this.today();
    const state: DemoState = {
      seededOn: today.toISODate()!,
      own: new Map(),
      released: new Set(),
      dibs: [],
      priority: [],
      nextDibsId: 1
    };
    const at = (day: DateTime, time: string) => DateTime.fromISO(`${day.toISODate()}T${time}`, { zone: STOCKHOLM_TZ }).toISO()!;
    const earlier = today.weekday === 1 ? at(today, "06:00") : at(today.minus({ days: 1 }), "16:00");
    hold(state, earlier, GROUPS[0].id);
    for (const group of GROUPS) hold(state, at(today.plus({ days: 1 }), "18:30"), group.id);
    this.logger?.info?.({ seededOn: state.seededOn }, "Demo laundry room reset");
    return state;
  }

  private groupState(state: DemoState, slot: Slot, groupId: number): CanonicalGroupState {
    const started = Date.parse(slot.startAt) <= this.now();
    if (state.own.get(slot.startAt)?.has(groupId)) {
      return { groupId, status: "own", canBook: false, canCancel: !started };
    }

    const free =
      !started &&
      slot.localDate <= this.lastBookableDate() &&
      (state.released.has(`${slot.startAt}#${groupId}`) || !this.takenByOthers(slot, groupId));
    if (!free) return { groupId, status: "unavailable", canBook: false, canCancel: false };

    // As upstream: at the limit the slot is still free, but the book button is gone.
    // A second group of a timeslot already held is the same session.
    const atLimit = !state.own.has(slot.startAt) && this.sessionsAhead(state) >= DEMO_SESSION_LIMIT;
    return { groupId, status: "bookable", canBook: !atLimit, canCancel: false };
  }

  private sessionsAhead(state: DemoState): number {
    return [...state.own.keys()].filter((startAt) => Date.parse(startAt) > this.now()).length;
  }

  /** Somebody else's: fixed per slot, likelier the nearer and the more popular it is. */
  private takenByOthers(slot: Slot, groupId: number): boolean {
    const daysAhead = DateTime.fromISO(slot.localDate, { zone: STOCKHOLM_TZ }).diff(this.today(), "days").days;
    const nearness = daysAhead <= 1 ? 1 : daysAhead <= 3 ? 0.8 : daysAhead <= 7 ? 0.55 : daysAhead <= 14 ? 0.3 : 0.12;
    return unitHash(`${slot.startAt}#${groupId}`) < (POPULARITY[slot.startTime] ?? 0.3) * nearness;
  }

  /** A ranked timeslot that is neither booked nor waited on any more has nothing left to rank. */
  private forgetRankIfUnused(state: DemoState, startAt: string): void {
    if (state.own.has(startAt) || state.dibs.some((d) => d.startAt === startAt)) return;
    state.priority = state.priority.filter((s) => s !== startAt);
  }
}

/**
 * Everything the routes reach for, for the demo object number: the laundry
 * room above in place of Aptus and dibs, push that goes nowhere, and feedback
 * that still arrives — labelled, so it is never mistaken for a resident's.
 */
export function createDemoBackend(args: {
  feedback: Backend["feedback"];
  logger?: LoggerLike;
  now?: () => number;
}): Backend {
  const laundry = new DemoLaundry(args.now ?? Date.now, args.logger);
  const feedback = args.feedback;
  return {
    aptus: {
      listTimeslots: async (_objectId, date) => laundry.listTimeslots(date),
      bookTimeslot: async (_objectId, timeslotId, groupIds) => laundry.bookTimeslot(timeslotId, groupIds),
      cancelTimeslot: async (_objectId, timeslotId, groupIds) => laundry.cancelTimeslot(timeslotId, groupIds)
    },
    push: {
      // Accepted and forgotten: the demo sends no pushes, but the app's
      // reminder settings should still save without an error.
      supports: () => true,
      registerDevice: () => {},
      unregisterDevice: () => {},
      enqueueTestNotification: () => 0,
      onBooked: () => {},
      onCancelled: () => {}
    },
    dibs: {
      call: async (_objectId, timeslotId, groupIds, originToken) => laundry.callDibs(timeslotId, groupIds, originToken),
      drop: (_objectId, timeslotId, groupIds) => laundry.dropDibs(timeslotId, groupIds),
      dropAll: () => laundry.dropAllDibs(),
      setPriority: (_objectId, timeslotIds) => laundry.setPriority(timeslotIds),
      annotate: (_objectId, response) => laundry.annotate(response),
      // Nobody else waits in the demo, so there is nobody to hand a slot to.
      onReleased: () => {}
    },
    feedback: feedback && {
      submit: (objectId, message, context) =>
        feedback.submit(objectId, `🧪 From the demo account (store review), not a resident\n\n${message}`, context)
    }
  };
}

function hold(state: DemoState, startAt: string, groupId: number): void {
  const held = state.own.get(startAt) ?? new Set<number>();
  held.add(groupId);
  state.own.set(startAt, held);
}

/** A week of slots, built exactly as the calendar parser builds them from Aptus's HTML. */
function weekSlots(monday: DateTime): Slot[] {
  const slots: Slot[] = [];
  for (let day = 0; day < 7; day++) {
    const localDate = monday.plus({ days: day }).toISODate()!;
    for (const [startTime, endTime] of SLOT_TIMES) {
      const start = DateTime.fromISO(`${localDate}T${startTime}`, { zone: STOCKHOLM_TZ });
      let end = DateTime.fromISO(`${localDate}T${endTime}`, { zone: STOCKHOLM_TZ });
      const spansMidnight = end <= start;
      if (spansMidnight) end = end.plus({ days: 1 });
      slots.push({ startAt: start.toISO()!, endAt: end.toISO()!, localDate, startTime, endTime, spansMidnight });
    }
  }
  return slots;
}

/** The slot a timeslot id names, if the demo week has one like it. */
function findSlot(timeslotId: string): Slot | undefined {
  const { startAt, endAt } = decodeTimeslotId(timeslotId);
  const start = DateTime.fromISO(startAt, { zone: STOCKHOLM_TZ });
  if (!start.isValid || !DateTime.fromISO(endAt).isValid) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_ID",
      message: "Timeslot id has invalid datetime fields"
    });
  }
  return weekSlots(start.startOf("week")).find((slot) => slot.startAt === startAt && slot.endAt === endAt);
}

function parseDate(value: string): DateTime {
  const parsed = DateTime.fromISO(value, { zone: STOCKHOLM_TZ });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || !parsed.isValid) {
    throw new AppError({ statusCode: 400, code: "INVALID_DATE", message: "date must be YYYY-MM-DD" });
  }
  return parsed;
}

function validateGroupIds(groupIds: number[]): void {
  const available = GROUPS.map((group) => group.id);
  const invalid = groupIds.filter((groupId) => !available.includes(groupId));
  if (invalid.length) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_GROUP_IDS",
      message: "Unknown booking group ids",
      details: { invalid, available }
    });
  }
}

function failure(groupId: number, code: string, message: string): GroupActionResult {
  return { groupId, status: "failed", message, error: { code, message } };
}

function overallStatus(results: GroupActionResult[], succeeded: Set<string>): ActionResponse["overallStatus"] {
  const count = results.filter((result) => succeeded.has(result.status)).length;
  if (count === results.length) return "success";
  return count > 0 ? "partial_success" : "failed";
}

/** FNV-1a, scaled to [0, 1): the same slot always draws the same number. */
function unitHash(input: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0) / 0x1_0000_0000;
}
