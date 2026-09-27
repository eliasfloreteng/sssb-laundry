import { DateTime } from "luxon";
import { AppError } from "./errors.js";
import { hashObjectId, type AptusClient, type LoggerLike } from "./aptus-client.js";
import { nowSeconds, type DibsRow, type Store } from "./db.js";
import { toEpoch, type OwnedSlot, type PushService } from "./notifications.js";
import { decodeTimeslotId, encodeTimeslotId } from "./timeslot-id.js";
import { STOCKHOLM_TZ, type TimeslotsResponse } from "./types.js";

/**
 * Open dibs per object id, counted in timeslots — both groups of one are one.
 * Not SSSB's quota: winning more than that is what the order of preference
 * sorts out. This only bounds what one object id can have watched.
 */
export const DIBS_LIMIT = 10;

/** The longest order of preference accepted — every dibs plus every booking. */
export const PRIORITY_LIMIT = 30;

/**
 * Aptus releases a session nobody tagged into 15 minutes after its start. The
 * window is watched closely from just before that until a few minutes after,
 * and a dibs still standing at its end has lost.
 */
const GRACE_OPENS_SECONDS = 14 * 60 + 30;
const GRACE_CLOSES_SECONDS = 20 * 60;
const GRACE_TICK_MS = 20_000;

const BOOKED = new Set(["booked", "already_booked"]);
const CANCELLED = new Set(["cancelled", "not_booked"]);

/** The part of the Aptus client dibs needs — reading a week, booking, and giving a booking up for a better one. */
export type DibsAptus = Pick<AptusClient, "listTimeslots" | "bookTimeslot" | "cancelTimeslot">;

/** How one attempt at booking a freed group went. */
type Attempt = "booked" | "refused" | "failed";

export interface DibsServiceOptions {
  store: Store;
  aptus: DibsAptus;
  push: PushService;
  logger?: LoggerLike;
  pollMinutes?: number;
}

/**
 * A waiting list for a timeslot somebody else holds. Aptus has no such thing:
 * a slot frees when its holder cancels, or when they fail to tag in within the
 * grace period, and whoever happens to look first gets it. Here, the server
 * looks — and books it for the first object id in line.
 *
 * Everything runs through one promise chain, so a sweep and a cancellation
 * arriving mid-sweep never book the same slot twice.
 */
export class DibsService {
  private readonly store: Store;
  private readonly aptus: DibsAptus;
  private readonly push: PushService;
  private readonly logger?: LoggerLike;
  private readonly pollMinutes: number;
  private timers: ReturnType<typeof setInterval>[] = [];
  private chain: Promise<void> = Promise.resolve();
  /**
   * `objectId#startAt` of dibs whose swap fell through: something other than
   * the session limit refused them, and a retry every sweep would cancel and
   * rebook the same booking over and over. Cleared when the order changes.
   */
  private readonly swapFailed = new Set<string>();

  constructor(options: DibsServiceOptions) {
    this.store = options.store;
    this.aptus = options.aptus;
    this.push = options.push;
    this.logger = options.logger;
    this.pollMinutes = options.pollMinutes ?? Number(process.env.DIBS_POLL_MINUTES ?? 2);
  }

  start(): void {
    this.timers.push(setInterval(() => void this.sweep("ahead"), this.pollMinutes * 60_000));
    this.timers.push(setInterval(() => void this.sweep("grace"), GRACE_TICK_MS));
    for (const timer of this.timers) timer.unref?.();
    void this.sweep("ahead");
  }

  stop(): void {
    for (const timer of this.timers) clearInterval(timer);
    this.timers = [];
  }

  // --- route hooks -----------------------------------------------------

