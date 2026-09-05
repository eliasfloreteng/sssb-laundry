import { describe, expect, it } from "bun:test";
import { buildServer } from "../src/server.js";
import { UpstreamCheck, type TimeslotsSource } from "../src/upstream-check.js";
import type { TimeslotsResponse } from "../src/types.js";

const OBJECT_ID = "0000-0000-000";
const MINUTE = 60_000;

function week(groups: number, timeslots: number): TimeslotsResponse {
  return {
    week: { fromDate: "2026-09-01", toDate: "2026-09-07", timezone: "Europe/Stockholm" },
    groups: Array.from({ length: groups }, (_, i) => ({
      id: 162 + i,
      location: "Jerum 21 Tvättstuga",
      name: `Grupp ${i + 1}`
    })),
    timeslots: Array.from({ length: timeslots }, (_, i) => ({
      id: `slot-${i}`,
      startAt: "2026-09-01T06:00:00.000+02:00",
      endAt: "2026-09-01T08:00:00.000+02:00",
      localDate: "2026-09-01",
      startTime: "06:00",
      endTime: "08:00",
      spansMidnight: false,
      groups: []
    }))
  };
}

/**
 * An Aptus stand-in that records what it was asked for. It is typed as the
 * whole client so that a probe reaching for `bookTimeslot` would be a type
 * error here, not a booking on someone's real object id.
 */
function fakeAptus(...answers: Array<TimeslotsResponse | Error>) {
  const dates: string[] = [];
  const objectIds: string[] = [];
  let next = 0;
  const source: TimeslotsSource = {
    async listTimeslots(objectId, date) {
      objectIds.push(objectId);
      dates.push(date);
      const answer = answers[Math.min(next++, answers.length - 1)];
      if (answer instanceof Error) throw answer;
      return answer;
    }
  };
  return { source, dates, objectIds, get calls() { return next; } };
}

function upstreamError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code });
}

