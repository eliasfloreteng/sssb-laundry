import { describe, expect, it } from "bun:test";
import { Store } from "../src/db.js";
import { PushService, activeOffsets, buildLabels, buildPayload, leadLabel } from "../src/notifications.js";
import type { AptusClient } from "../src/aptus-client.js";
import type { ApnsClient } from "../src/apns.js";
import type { TimeslotsResponse } from "../src/types.js";

const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

function memoryStore(): Store {
  return new Store(":memory:");
}

/** A week response holding `own` groups on one timeslot. */
function week(args: {
  fromDate: string;
  toDate: string;
  startAt?: string;
  endAt?: string;
  ownGroups?: number[];
}): TimeslotsResponse {
  const { startAt, endAt, ownGroups = [] } = args;
  return {
    week: { fromDate: args.fromDate, toDate: args.toDate, timezone: "Europe/Stockholm" },
    groups: [
      { id: 162, location: "Domus", name: "Grupp 1" },
      { id: 163, location: "Domus", name: "Grupp 2" }
    ],
    timeslots:
      startAt && endAt
        ? [
            {
              id: "ts_x",
              startAt,
              endAt,
              localDate: startAt.slice(0, 10),
              startTime: "07:00",
              endTime: "10:00",
              spansMidnight: false,
              groups: [162, 163].map((groupId) => ({
                groupId,
                status: ownGroups.includes(groupId) ? ("own" as const) : ("bookable" as const),
                canBook: !ownGroups.includes(groupId),
                canCancel: ownGroups.includes(groupId)
              }))
            }
          ]
        : []
  };
}

function service(args: {
  store: Store;
  responses: TimeslotsResponse[] | (() => never);
  sent?: unknown[];
}): PushService {
  const responses = args.responses;
  let call = 0;
  const aptus = {
    listTimeslots: async () => {
      if (typeof responses === "function") return responses();
      const response = responses[Math.min(call, responses.length - 1)]!;
      call += 1;
      return response;
    }
  } as unknown as AptusClient;

  const apns = {
    send: async (request: unknown) => {
      args.sent?.push(request);
      return { kind: "sent" as const };
    },
    close: () => {}
  } as unknown as ApnsClient;

  return new PushService({ store: args.store, aptus, apns, pollWeeks: 1 });
}

/** Start far enough out that every alert offset is still in the future. */
function futureSlot() {
  const start = new Date(Date.now() + 30 * 24 * 3600 * 1000);
  start.setUTCMinutes(0, 0, 0);
  const end = new Date(start.getTime() + 3 * 3600 * 1000);
  return { startAt: start.toISOString(), endAt: end.toISOString() };
}

describe("alert offsets", () => {
  it("drops nulls and duplicates, keeping order", () => {
    expect(activeOffsets({ alertMinutes: 10, secondAlertMinutes: 10 } as never)).toEqual([10]);
    expect(activeOffsets({ alertMinutes: null, secondAlertMinutes: 60 } as never)).toEqual([60]);
    expect(activeOffsets({ alertMinutes: 0, secondAlertMinutes: null } as never)).toEqual([0]);
  });
});

describe("lead labels", () => {
  it("picks the coarsest whole unit", () => {
    expect(leadLabel(5)).toBe("5 minutes");
    expect(leadLabel(60)).toBe("1 hour");
    expect(leadLabel(120)).toBe("2 hours");
    expect(leadLabel(1440)).toBe("1 day");
    expect(leadLabel(10080)).toBe("1 week");
  });
});

describe("payloads", () => {
  const labels = buildLabels({
    startAt: "2026-05-04T07:00:00.000+02:00",
    endAt: "2026-05-04T10:00:00.000+02:00",
    groups: [{ groupId: 162, groupName: "Grupp 1", location: "Domus" }]
  });

  it("renders a reminder with the lead time and the grace warning", () => {
    const payload = buildPayload(
      { kind: "reminder", startAt: "2026-05-04T07:00:00.000+02:00", endAt: "2026-05-04T10:00:00.000+02:00", groupIds: "162", offsetMinutes: 10 },
      labels,
      [162]
    ) as { aps: { alert: { title: string; body: string }; "interruption-level": string } };

    expect(payload.aps.alert.title).toBe("Laundry in 10 minutes");
    expect(payload.aps.alert.body).toContain("Mon 4 May 07:00–10:00");
    expect(payload.aps.alert.body).toContain("Grupp 1");
    expect(payload.aps.alert.body).toContain("15 minutes");
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
  });

  it("omits the grace warning on far-out alerts", () => {
    const payload = buildPayload(
      { kind: "reminder", startAt: "2026-05-04T07:00:00.000+02:00", endAt: "2026-05-04T10:00:00.000+02:00", groupIds: "162", offsetMinutes: 1440 },
      labels,
      [162]
    ) as { aps: { alert: { title: string; body: string } } };

    expect(payload.aps.alert.title).toBe("Laundry in 1 day");
    expect(payload.aps.alert.body).not.toContain("15 minutes");
  });

  it("regenerates the timeslot id rather than persisting one", () => {
    const payload = buildPayload(
      { kind: "new_booking", startAt: "2026-05-04T07:00:00.000+02:00", endAt: "2026-05-04T10:00:00.000+02:00", groupIds: "162", offsetMinutes: null },
      labels,
      [162]
    ) as { timeslotId: string; aps: Record<string, unknown> };

    expect(payload.timeslotId.startsWith("ts_")).toBe(true);
    expect(payload.aps["interruption-level"]).toBeUndefined();
  });
});