  /**
   * Queues this object id on groups of a timeslot it cannot book yet: one
   * somebody else holds, or one that is free but past the caller's session
   * limit — booked for them once a session of theirs starts or is cancelled.
   * A group the caller could book right now should just be booked, and a
   * started one has nothing left to wait for.
   */
  async call(
    objectId: string,
    timeslotId: string,
    groupIds: number[],
    originToken: string | null,
    requestId?: string
  ): Promise<DibsRow[]> {
    const { startAt, endAt } = decodeTimeslotId(timeslotId);
    if (isStarted(startAt)) {
      throw new AppError({ statusCode: 409, code: "TOO_LATE", message: "The timeslot has already started" });
    }

    const week = await this.aptus.listTimeslots(objectId, localDate(startAt), requestId);
    const timeslot = week.timeslots.find((t) => t.startAt === startAt && t.endAt === endAt);
    if (!timeslot) {
      throw new AppError({ statusCode: 404, code: "TIMESLOT_NOT_FOUND", message: "Timeslot does not exist" });
    }
    for (const groupId of groupIds) {
      const group = timeslot.groups.find((g) => g.groupId === groupId);
      if (!group) {
        throw new AppError({
          statusCode: 400,
          code: "INVALID_GROUP_IDS",
          message: `Group ${groupId} is not part of this timeslot`
        });
      }
      // Read as the caller: no book button on a free group is their own
      // session limit. Past the booking window Aptus shows slots as taken.
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

    const held = new Set(this.store.dibsForObject(objectId).map((d) => d.startAt));
    if (!held.has(startAt) && held.size >= DIBS_LIMIT) {
      throw new AppError({
        statusCode: 409,
        code: "DIBS_LIMIT",
        message: `At most ${DIBS_LIMIT} timeslots can be waited on at once`,
        details: { limit: DIBS_LIMIT }
      });
    }

    this.store.transaction(() => {
      for (const groupId of groupIds) {
        this.store.insertDibs({ objectId, startAt, endAt, groupId, originToken });
      }
      // Wanted least until the user says otherwise, so a new dibs never costs
      // a booking they have not ranked below it.
      this.store.appendPriority(objectId, startAt, endAt);
    });
    this.logger?.info?.({ objectKey: hashObjectId(objectId), startAt, groupIds }, "Dibs called");
    return this.store.dibsForObject(objectId).filter((d) => d.startAt === startAt);
  }

  drop(objectId: string, timeslotId: string, groupIds: number[]): void {
    const { startAt } = decodeTimeslotId(timeslotId);
    for (const groupId of groupIds) this.store.deleteDibs(objectId, startAt, groupId);
    // Its rank goes with the last dibs on it. Were the slot also booked, that
    // leaves the booking unranked, which is the side that never gets given up.
    if (!this.store.dibsForObject(objectId).some((d) => d.startAt === startAt)) {
      this.store.deletePriority(objectId, startAt);
    }
  }

  /** Every dibs and the order of preference — the app turned dibs off. */
  dropAll(objectId: string): void {
    this.store.deleteAllDibs(objectId);
  }

  /**
   * The order the object id wants its timeslots in, most wanted first: dibs
   * and bookings together. A booking ranked below a dibs is given up for it
   * when that dibs frees and Aptus's session limit is what stands in the way.
   */
  setPriority(objectId: string, timeslotIds: string[]): void {
    const seen = new Set<string>();
    const slots: { startAt: string; endAt: string }[] = [];
    for (const id of timeslotIds) {
      const slot = decodeTimeslotId(id);
      if (seen.has(slot.startAt)) continue;
      seen.add(slot.startAt);
      slots.push(slot);
    }
    this.store.setPriority(objectId, slots);
    // A new order is a new question: every swap gets its chance again.
    for (const key of this.swapFailed) {
      if (key.startsWith(`${objectId}#`)) this.swapFailed.delete(key);
    }
  }

  /** Marks the caller's dibs, their place in line, and their order of preference, on a week listing. */
  annotate(objectId: string, response: TimeslotsResponse): TimeslotsResponse {
    const mine = this.store.dibsForObject(objectId);
    const ranking = this.store.priorityForObject(objectId);
    if (mine.length === 0 && ranking.length === 0) return response;
    const byKey = new Map(mine.map((d) => [`${d.startAt}#${d.groupId}`, d]));
    const rankOf = new Map(ranking.map((p, index) => [p.startAt, index + 1]));

    for (const timeslot of response.timeslots) {
      const rank = rankOf.get(timeslot.startAt);
      if (rank !== undefined) timeslot.priority = rank;
      for (const group of timeslot.groups) {
        const dibs = byKey.get(`${timeslot.startAt}#${group.groupId}`);
        if (!dibs) continue;
        group.dibs = true;
        group.dibsQueue = this.store.dibsQueue(dibs.startAt, dibs.groupId).findIndex((d) => d.id === dibs.id) + 1;
      }
    }
    return response;
  }

  /**
   * A holder cancelled through this app: the slot is free this instant, so the
   * first in line gets it without waiting for a poll.
   */
  onReleased(startAt: string, endAt: string, groupIds: number[]): void {
    const queued = groupIds.filter((groupId) => this.store.dibsQueue(startAt, groupId).length > 0);
    if (queued.length === 0) return;
    void this.enqueue(async () => {
      for (const groupId of queued) await this.claim(startAt, endAt, groupId, null);
    });
  }

  // --- watching --------------------------------------------------------

  /**
   * `ahead` watches every dibs whose slot has not started, for a cancellation;
   * `grace` watches only those around the release at start + 15 minutes, and
   * runs far more often. One listing per week covers every dibs in it.
   */
  sweep(mode: "ahead" | "grace"): Promise<void> {
    return this.enqueue(async () => {
      const now = nowSeconds();
      // A dibs still standing once the grace window has closed never came
      // through. Dropped without a push — the user asked to hear only good news.
      const cutoff = DateTime.fromSeconds(now - GRACE_CLOSES_SECONDS).toISO()!;
      this.store.pruneDibsStartedBefore(cutoff);

      const due = this.store.openDibs().filter((d) => {
        const start = toEpoch(d.startAt);
        if (start === null) return false;
        return mode === "ahead"
          ? start > now
          : now >= start + GRACE_OPENS_SECONDS && now < start + GRACE_CLOSES_SECONDS;
      });
      if (due.length === 0) return;

      const byWeek = new Map<string, DibsRow[]>();
      for (const dibs of due) {
        const key = weekKey(dibs.startAt);
        const list = byWeek.get(key);
        if (list) list.push(dibs);
        else byWeek.set(key, [dibs]);
      }

      for (const rows of byWeek.values()) await this.checkWeek(rows);
    });
  }

  private async checkWeek(rows: DibsRow[]): Promise<void> {
    // Anyone in line can read the week; the first one is as good as any.
    const viewer = rows[0]!;
    let week: TimeslotsResponse;
    try {
      week = await this.aptus.listTimeslots(viewer.objectId, localDate(viewer.startAt));
    } catch (error) {
      this.logger?.warn?.(
        { objectKey: hashObjectId(viewer.objectId), err: describe(error) },
        "Dibs poll failed, trying again next tick"
      );
      return;
    }

    const seen = new Set<string>();
    for (const dibs of rows) {
      const key = `${dibs.startAt}#${dibs.groupId}`;
      if (seen.has(key)) continue;
      seen.add(key);

      const timeslot = week.timeslots.find((t) => t.startAt === dibs.startAt);
      const group = timeslot?.groups.find((g) => g.groupId === dibs.groupId);
      if (!timeslot || !group) continue;

      // The viewer took it some other way — their own dibs has done its job.
      if (group.status === "own" && dibs.objectId === viewer.objectId) {
        this.store.deleteDibs(viewer.objectId, dibs.startAt, dibs.groupId);
        continue;
      }
      // Free is the class, not the button: a viewer at their session limit
      // gets no book button on a slot that is free for everyone else in line.
      if (group.status !== "bookable") continue;

      if (isStarted(dibs.startAt)) {
        // The evidence for whether Aptus books a released session at all.
        this.logger?.info?.(
          { startAt: dibs.startAt, groupId: dibs.groupId, canBook: group.canBook },
          "Dibs: started timeslot seen free again"
        );
      }
      await this.claim(dibs.startAt, dibs.endAt, dibs.groupId, week);
    }
  }

  /**
   * Books a freed (timeslot, group) for the first object id in line that
   * Aptus will take it for. One that cannot — at its session limit, most
   * likely — first gets the chance to give up a booking it wants less; one
   * that still cannot is passed over but keeps its place: if nobody gets it,
   * the slot was taken again first and everyone waits on.
   */
  private async claim(
    startAt: string,
    endAt: string,
    groupId: number,
    week: TimeslotsResponse | null
  ): Promise<void> {
    const timeslotId = encodeTimeslotId(startAt, endAt);
    for (const dibs of this.store.dibsQueue(startAt, groupId)) {
      const objectKey = hashObjectId(dibs.objectId);
      let replaced: { startAt: string } | undefined;
      let attempt = await this.book(dibs.objectId, timeslotId, groupId);
      // A started slot is not a future session, so the quota is not what
      // refused it and nothing booked is worth giving up for it.
      if (attempt === "refused" && !isStarted(startAt)) {
        const swap = await this.swap(dibs, timeslotId, groupId);
        if (swap) {
          attempt = "booked";
          replaced = swap;
        }
      }
      if (attempt !== "booked") {
        this.logger?.info?.({ objectKey, startAt, groupId, attempt }, "Dibs passed over");
        continue;
      }

      this.store.deleteDibsForSlot(startAt, groupId);
      this.logger?.info?.({ objectKey, startAt, groupId, swapped: Boolean(replaced) }, "Dibs came through");
      const info = week?.groups.find((g) => g.id === groupId);
      const slot: OwnedSlot = {
        startAt,
        endAt,
        groups: [{ groupId, groupName: info?.name ?? null, location: info?.location ?? null }]
      };
      this.push.onDibsWon(dibs.objectId, slot, replaced);
      return;
    }
  }

  private async book(objectId: string, timeslotId: string, groupId: number): Promise<Attempt> {
    try {
      const response = await this.aptus.bookTimeslot(objectId, timeslotId, [groupId]);
      const result = response.results[0];
      if (result && BOOKED.has(result.status)) return "booked";
      // No book button for this viewer on a slot that is free for everyone:
      // the session limit, nearly always.
      return result?.status === "not_bookable" ? "refused" : "failed";
    } catch (error) {
      this.logger?.warn?.(
        { objectKey: hashObjectId(objectId), timeslotId, groupId, err: describe(error) },
        "Dibs booking failed"
      );
      return "failed";
    }
  }

  /**
   * Gives up the booking this object id wants least — only one it ranked
   * below the dibs — and books the dibs in its place. Either both happen or,
   * as near as Aptus allows, neither: a dibs that still cannot be booked puts
   * the old booking straight back, before anyone else in line hears it freed.
   * Resolves to the booking given up, or null when nothing was swapped.
   */
  private async swap(dibs: DibsRow, timeslotId: string, groupId: number): Promise<{ startAt: string } | null> {
    const objectKey = hashObjectId(dibs.objectId);
    const failedKey = `${dibs.objectId}#${dibs.startAt}`;
    if (this.swapFailed.has(failedKey)) return null;
    const ranking = this.store.priorityForObject(dibs.objectId);
    const rank = ranking.findIndex((p) => p.startAt === dibs.startAt);
    if (rank < 0) return null;

    // Wanted least first. Only the first one actually held is tried: one
    // session given back is all a single booking needs.
    for (const entry of ranking.slice(rank + 1).reverse()) {
      if (isStarted(entry.startAt)) continue;
      const held = await this.heldGroups(dibs.objectId, entry);
      if (held === null) return null;
      if (held.length === 0) continue;

      const entryId = encodeTimeslotId(entry.startAt, entry.endAt);
      let released: number[];
      try {
        const response = await this.aptus.cancelTimeslot(dibs.objectId, entryId, held);
        released = response.results.filter((r) => CANCELLED.has(r.status)).map((r) => r.groupId);
      } catch (error) {
        this.logger?.warn?.({ objectKey, err: describe(error) }, "Dibs swap: cancelling failed");
        return null;
      }

      const attempt = released.length === held.length ? await this.book(dibs.objectId, timeslotId, groupId) : "failed";
      if (attempt !== "booked") {
        if (released.length > 0) await this.restore(dibs.objectId, entry, released);
        // A dibs on a free slot is retried every sweep; its swap must not be.
        this.swapFailed.add(failedKey);
        this.logger?.info?.({ objectKey, startAt: dibs.startAt, groupId }, "Dibs swap fell through, not retried");
        return null;
      }

      this.logger?.info?.(
        { objectKey, startAt: dibs.startAt, groupId, replacedStartAt: entry.startAt },
        "Dibs swap: gave up a booking wanted less"
      );
      this.store.deletePriority(dibs.objectId, entry.startAt);
      this.push.onCancelled(dibs.objectId, entry.startAt, released);
      // Only now is it free for anyone else in line for it. Queued behind this
      // claim rather than awaited, so the chain stays one task at a time.
      this.onReleased(entry.startAt, entry.endAt, released);
      return { startAt: entry.startAt };
    }
    return null;
  }

  /**
   * The groups of a ranked timeslot this object id holds and may still hand
   * back — none when it no longer holds it, null when Aptus could not say.
   */
  private async heldGroups(objectId: string, entry: { startAt: string; endAt: string }): Promise<number[] | null> {
    try {
      const week = await this.aptus.listTimeslots(objectId, localDate(entry.startAt));
      const timeslot = week.timeslots.find((t) => t.startAt === entry.startAt);
      return timeslot?.groups.filter((g) => g.status === "own" && g.canCancel).map((g) => g.groupId) ?? [];
    } catch (error) {
      this.logger?.warn?.(
        { objectKey: hashObjectId(objectId), err: describe(error) },
        "Dibs swap: reading the booking failed"
      );
      return null;
    }
  }

  /** Puts back a booking given up for a dibs that then fell through. */
  private async restore(objectId: string, entry: { startAt: string; endAt: string }, groupIds: number[]): Promise<void> {
    const objectKey = hashObjectId(objectId);
    let lost = groupIds;
    try {
      const response = await this.aptus.bookTimeslot(objectId, encodeTimeslotId(entry.startAt, entry.endAt), groupIds);
      lost = response.results.filter((r) => !BOOKED.has(r.status)).map((r) => r.groupId);
    } catch (error) {
      this.logger?.error?.({ objectKey, err: describe(error) }, "Dibs swap: putting a booking back failed");
    }
    if (lost.length === 0) return;
    // Somebody took it in the moment between. Its reminders must not outlive it.
    this.logger?.error?.({ objectKey, startAt: entry.startAt, groupIds: lost }, "Dibs swap: could not put a booking back");
    this.push.onCancelled(objectId, entry.startAt, lost);
  }

  private enqueue(task: () => Promise<void>): Promise<void> {
    const run = this.chain.then(task).catch((error) => {
      this.logger?.error?.({ err: describe(error) }, "Dibs task failed");
    });
    this.chain = run;
    return run;
  }
}

function isStarted(startAt: string): boolean {
  const start = toEpoch(startAt);
  return start !== null && start <= nowSeconds();
}

function localDate(iso: string): string {
  return DateTime.fromISO(iso).setZone(STOCKHOLM_TZ).toFormat("yyyy-MM-dd");
}

/** Monday of the Stockholm week — the unit one listing covers. */
function weekKey(iso: string): string {
  return DateTime.fromISO(iso).setZone(STOCKHOLM_TZ).startOf("week").toFormat("yyyy-MM-dd");
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Dibs needs push — its only way to tell anyone it came through. */
export function createDibsService(
  push: PushService | null,
  aptus: DibsAptus,
  logger?: LoggerLike
): DibsService | null {
  return push ? new DibsService({ store: push.store, aptus, push, logger }) : null;
}
