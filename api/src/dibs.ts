import { DateTime } from "luxon";
import { AppError } from "./errors.js";
import { hashObjectId, type AptusClient, type LoggerLike } from "./aptus-client.js";
import { nowSeconds, type DibsRow, type Store } from "./db.js";
import { toEpoch, type OwnedSlot, type PushService } from "./notifications.js";
import { decodeTimeslotId, encodeTimeslotId } from "./timeslot-id.js";
import { STOCKHOLM_TZ, type TimeslotsResponse } from "./types.js";

/** Open dibs per object id, counted in timeslots — both groups of one are one. */
export const DIBS_LIMIT = 2;

/**
 * Aptus releases a session nobody tagged into 15 minutes after its start. The
 * window is watched closely from just before that until a few minutes after,
 * and a dibs still standing at its end has lost.
 */
const GRACE_OPENS_SECONDS = 14 * 60 + 30;
const GRACE_CLOSES_SECONDS = 20 * 60;
const GRACE_TICK_MS = 20_000;

const BOOKED = new Set(["booked", "already_booked"]);

/** The part of the Aptus client dibs needs — reading a week and booking. */
export type DibsAptus = Pick<AptusClient, "listTimeslots" | "bookTimeslot">;

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
   * Queues this object id on groups of a timeslot someone else holds. Only a
   * taken group that has not started can be dibs'd: a free one should just be
   * booked, and a started one has nothing left to wait for.
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
      if (group.status !== "unavailable") {
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

    for (const groupId of groupIds) {
      this.store.insertDibs({ objectId, startAt, endAt, groupId, originToken });
    }
    this.logger?.info?.({ objectKey: hashObjectId(objectId), startAt, groupIds }, "Dibs called");
    return this.store.dibsForObject(objectId).filter((d) => d.startAt === startAt);
  }

  drop(objectId: string, timeslotId: string, groupIds: number[]): void {
    const { startAt } = decodeTimeslotId(timeslotId);
    for (const groupId of groupIds) this.store.deleteDibs(objectId, startAt, groupId);
  }

  /** Marks the caller's dibs, and their place in line, on a week listing. */
  annotate(objectId: string, response: TimeslotsResponse): TimeslotsResponse {
    const mine = this.store.dibsForObject(objectId);
    if (mine.length === 0) return response;
    const byKey = new Map(mine.map((d) => [`${d.startAt}#${d.groupId}`, d]));

    for (const timeslot of response.timeslots) {
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
   * likely — is passed over but keeps its place: if nobody gets it, the slot
   * was taken again first and everyone waits on.
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
      try {
        const response = await this.aptus.bookTimeslot(dibs.objectId, timeslotId, [groupId]);
        const result = response.results[0];
        if (!result || !BOOKED.has(result.status)) {
          this.logger?.info?.({ objectKey, startAt, groupId, status: result?.status }, "Dibs passed over");
          continue;
        }
      } catch (error) {
        this.logger?.warn?.({ objectKey, startAt, groupId, err: describe(error) }, "Dibs booking failed");
        continue;
      }

      this.store.deleteDibsForSlot(startAt, groupId);
      this.logger?.info?.({ objectKey, startAt, groupId }, "Dibs came through");
      const info = week?.groups.find((g) => g.id === groupId);
      const slot: OwnedSlot = {
        startAt,
        endAt,
        groups: [{ groupId, groupName: info?.name ?? null, location: info?.location ?? null }]
      };
      this.push.onDibsWon(dibs.objectId, slot);
      return;
    }
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