describe("polling", () => {
  it("schedules both alert offsets for a newly seen booking", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    store.upsertDevice({
      token: TOKEN_A,
      objectId: "obj",
      environment: "sandbox",
      enabled: true,
      alertMinutes: 10,
      secondAlertMinutes: 1440
    });
    // First poll establishes the baseline; the booking arrives on the second.
    const push = service({ store, responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10" })] });
    await push.pollObject("obj");

    const push2 = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await push2.pollObject("obj");

    const due = store.dueNotifications(2 ** 31);
    expect(due.filter((d) => d.kind === "reminder").map((d) => d.offsetMinutes).sort()).toEqual([10, 1440]);
  });

  it("does not announce bookings that already existed on the first poll", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 10, secondAlertMinutes: null
    });
    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await push.pollObject("obj");

    expect(store.dueNotifications(2 ** 31).some((d) => d.kind === "new_booking")).toBe(false);
  });

  it("announces a roommate's booking to every device except the one that made it", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    for (const token of [TOKEN_A, TOKEN_B]) {
      store.upsertDevice({
        token, objectId: "obj", environment: "sandbox", enabled: true,
        alertMinutes: 10, secondAlertMinutes: null
      });
    }
    const baseline = service({ store, responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10" })] });
    await baseline.pollObject("obj");

    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    push.onBooked("obj", slot.startAt, slot.endAt, [162], TOKEN_A);
    await push.pollObject("obj");

    const announcements = store.dueNotifications(2 ** 31).filter((d) => d.kind === "new_booking");
    expect(announcements.map((a) => a.token)).toEqual([TOKEN_B]);
  });

  it("leaves stored bookings alone when the upstream fetch fails", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 10, secondAlertMinutes: null
    });
    const ok = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await ok.pollObject("obj");
    expect(store.knownBookings("obj")).toHaveLength(1);

    const broken = service({
      store,
      responses: () => {
        throw new Error("upstream down");
      }
    });
    await broken.pollObject("obj");

    expect(store.knownBookings("obj")).toHaveLength(1);
    expect(store.dueNotifications(2 ** 31).length).toBeGreaterThan(0);
  });

  it("drops a booking and its pending reminders once it disappears", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 10, secondAlertMinutes: null
    });
    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await push.pollObject("obj");
    expect(store.dueNotifications(2 ** 31)).not.toHaveLength(0);

    const gone = service({ store, responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10" })] });
    await gone.pollObject("obj");

    expect(store.knownBookings("obj")).toHaveLength(0);
    expect(store.dueNotifications(2 ** 31)).toHaveLength(0);
  });

  it("rebuilds reminders when the alert offsets change", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 10, secondAlertMinutes: null
    });
    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await push.pollObject("obj");

    push.registerDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 60, secondAlertMinutes: null
    });

    const offsets = store.dueNotifications(2 ** 31).filter((d) => d.kind === "reminder").map((d) => d.offsetMinutes);
    expect(offsets).toEqual([60]);
  });

  it("skips alert offsets that already passed", async () => {
    const store = memoryStore();
    const start = new Date(Date.now() + 20 * 60 * 1000);
    const slot = { startAt: start.toISOString(), endAt: new Date(start.getTime() + 3 * 3600 * 1000).toISOString() };
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 10, secondAlertMinutes: 1440
    });
    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })]
    });
    await push.pollObject("obj");

    const offsets = store.dueNotifications(2 ** 31).filter((d) => d.kind === "reminder").map((d) => d.offsetMinutes);
    expect(offsets).toEqual([10]);
  });
});

describe("sending", () => {
  it("marks a delivered notification as sent so it never repeats", async () => {
    const store = memoryStore();
    const slot = futureSlot();
    const sent: unknown[] = [];
    store.upsertDevice({
      token: TOKEN_A, objectId: "obj", environment: "sandbox", enabled: true,
      alertMinutes: 0, secondAlertMinutes: null
    });
    const push = service({
      store,
      responses: [week({ fromDate: "2026-05-04", toDate: "2026-05-10", ...slot, ownGroups: [162] })],
      sent
    });
    await push.pollObject("obj");
    store.enqueue({
      token: TOKEN_A, kind: "reminder", objectId: "obj",
      startAt: slot.startAt, endAt: slot.endAt, groupIds: [162],
      labels: { machines: ["Grupp 1"], location: "Domus", dayLabel: "Mon 4 May", startTime: "07:00", endTime: "10:00" },
      offsetMinutes: 5, fireAt: 1
    });

    await push.sendDue();

    expect(sent).toHaveLength(1);
    expect(store.dueNotifications()).toHaveLength(0);
  });
});
