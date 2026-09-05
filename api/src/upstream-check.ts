import { DateTime } from "luxon";
import { hashObjectId, type LoggerLike } from "./aptus-client.js";
import { STOCKHOLM_TZ, type TimeslotsResponse } from "./types.js";

/**
 * The half of AptusClient this probe is allowed to touch. Narrow on purpose:
 * the check runs against a real object id on a schedule, so nothing here may
 * book, cancel, or otherwise leave a trace the owner would have to undo — and
 * a wider type would make writing one an ordinary edit rather than a visible
 * one.
 */
export interface TimeslotsSource {
  listTimeslots(objectId: string, date: string, requestId?: string): Promise<TimeslotsResponse>;
}

export type UpstreamState =
  /** The last probe scraped a plausible week. */
  | "ok"
  /** Some probes have failed, but not enough in a row to call it. */
  | "degraded"
  /** Failed `failureThreshold` times in a row. */
  | "failed"
  /** No probe has landed in the window it should have — the loop itself is sick. */
  | "stale"
  /** Configured, but the first probe has not come back yet. */
  | "unknown"
  /** No object id configured; nothing is being probed. */
  | "disabled";

export interface UpstreamSnapshot {
  state: UpstreamState;
  /** What the state means for a monitor: false is the only thing worth waking for. */
  ok: boolean;
  checkedAt: string | null;
  lastOkAt: string | null;
  durationMs: number | null;
  groups: number | null;
  timeslots: number | null;
  consecutiveFailures: number;
  intervalMinutes: number;
  error: { code: string; message: string } | null;
}

export interface UpstreamCheckOptions {
  aptus: TimeslotsSource;
  /** Absent disables the probe rather than failing it. */
  objectId?: string;
  logger?: LoggerLike;
  intervalMinutes?: number;
  failureThreshold?: number;
}

const DEFAULT_INTERVAL_MINUTES = 15;
const DEFAULT_FAILURE_THRESHOLD = 2;

/** How many intervals may pass with no probe before the loop counts as broken. */
const STALE_INTERVALS = 3;

/**
 * A scheduled read-only probe of the Aptus portal, so that "the upstream this
 * whole API wraps has stopped answering" is something a monitor can see without
 * anyone opening the app.
 *
 * It lists one week of timeslots for a single object id, which is the same call
 * path the app's main screen takes: log in, read the categories, the groups, and
 * a calendar per group. An empty result counts as a failure — a portal that
 * changes its HTML answers `200` with nothing in it, and that is exactly the
 * silent break worth catching.
 *
 * Timers start in `startServer()` only, like the push service, so tests stay
 * timer-free. `/status` reads the last result and never probes on demand: this
 * endpoint is public, and upstream is a fragile ASP.NET portal that no visitor
 * should be able to pull on.
 */
export class UpstreamCheck {
  private readonly aptus: TimeslotsSource;
  private readonly objectId?: string;
  private readonly logger?: LoggerLike;
  private readonly intervalMinutes: number;
  private readonly failureThreshold: number;
  private readonly startedAt = Date.now();
  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;

  private checkedAt: number | null = null;
  private lastOkAt: number | null = null;
  private durationMs: number | null = null;
  private groups: number | null = null;
  private timeslots: number | null = null;
  private consecutiveFailures = 0;
  private error: { code: string; message: string } | null = null;

  constructor(options: UpstreamCheckOptions) {
    this.aptus = options.aptus;
    this.objectId = options.objectId;
    this.logger = options.logger;
    this.intervalMinutes = options.intervalMinutes ?? DEFAULT_INTERVAL_MINUTES;
    this.failureThreshold = options.failureThreshold ?? DEFAULT_FAILURE_THRESHOLD;
  }

