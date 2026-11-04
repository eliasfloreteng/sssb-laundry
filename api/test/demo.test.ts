import { describe, expect, it } from "bun:test";
import { DateTime } from "luxon";
import type { AptusClient } from "../src/aptus-client.js";
import { createDemoBackend, DEMO_OBJECT_ID, DEMO_SESSION_LIMIT, isDemoObjectId } from "../src/demo.js";
import { FeedbackService, type FeedbackSender } from "../src/feedback.js";
import { buildServer } from "../src/server.js";
import { decodeTimeslotId } from "../src/timeslot-id.js";
import type { CanonicalTimeslot, TimeslotsResponse } from "../src/types.js";

const ZONE = "Europe/Stockholm";
/** A Wednesday morning, so the week has a past, a present and a future. */
const WEDNESDAY = DateTime.fromISO("2026-11-04T10:00", { zone: ZONE });

/** Aptus that fails the test the moment anything reaches it. */
const unreachableAptus = new Proxy(
  {},
  {
    get: () => () => {
      throw new Error("The demo reached Aptus");
    }
  }
) as unknown as AptusClient;

async function demoServer(options: { now?: () => number; sent?: string[] } = {}) {
  let now = options.now ?? (() => WEDNESDAY.toMillis());
  const sent = options.sent ?? [];
  const sender: FeedbackSender = { send: async (text) => void sent.push(text) };
  const feedbackService = new FeedbackService({ sender });
  // Push and dibs off, as on a server without APNs: the demo needs neither.
  const app = buildServer({
    aptusClient: unreachableAptus,
    pushService: null,
    dibsService: null,
    feedbackService,
    demoBackend: createDemoBackend({ feedback: feedbackService, now: () => now() })
  });
  await app.ready();

  const request = (method: "GET" | "POST" | "PUT" | "DELETE", url: string, payload?: unknown, objectId = DEMO_OBJECT_ID) =>
    app.inject({ method, url, headers: { "x-object-id": objectId }, payload: payload as Record<string, unknown> });
  const week = async (date = "2026-11-04") => (await request("GET", `/timeslots?date=${date}`)).json() as TimeslotsResponse;
  const setNow = (next: () => number) => {
    now = next;
  };
  return { app, request, week, sent, setNow };
}

function at(timeslots: CanonicalTimeslot[], localDate: string, startTime: string): CanonicalTimeslot {
  const found = timeslots.find((t) => t.localDate === localDate && t.startTime === startTime);
  if (!found) throw new Error(`No timeslot ${localDate} ${startTime}`);
  return found;
}

function freeSlots(timeslots: CanonicalTimeslot[]): CanonicalTimeslot[] {
  return timeslots.filter((t) => t.groups.every((g) => g.status === "bookable" && g.canBook));
}