describe("upstream check", () => {
  it("reports ok, with what it scraped, after a passing probe", async () => {
    const aptus = fakeAptus(week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID });

    await check.run();

    const snapshot = check.snapshot();
    expect(snapshot.state).toBe("ok");
    expect(snapshot.ok).toBe(true);
    expect(snapshot.groups).toBe(2);
    expect(snapshot.timeslots).toBe(84);
    expect(snapshot.error).toBeNull();
    expect(snapshot.checkedAt).not.toBeNull();
  });

  it("probes the configured object id, read-only, for today's week", async () => {
    const aptus = fakeAptus(week(1, 12));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID });

    await check.run();

    expect(aptus.objectIds).toEqual([OBJECT_ID]);
    expect(aptus.dates[0]).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("never puts the object id in the snapshot", async () => {
    const aptus = fakeAptus(upstreamError("UPSTREAM_PARSE_ERROR", `No groups for ${OBJECT_ID}`));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID });

    await check.run();

    // The message is upstream's own, so it is dropped rather than trusted.
    expect(JSON.stringify(check.snapshot())).not.toContain(OBJECT_ID);
  });

  it("fails a probe that comes back empty, which is how a parser break looks", async () => {
    const aptus = fakeAptus(week(0, 0));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, failureThreshold: 1 });

    await check.run();

    const snapshot = check.snapshot();
    expect(snapshot.state).toBe("failed");
    expect(snapshot.ok).toBe(false);
    expect(snapshot.error?.code).toBe("UPSTREAM_EMPTY");
  });

  it("rides out one failure and only calls it after the threshold", async () => {
    const aptus = fakeAptus(upstreamError("UPSTREAM_UNAVAILABLE", "502 from Aptus"));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, failureThreshold: 2 });

    await check.run();
    // Aptus drops requests often enough that one miss is not an outage; a
    // monitor polling /status must not see this one.
    expect(check.snapshot()).toMatchObject({ state: "degraded", ok: true, consecutiveFailures: 1 });

    await check.run();
    expect(check.snapshot()).toMatchObject({ state: "failed", ok: false, consecutiveFailures: 2 });
  });

  it("clears the failure count as soon as a probe passes again", async () => {
    const aptus = fakeAptus(upstreamError("UPSTREAM_UNAVAILABLE", "502"), week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, failureThreshold: 1 });

    await check.run();
    expect(check.snapshot().ok).toBe(false);

    await check.run();
    expect(check.snapshot()).toMatchObject({ state: "ok", ok: true, consecutiveFailures: 0 });
    expect(check.snapshot().error).toBeNull();
  });

  it("goes stale when the loop itself stops landing probes", async () => {
    const aptus = fakeAptus(week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, intervalMinutes: 15 });

    await check.run();
    expect(check.snapshot(Date.now() + 30 * MINUTE).state).toBe("ok");

    const stale = check.snapshot(Date.now() + 60 * MINUTE);
    expect(stale.state).toBe("stale");
    expect(stale.ok).toBe(false);
  });

  it("is unknown before the first probe, and stale if one never arrives", () => {
    const aptus = fakeAptus(week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, intervalMinutes: 15 });

    // A redeploy must not read as an outage for the seconds before the first
    // probe comes back.
    expect(check.snapshot()).toMatchObject({ state: "unknown", ok: true });
    expect(check.snapshot(Date.now() + 60 * MINUTE).state).toBe("stale");
  });

  it("stays quiet, and never probes, with no object id configured", async () => {
    const aptus = fakeAptus(week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source });

    await check.run();

    expect(aptus.calls).toBe(0);
    expect(check.snapshot()).toMatchObject({ state: "disabled", ok: true });
  });

  it("runs one probe at a time", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    let calls = 0;
    const source: TimeslotsSource = {
      async listTimeslots() {
        calls += 1;
        await gate;
        return week(2, 84);
      }
    };
    const check = new UpstreamCheck({ aptus: source, objectId: OBJECT_ID });

    const first = check.run();
    await check.run();
    release();
    await first;

    expect(calls).toBe(1);
  });
});

describe("GET /status", () => {
  async function serverWith(check: UpstreamCheck) {
    const app = buildServer({ pushService: null, upstreamCheck: check });
    await app.ready();
    return app;
  }

  it("answers 200 with the last passing probe", async () => {
    const aptus = fakeAptus(week(2, 84));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID });
    await check.run();

    const app = await serverWith(check);
    try {
      const response = await app.inject({ method: "GET", url: "/status" });
      expect(response.statusCode).toBe(200);
      expect(response.json()).toMatchObject({
        ok: true,
        upstream: { state: "ok", groups: 2, timeslots: 84 }
      });
    } finally {
      await app.close();
    }
  });

  it("answers 503 once upstream has failed, so a monitor can see it", async () => {
    const aptus = fakeAptus(upstreamError("UPSTREAM_UNAVAILABLE", "502 from Aptus"));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, failureThreshold: 1 });
    await check.run();

    const app = await serverWith(check);
    try {
      const response = await app.inject({ method: "GET", url: "/status" });
      expect(response.statusCode).toBe(503);
      expect(response.json().upstream.error.code).toBe("UPSTREAM_UNAVAILABLE");
    } finally {
      await app.close();
    }
  });

  it("leaves /health alone: liveness must not follow a portal outage", async () => {
    const aptus = fakeAptus(upstreamError("UPSTREAM_UNAVAILABLE", "502 from Aptus"));
    const check = new UpstreamCheck({ aptus: aptus.source, objectId: OBJECT_ID, failureThreshold: 1 });
    await check.run();

    const app = await serverWith(check);
    try {
      const response = await app.inject({ method: "GET", url: "/health" });
      expect(response.statusCode).toBe(200);
      expect(response.json<{ ok: boolean }>()).toEqual({ ok: true });
    } finally {
      await app.close();
    }
  });
});