  start(): void {
    if (!this.objectId) {
      this.logger?.warn?.({}, "UPSTREAM_CHECK_OBJECT_ID is unset; upstream is not being probed");
      return;
    }
    this.timer = setInterval(() => void this.run(), this.intervalMinutes * 60_000);
    this.timer.unref?.();
    // A redeploy would otherwise leave `/status` at "unknown" for a full
    // interval, which is the window a bad deploy most wants covered.
    void this.run();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** One probe. Never throws: a failure is a result, not an error to handle. */
  async run(): Promise<void> {
    const objectId = this.objectId;
    if (!objectId || this.running) return;
    this.running = true;

    const objectKey = hashObjectId(objectId);
    const date = DateTime.now().setZone(STOCKHOLM_TZ).toISODate()!;
    const startedAt = Date.now();
    try {
      const response = await this.aptus.listTimeslots(objectId, date);
      const groups = response.groups.length;
      const timeslots = response.timeslots.length;
      if (groups === 0 || timeslots === 0) {
        // The portal answered, so nothing threw — but the current week always
        // has groups and slots in it, so this is a parser or portal change.
        throw new EmptyWeekError(groups, timeslots);
      }
      this.record(startedAt, { groups, timeslots });
      this.logger?.debug?.(
        { objectKey, date, groups, timeslots, durationMs: this.durationMs },
        "Upstream check passed"
      );
    } catch (error) {
      this.record(startedAt, { error: describeUpstream(error, objectId) });
      this.logger?.warn?.(
        {
          objectKey,
          date,
          durationMs: this.durationMs,
          consecutiveFailures: this.consecutiveFailures,
          err: this.error
        },
        "Upstream check failed"
      );
    } finally {
      this.running = false;
    }
  }

  snapshot(now = Date.now()): UpstreamSnapshot {
    const state = this.stateAt(now);
    return {
      state,
      ok: state !== "failed" && state !== "stale",
      checkedAt: toIso(this.checkedAt),
      lastOkAt: toIso(this.lastOkAt),
      durationMs: this.durationMs,
      groups: this.groups,
      timeslots: this.timeslots,
      consecutiveFailures: this.consecutiveFailures,
      intervalMinutes: this.intervalMinutes,
      error: this.error
    };
  }

  private record(
    startedAt: number,
    outcome: { groups: number; timeslots: number } | { error: { code: string; message: string } }
  ): void {
    const finishedAt = Date.now();
    this.checkedAt = finishedAt;
    this.durationMs = finishedAt - startedAt;
    if ("error" in outcome) {
      this.consecutiveFailures += 1;
      this.error = outcome.error;
      return;
    }
    this.consecutiveFailures = 0;
    this.error = null;
    this.lastOkAt = finishedAt;
    this.groups = outcome.groups;
    this.timeslots = outcome.timeslots;
  }

  private stateAt(now: number): UpstreamState {
    if (!this.objectId) return "disabled";
    // A confirmed failure outranks staleness: it says more about what is wrong.
    if (this.consecutiveFailures >= this.failureThreshold) return "failed";
    // Before the first probe lands, the process start is what has to be recent —
    // otherwise a dead timer would read as a permanently forgivable "unknown".
    const since = this.checkedAt ?? this.startedAt;
    if (now - since > this.intervalMinutes * STALE_INTERVALS * 60_000) return "stale";
    if (this.checkedAt === null) return "unknown";
    return this.consecutiveFailures > 0 ? "degraded" : "ok";
  }
}

/** Wires the probe from the environment. Unset object id disables it, loudly once. */
export function createUpstreamCheck(aptus: TimeslotsSource, logger?: LoggerLike): UpstreamCheck {
  return new UpstreamCheck({
    aptus,
    // Never logged, never in a response: it is a credential upstream.
    objectId: process.env.UPSTREAM_CHECK_OBJECT_ID?.trim() || undefined,
    logger,
    intervalMinutes: positiveNumber(process.env.UPSTREAM_CHECK_MINUTES) ?? DEFAULT_INTERVAL_MINUTES,
    failureThreshold:
      positiveNumber(process.env.UPSTREAM_CHECK_FAILURES) ?? DEFAULT_FAILURE_THRESHOLD
  });
}

class EmptyWeekError extends Error {
  readonly code = "UPSTREAM_EMPTY";

  constructor(groups: number, timeslots: number) {
    super(`Aptus returned ${groups} groups and ${timeslots} timeslots for the current week`);
    this.name = "EmptyWeekError";
  }
}

/**
 * Errors as the monitor gets to see them: a code and a sentence. `AppError`'s
 * `details` are deliberately dropped — they carry HTML previews, and `/status`
 * is public. The message is upstream's wording rather than ours, so the object
 * id is scrubbed out of it: it is a credential, and this endpoint needs no
 * authentication to read.
 */
function describeUpstream(error: unknown, objectId: string): { code: string; message: string } {
  const code =
    typeof (error as { code?: unknown })?.code === "string"
      ? (error as { code: string }).code
      : "UNKNOWN_ERROR";
  const message = error instanceof Error ? error.message : String(error);
  return { code, message: message.split(objectId).join("<object-id>") };
}

function toIso(epochMs: number | null): string | null {
  return epochMs === null ? null : new Date(epochMs).toISOString();
}

function positiveNumber(raw: string | undefined): number | undefined {
  const value = Number(raw);
  return raw !== undefined && Number.isFinite(value) && value > 0 ? value : undefined;
}