describe("demo object number", () => {
  it("is recognised however it is typed, and nothing else is", () => {
    expect(isDemoObjectId("0000-0000-000")).toBe(true);
    expect(isDemoObjectId("00000000000")).toBe(true);
    expect(isDemoObjectId("0000 0000 000")).toBe(true);
    expect(isDemoObjectId("0000-0000-001")).toBe(false);
    expect(isDemoObjectId("0000-0000-0000")).toBe(false);
  });

  it("lists a week in the live shape, from memory", async () => {
    const { app, week } = await demoServer();
    try {
      const response = await week();
      expect(response.week).toEqual({ fromDate: "2026-11-02", toDate: "2026-11-08", timezone: ZONE });
      expect(response.groups.map((g) => g.name)).toEqual(["Grupp 1", "Grupp 2"]);
      expect(response.timeslots).toHaveLength(70);

      const late = at(response.timeslots, "2026-11-04", "23:30");
      expect(late).toMatchObject({ endTime: "02:00", spansMidnight: true });
      expect(decodeTimeslotId(late.id)).toEqual({ startAt: late.startAt, endAt: late.endAt });
      expect(late.endAt).toBe("2026-11-05T02:00:00.000+01:00");

      // What has started is no longer bookable, and a session behind you no longer cancellable.
      for (const t of response.timeslots.filter((t) => Date.parse(t.startAt) <= WEDNESDAY.toMillis())) {
        for (const g of t.groups) expect(g.canBook).toBe(false);
      }
      const yesterday = at(response.timeslots, "2026-11-03", "16:00");
      expect(yesterday.groups[0]).toMatchObject({ status: "own", canCancel: false });
      const tomorrow = at(response.timeslots, "2026-11-05", "18:30");
      expect(tomorrow.groups.every((g) => g.status === "own" && g.canCancel)).toBe(true);

      // Some of it taken by others, plenty of it free.
      const statuses = response.timeslots
        .filter((t) => Date.parse(t.startAt) > WEDNESDAY.toMillis())
        .flatMap((t) => t.groups.map((g) => g.status));
      expect(statuses.filter((s) => s === "unavailable").length).toBeGreaterThan(5);
      expect(statuses.filter((s) => s === "bookable").length).toBeGreaterThan(20);

      expect(await week()).toEqual(response);
    } finally {
      await app.close();
    }
  });

  it("ends the scroll four weeks out", async () => {
    const { app, week } = await demoServer();
    try {
      expect((await week("2026-11-30")).timeslots).toHaveLength(70);
      const past = await week("2026-12-07");
      expect(past.timeslots).toEqual([]);
      expect(past.week.fromDate).toBe("2026-12-07");
    } finally {
      await app.close();
    }
  });

  it("books and cancels in memory, up to the session limit", async () => {
    const { app, request, week } = await demoServer();
    try {
      const [first, second] = freeSlots((await week("2026-11-09")).timeslots);
      const booked = await request("POST", `/timeslots/${first.id}/book`, { groupIds: [901, 902] });
      expect(booked.statusCode).toBe(200);
      expect(booked.json()).toMatchObject({ overallStatus: "success", results: [{ status: "booked" }, { status: "booked" }] });
      expect(at((await week("2026-11-09")).timeslots, first.localDate, first.startTime).groups[0]).toMatchObject({
        status: "own",
        canCancel: true
      });

      // With the seeded booking tomorrow, that is the limit: free slots lose their book button.
      expect(DEMO_SESSION_LIMIT).toBe(2);
      const atLimit = at((await week("2026-11-09")).timeslots, second.localDate, second.startTime);
      expect(atLimit.groups[0]).toMatchObject({ status: "bookable", canBook: false });
      const refused = await request("POST", `/timeslots/${second.id}/book`, { groupIds: [901] });
      expect(refused.json()).toMatchObject({ overallStatus: "failed", results: [{ status: "not_bookable" }] });

      const cancelled = await request("POST", `/timeslots/${first.id}/cancel`, { groupIds: [901, 902] });
      expect(cancelled.json()).toMatchObject({ overallStatus: "success", results: [{ status: "cancelled" }, { status: "cancelled" }] });
      const after = await week("2026-11-09");
      expect(at(after.timeslots, first.localDate, first.startTime).groups[0]).toMatchObject({ status: "bookable", canBook: true });
      expect(at(after.timeslots, second.localDate, second.startTime).groups[0].canBook).toBe(true);
    } finally {
      await app.close();
    }
  });

  it("refuses what live refuses", async () => {
    const { app, request, week } = await demoServer();
    try {
      const { timeslots } = await week();
      const started = at(timeslots, "2026-11-04", "08:30");
      expect((await request("POST", `/timeslots/${started.id}/book`, { groupIds: [901] })).json().results[0].status).toBe(
        "not_bookable"
      );
      const behind = at(timeslots, "2026-11-03", "16:00");
      expect((await request("POST", `/timeslots/${behind.id}/cancel`, { groupIds: [901] })).json().results[0].error.code).toBe(
        "NOT_CANCELLABLE"
      );
      expect((await request("POST", `/timeslots/${behind.id}/book`, { groupIds: [185] })).json().error.code).toBe(
        "INVALID_GROUP_IDS"
      );
      expect((await request("POST", "/timeslots/ts_nope/book", { groupIds: [901] })).statusCode).toBe(400);
    } finally {
      await app.close();
    }
  });

  it("keeps dibs and their order in memory, where live would have none", async () => {
    const { app, request, week } = await demoServer();
    try {
      const { timeslots } = await week("2026-11-09");
      const taken = timeslots.filter((t) => t.groups.every((g) => g.status === "unavailable"));
      expect(taken.length).toBeGreaterThan(1);
      const [a, b] = taken;
      const tomorrow = at((await week()).timeslots, "2026-11-05", "18:30");

      const called = await request("POST", `/timeslots/${a.id}/dibs`, { groupIds: [901, 902] });
      expect(called.statusCode).toBe(200);
      expect(called.json<object>()).toEqual({ timeslotId: a.id, groupIds: [901, 902] });
      expect((await request("POST", `/timeslots/${b.id}/dibs`, { groupIds: [902] })).statusCode).toBe(200);

      let listed = (await week("2026-11-09")).timeslots;
      expect(at(listed, a.localDate, a.startTime)).toMatchObject({ priority: 1, groups: [{ dibs: true, dibsQueue: 1 }, { dibs: true }] });
      expect(at(listed, b.localDate, b.startTime).groups[0].dibs).toBeUndefined();

      const free = freeSlots(listed)[0];
      expect((await request("POST", `/timeslots/${free.id}/dibs`, { groupIds: [901] })).json().error.code).toBe("NOT_TAKEN");

      expect((await request("PUT", "/dibs/priority", { timeslotIds: [b.id, tomorrow.id, a.id] })).statusCode).toBe(200);
      listed = (await week("2026-11-09")).timeslots;
      expect(at(listed, b.localDate, b.startTime).priority).toBe(1);
      expect(at(listed, a.localDate, a.startTime).priority).toBe(3);
      expect(at((await week()).timeslots, "2026-11-05", "18:30").priority).toBe(2);

      expect((await request("DELETE", `/timeslots/${b.id}/dibs`, { groupIds: [902] })).statusCode).toBe(200);
      listed = (await week("2026-11-09")).timeslots;
      expect(at(listed, b.localDate, b.startTime).priority).toBeUndefined();

      expect((await request("DELETE", "/dibs")).statusCode).toBe(200);
      listed = (await week("2026-11-09")).timeslots;
      expect(listed.some((t) => t.priority !== undefined || t.groups.some((g) => g.dibs))).toBe(false);

      // A real object id on this server has no dibs at all.
      const live = await request("POST", `/timeslots/${a.id}/dibs`, { groupIds: [901] }, "1111-1111-111");
      expect(live.json().error.code).toBe("PUSH_DISABLED");
    } finally {
      await app.close();
    }
  });

  it("accepts a device and keeps nothing", async () => {
    const { app, request } = await demoServer();
    try {
      const device = { deviceToken: "a".repeat(64), environment: "production", alertMinutes: 30 };
      expect((await request("PUT", "/notifications/device", device)).json<object>()).toEqual({ ok: true });
      expect((await request("DELETE", "/notifications/device", { deviceToken: "a".repeat(64) })).json<object>()).toEqual({ ok: true });

      const android = { platform: "android", deviceToken: "dX:APA91b" + "y".repeat(140), alertMinutes: 30 };
      expect((await request("PUT", "/notifications/device", android)).json<object>()).toEqual({ ok: true });
      // An APNs-shaped token is not an FCM one, and an unknown platform is refused.
      expect((await request("PUT", "/notifications/device", { ...android, deviceToken: "a".repeat(64) })).statusCode).toBe(400);
      expect((await request("PUT", "/notifications/device", { ...device, platform: "windows" })).statusCode).toBe(400);
    } finally {
      await app.close();
    }
  });

  it("forwards feedback marked as the demo account's", async () => {
    const sent: string[] = [];
    const { app, request } = await demoServer({ sent });
    try {
      expect((await request("POST", "/feedback", { message: "Looks good" })).statusCode).toBe(200);
      expect(sent).toHaveLength(1);
      expect(sent[0]).toContain("demo account");
      expect(sent[0]).toContain("Looks good");
    } finally {
      await app.close();
    }
  });

  it("starts over on a new day", async () => {
    const { app, request, week, setNow } = await demoServer();
    try {
      const [slot] = freeSlots((await week("2026-11-09")).timeslots);
      await request("POST", `/timeslots/${slot.id}/book`, { groupIds: [901] });
      setNow(() => WEDNESDAY.plus({ days: 1 }).toMillis());
      const after = await week("2026-11-09");
      expect(at(after.timeslots, slot.localDate, slot.startTime).groups[0].status).not.toBe("own");
      // And seeds that day's own pair of bookings.
      const thisWeek = (await week()).timeslots;
      expect(at(thisWeek, "2026-11-04", "16:00").groups[0].status).toBe("own");
      expect(at(thisWeek, "2026-11-06", "18:30").groups[1].status).toBe("own");
    } finally {
      await app.close();
    }
  });

  it("keeps the earlier booking in sight on a Monday", async () => {
    const monday = DateTime.fromISO("2026-11-09T10:00", { zone: ZONE }).toMillis();
    const { app, week } = await demoServer({ now: () => monday });
    try {
      const { timeslots } = await week("2026-11-09");
      expect(at(timeslots, "2026-11-09", "06:00").groups[0]).toMatchObject({ status: "own", canCancel: false });
      expect(at(timeslots, "2026-11-10", "18:30").groups[0]).toMatchObject({ status: "own", canCancel: true });
    } finally {
      await app.close();
    }
  });
});
