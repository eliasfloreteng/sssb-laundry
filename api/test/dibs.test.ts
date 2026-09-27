import { describe, expect, it } from "bun:test";
import { DateTime } from "luxon";
import { Store } from "../src/db.js";
import { DibsService, DIBS_LIMIT, type DibsAptus } from "../src/dibs.js";
import { PUSH_VERSION, PushService, buildPayload } from "../src/notifications.js";
import { decodeTimeslotId, encodeTimeslotId } from "../src/timeslot-id.js";
import type { AppError } from "../src/errors.js";
import type { ApnsClient } from "../src/apns.js";
import type { ActionResponse, GroupSlotStatus, TimeslotsResponse } from "../src/types.js";

const ALICE = "1111-1111-111";
const BOB = "2222-2222-222";
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

/** A slot two days out, so it has neither started nor reached its grace window. */
function futureSlot(hoursAhead = 48): { startAt: string; endAt: string; id: string } {
  const start = DateTime.now().setZone("Europe/Stockholm").plus({ hours: hoursAhead }).startOf("hour");
  const startAt = start.toISO()!;
  const endAt = start.plus({ hours: 2, minutes: 30 }).toISO()!;
  return { startAt, endAt, id: encodeTimeslotId(startAt, endAt) };
}

function week(slot: { startAt: string; endAt: string }, status: GroupSlotStatus): TimeslotsResponse {
  return {
    week: { fromDate: "2026-01-01", toDate: "2026-01-07", timezone: "Europe/Stockholm" },
    groups: [
      { id: 162, location: "Domus", name: "Grupp 1" },
      { id: 163, location: "Domus", name: "Grupp 2" }
    ],
    timeslots: [
      {
        id: encodeTimeslotId(slot.startAt, slot.endAt),
        startAt: slot.startAt,
        endAt: slot.endAt,
        localDate: slot.startAt.slice(0, 10),
        startTime: "10:00",
        endTime: "12:30",
        spansMidnight: false,
        groups: [162, 163].map((groupId) => ({
          groupId,
          status,
          canBook: status === "bookable",
          canCancel: status === "own"
        }))
      }
    ]
  };
}

function setup(args: {
  listing: () => TimeslotsResponse;
  book?: (objectId: string) => string;
}) {
  const store = new Store(":memory:");
  const booked: string[] = [];
  const sent: { payload: { kind: string } }[] = [];

  const aptus: DibsAptus = {
    listTimeslots: async () => args.listing(),
    bookTimeslot: async (objectId, timeslotId, groupIds): Promise<ActionResponse> => {
      booked.push(objectId);
      const status = args.book?.(objectId) ?? "booked";
      return {
        timeslotId,
        results: groupIds.map((groupId) => ({ groupId, status })),
        overallStatus: status === "booked" ? "success" : "failed"
      };
    },
    cancelTimeslot: async (_objectId, timeslotId, groupIds): Promise<ActionResponse> => ({
      timeslotId,
      results: groupIds.map((groupId) => ({ groupId, status: "cancelled" })),
      overallStatus: "success"
    })
  };
  const apns = {
    send: async (request: { payload: { kind: string } }) => {
      sent.push(request);
      return { kind: "sent" as const };
    },
    close: () => {}
  } as unknown as ApnsClient;

  const push = new PushService({
    store,
    aptus: { listTimeslots: async () => args.listing() } as never,
    apns,
    pollWeeks: 1
  });
  const dibs = new DibsService({ store, aptus, push });

  for (const [token, objectId] of [
    [TOKEN_A, ALICE],
    [TOKEN_B, BOB]
  ] as const) {
    store.upsertDevice({
      token,
      objectId,
      environment: "sandbox",
      enabled: true,
      alertMinutes: null,
      secondAlertMinutes: null
    });
  }
  return { store, dibs, push, booked, sent };
}

async function settle(): Promise<void> {
  for (let i = 0; i < 5; i += 1) await new Promise((r) => setTimeout(r, 5));
}

describe("calling dibs", () => {
  it("queues on a taken slot and reports the place in line", async () => {
    const slot = futureSlot();
    const { dibs } = setup({ listing: () => week(slot, "unavailable") });

    await dibs.call(ALICE, slot.id, [162], null);
    await dibs.call(BOB, slot.id, [162], null);

    const annotated = dibs.annotate(BOB, week(slot, "unavailable"));
    const group = annotated.timeslots[0]!.groups.find((g) => g.groupId === 162)!;
    expect(group.dibs).toBe(true);
    expect(group.dibsQueue).toBe(2);
    expect(annotated.timeslots[0]!.groups.find((g) => g.groupId === 163)!.dibs).toBeUndefined();
  });

  it("refuses a free slot", async () => {
    const slot = futureSlot();
    const { dibs } = setup({ listing: () => week(slot, "bookable") });
    const error = await dibs.call(ALICE, slot.id, [162], null).catch((e: AppError) => e);
    expect((error as AppError).code).toBe("NOT_TAKEN");
  });

  it("refuses a started slot", async () => {
    const slot = futureSlot(-1);
    const { dibs } = setup({ listing: () => week(slot, "unavailable") });
    const error = await dibs.call(ALICE, slot.id, [162], null).catch((e: AppError) => e);
    expect((error as AppError).code).toBe("TOO_LATE");
  });

  it(`holds at most ${DIBS_LIMIT} timeslots, counting both groups of one as one`, async () => {
    const slots = Array.from({ length: DIBS_LIMIT + 1 }, (_, i) => futureSlot(48 + 4 * i));
    let current = slots[0]!;
    const { dibs } = setup({ listing: () => week(current, "unavailable") });

    await dibs.call(ALICE, current.id, [162, 163], null);
    for (const slot of slots.slice(1, DIBS_LIMIT)) {
      current = slot;
      await dibs.call(ALICE, current.id, [162], null);
    }
    // A second group on a slot already waited on is not a new timeslot.
    await dibs.call(ALICE, current.id, [163], null);

    current = slots[DIBS_LIMIT]!;
    const error = await dibs.call(ALICE, current.id, [162], null).catch((e: AppError) => e);
    expect((error as AppError).code).toBe("DIBS_LIMIT");
  });
});

describe("claiming", () => {
  it("books for the first in line and clears the queue", async () => {
    const slot = futureSlot();
    let status: GroupSlotStatus = "unavailable";
    const { dibs, store, booked, sent } = setup({
      listing: () => week(slot, status),
      // What Aptus shows the winner afterwards, and what the push poll reads.
      book: () => {
        status = "own";
        return "booked";
      }
    });

    await dibs.call(ALICE, slot.id, [162], null);
    await dibs.call(BOB, slot.id, [162], null);

    status = "bookable";
    await dibs.sweep("ahead");
    await settle();

    expect(booked).toEqual([ALICE]);
    expect(store.openDibs()).toHaveLength(0);
    expect(store.knownBookings(ALICE).map((b) => b.groupId)).toContain(162);
    const won = sent.filter((s) => s.payload.kind === "dibs_won");
    expect(won).toHaveLength(1);
    // Announced by the dibs alert, never again as a "new booking".
    expect(sent.some((s) => s.payload.kind === "new_booking")).toBe(false);
  });

  it("passes over someone Aptus refuses and books the next", async () => {
    const slot = futureSlot();
    let status: GroupSlotStatus = "unavailable";
    const { dibs, store, booked } = setup({
      listing: () => week(slot, status),
      book: (objectId) => (objectId === ALICE ? "not_bookable" : "booked")
    });

    await dibs.call(ALICE, slot.id, [162], null);
    await dibs.call(BOB, slot.id, [162], null);

    status = "bookable";
    await dibs.sweep("ahead");

    expect(booked).toEqual([ALICE, BOB]);
    expect(store.openDibs()).toHaveLength(0);
  });

  it("keeps everyone in line when nobody gets it", async () => {
    const slot = futureSlot();
    let status: GroupSlotStatus = "unavailable";
    const { dibs, store } = setup({ listing: () => week(slot, status), book: () => "not_bookable" });

    await dibs.call(ALICE, slot.id, [162], null);
    status = "bookable";
    await dibs.sweep("ahead");

    expect(store.openDibs()).toHaveLength(1);
  });

  it("leaves a still-taken slot alone", async () => {
    const slot = futureSlot();
    const { dibs, booked } = setup({ listing: () => week(slot, "unavailable") });
    await dibs.call(ALICE, slot.id, [162], null);
    await dibs.sweep("ahead");
    expect(booked).toHaveLength(0);
  });

  it("claims straight away when a holder cancels through the app", async () => {
    const slot = futureSlot();
    const { dibs, booked } = setup({ listing: () => week(slot, "unavailable") });
    await dibs.call(BOB, slot.id, [163], null);

    dibs.onReleased(slot.startAt, slot.endAt, [162, 163]);
    await settle();

    expect(booked).toEqual([BOB]);
  });

  it("drops a dibs once its grace window has closed, without a push", async () => {
    const slot = futureSlot();
    const { dibs, store, sent } = setup({ listing: () => week(slot, "unavailable") });
    await dibs.call(ALICE, slot.id, [162], null);

    // Rewrite the stored start to half an hour ago.
    const past = DateTime.now().minus({ minutes: 30 }).toISO()!;
    store.deleteDibs(ALICE, slot.startAt, 162);
    store.insertDibs({ objectId: ALICE, startAt: past, endAt: slot.endAt, groupId: 162, originToken: null });

    await dibs.sweep("grace");
    expect(store.openDibs()).toHaveLength(0);
    expect(sent).toHaveLength(0);
  });
});

describe("dibs_won payload", () => {
  it("uses its own title and warns about activation when it is close", () => {
    const labels = { machines: ["Grupp 1"], location: "Domus", dayLabel: "Thu 24 Sep", startTime: "10:00", endTime: "12:30" };
    const row = { kind: "dibs_won" as const, startAt: "2026-09-24T10:00:00.000+02:00", endAt: "2026-09-24T12:30:00.000+02:00", groupIds: "162" };

    const soon = buildPayload({ ...row, offsetMinutes: 5 }, labels, [162], PUSH_VERSION) as { aps: { alert: Record<string, unknown> } };
    expect(soon.aps.alert["title-loc-key"]).toBe("notification.title.dibsWon");
    expect(soon.aps.alert["loc-key"]).toBe("notification.body.machines.activate");

    const later = buildPayload({ ...row, offsetMinutes: 600 }, labels, [162], PUSH_VERSION) as { aps: { alert: Record<string, unknown> } };
    expect(later.aps.alert["loc-key"]).toBe("notification.body.machines");
  });

  it("falls back to a title every build knows for a device that never said which it knows", () => {
    const labels = { machines: ["Grupp 1"], location: "Domus", dayLabel: "Thu 24 Sep", startTime: "10:00", endTime: "12:30" };
    const row = { kind: "dibs_won" as const, startAt: "2026-09-24T10:00:00.000+02:00", endAt: "2026-09-24T12:30:00.000+02:00", groupIds: "162", offsetMinutes: 600 };
    type Alert = { aps: { alert: Record<string, unknown> } };

    const legacy = buildPayload(row, labels, [162]) as Alert;
    expect(legacy.aps.alert["title-loc-key"]).toBe("notification.title.newBooking");
    const swapped = buildPayload(row, { ...labels, replaced: "Fri 25 Sep 10:00" }, [162]) as Alert;
    expect(swapped.aps.alert["title-loc-key"]).toBe("notification.title.newBooking");
    expect(swapped.aps.alert["title-loc-args"]).toBeUndefined();

    const current = buildPayload(row, { ...labels, replaced: "Fri 25 Sep 10:00" }, [162], PUSH_VERSION) as Alert;
    expect(current.aps.alert["title-loc-key"]).toBe("notification.title.dibsSwapped");
    expect(current.aps.alert["title-loc-args"]).toEqual(["Fri 25 Sep 10:00"]);
  });
});

/**
 * A tiny Aptus: who holds which group of which slot, with a one-session limit
 * per object id, and every listing drawn from the viewer's side of it.
 */
function world(slots: { startAt: string; endAt: string }[]) {
  const holders = new Map<string, string>();
  const key = (startAt: string, groupId: number) => `${startAt}#${groupId}`;
  const sessions = (objectId: string) =>
    new Set([...holders].filter(([, holder]) => holder === objectId).map(([k]) => k.split("#")[0])).size;
  const calls: string[] = [];

  const listing = (viewer: string): TimeslotsResponse => ({
    ...week(slots[0]!, "bookable"),
    timeslots: slots.map((slot) => ({
      ...week(slot, "bookable").timeslots[0]!,
      groups: [162, 163].map((groupId) => {
        const holder = holders.get(key(slot.startAt, groupId));
        const status: GroupSlotStatus = !holder ? "bookable" : holder === viewer ? "own" : "unavailable";
        return { groupId, status, canBook: status === "bookable" && sessions(viewer) < 1, canCancel: status === "own" };
      })
    }))
  });

  const aptus: DibsAptus = {
    listTimeslots: async (objectId) => listing(objectId),
    bookTimeslot: async (objectId, timeslotId, groupIds) => {
      const { startAt } = decodeTimeslotId(timeslotId);
      calls.push(`book ${objectId} ${startAt}`);
      const results = groupIds.map((groupId) => {
        const holder = holders.get(key(startAt, groupId));
        if (holder === objectId) return { groupId, status: "already_booked" };
        const inSlot = [...holders].some(([k, h]) => h === objectId && k.startsWith(`${startAt}#`));
        if (holder || (!inSlot && sessions(objectId) >= 1)) return { groupId, status: "not_bookable" };
        holders.set(key(startAt, groupId), objectId);
        return { groupId, status: "booked" };
      });
      return { timeslotId, results, overallStatus: "success" };
    },
    cancelTimeslot: async (objectId, timeslotId, groupIds) => {
      const { startAt } = decodeTimeslotId(timeslotId);
      calls.push(`cancel ${objectId} ${startAt}`);
      const results = groupIds.map((groupId) => {
        if (holders.get(key(startAt, groupId)) !== objectId) return { groupId, status: "not_booked" };
        holders.delete(key(startAt, groupId));
        return { groupId, status: "cancelled" };
      });
      return { timeslotId, results, overallStatus: "success" };
    }
  };

  const store = new Store(":memory:");
  const sent: { payload: { kind: string; aps?: { alert?: Record<string, unknown> } } }[] = [];
  const apns = {
    send: async (request: (typeof sent)[number]) => {
      sent.push(request);
      return { kind: "sent" as const };
    },
    close: () => {}
  } as unknown as ApnsClient;
  const push = new PushService({ store, aptus: aptus as never, apns, pollWeeks: 1 });
  const dibs = new DibsService({ store, aptus, push });
  store.upsertDevice({
    token: TOKEN_A,
    objectId: ALICE,
    environment: "sandbox",
    enabled: true,
    alertMinutes: null,
    secondAlertMinutes: null,
    pushVersion: PUSH_VERSION
  });

  const hold = (objectId: string, startAt: string, groupId = 162) => holders.set(key(startAt, groupId), objectId);
  const holder = (startAt: string, groupId = 162) => holders.get(key(startAt, groupId));
  const free = (startAt: string, groupId = 162) => holders.delete(key(startAt, groupId));
  return { store, dibs, sent, calls, hold, holder, free };
}

describe("order of preference", () => {
  const wanted = futureSlot(48);
  const booked = futureSlot(72);

  it("ranks a new dibs last and marks the order on the listing", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);

    await w.dibs.call(ALICE, wanted.id, [162], null);
    let annotated = w.dibs.annotate(ALICE, week(wanted, "unavailable"));
    expect(annotated.timeslots[0]!.priority).toBe(1);

    w.dibs.setPriority(ALICE, [booked.id, wanted.id]);
    annotated = w.dibs.annotate(ALICE, week(wanted, "unavailable"));
    expect(annotated.timeslots[0]!.priority).toBe(2);
  });

  it("gives up a booking ranked below the dibs to make room for it", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);

    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.dibs.setPriority(ALICE, [wanted.id, booked.id]);

    w.free(wanted.startAt);
    await w.dibs.sweep("ahead");
    await settle();

    expect(w.holder(wanted.startAt)).toBe(ALICE);
    expect(w.holder(booked.startAt)).toBeUndefined();
    expect(w.store.openDibs()).toHaveLength(0);
    // The one given up has no rank left; the one won keeps its own.
    expect(w.store.priorityForObject(ALICE).map((p) => p.startAt)).toEqual([wanted.startAt]);
    const won = w.sent.find((s) => s.payload.kind === "dibs_won");
    expect(won?.payload.aps?.alert?.["title-loc-key"]).toBe("notification.title.dibsSwapped");
  });

  it("hands the booking it gave up to whoever is in line for it", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);

    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.dibs.setPriority(ALICE, [wanted.id, booked.id]);
    // Bob holds nothing else once his slot is gone, so he has room for it.
    w.store.insertDibs({ objectId: BOB, startAt: booked.startAt, endAt: booked.endAt, groupId: 162, originToken: null });

    w.free(wanted.startAt);
    await w.dibs.sweep("ahead");
    await settle();

    expect(w.holder(wanted.startAt)).toBe(ALICE);
    expect(w.holder(booked.startAt)).toBe(BOB);
  });

  it("never gives up a booking ranked above the dibs", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);

    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.dibs.setPriority(ALICE, [booked.id, wanted.id]);

    w.free(wanted.startAt);
    await w.dibs.sweep("ahead");

    expect(w.holder(booked.startAt)).toBe(ALICE);
    expect(w.holder(wanted.startAt)).toBeUndefined();
    expect(w.calls.some((c) => c.startsWith("cancel"))).toBe(false);
    expect(w.store.openDibs()).toHaveLength(1);
  });

  it("never gives up a booking left out of the order", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);

    // Called, so ranked — but the booking was never ranked at all.
    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.free(wanted.startAt);
    await w.dibs.sweep("ahead");

    expect(w.holder(booked.startAt)).toBe(ALICE);
    expect(w.calls.some((c) => c.startsWith("cancel"))).toBe(false);
  });

  it("puts the booking back when the dibs still cannot be booked", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    w.hold(ALICE, booked.startAt);
    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.dibs.setPriority(ALICE, [wanted.id, booked.id]);
    w.free(wanted.startAt);

    // Somebody else books it in the moment between Alice's cancel and her
    // second try, so Aptus refuses her both times.
    const record = w.calls.push.bind(w.calls);
    w.calls.push = (entry: string) => {
      if (entry.startsWith("cancel")) w.hold("3333-3333-333", wanted.startAt);
      return record(entry);
    };
    await w.dibs.sweep("ahead");

    expect(w.holder(booked.startAt)).toBe(ALICE);
    expect(w.store.openDibs()).toHaveLength(1);
    expect(w.store.priorityForObject(ALICE)).toHaveLength(2);
  });

  it("drops every dibs and the order at once", async () => {
    const w = world([wanted, booked]);
    w.hold(BOB, wanted.startAt);
    await w.dibs.call(ALICE, wanted.id, [162], null);
    w.dibs.setPriority(ALICE, [wanted.id, booked.id]);

    w.dibs.dropAll(ALICE);
    expect(w.store.dibsForObject(ALICE)).toHaveLength(0);
    expect(w.store.priorityForObject(ALICE)).toHaveLength(0);
  });
});

describe("a dibs right after the user's own booking", () => {
  const first = futureSlot(48);
  const next = futureSlot(51);

  it("is booked on a later sweep, once the first booking stops counting", async () => {
    const w = world([first, next]);
    w.hold(ALICE, first.startAt);
    w.hold(BOB, next.startAt);
    await w.dibs.call(ALICE, next.id, [162], null);

    // Bob lets it go while Alice is still at her limit: refused, kept in line.
    w.free(next.startAt);
    await w.dibs.sweep("ahead");
    expect(w.holder(next.startAt)).toBeUndefined();
    expect(w.store.openDibs()).toHaveLength(1);

    // Her first session starts, which frees the quota — modelled as it leaving her count.
    w.free(first.startAt);
    await w.dibs.sweep("ahead");
    expect(w.holder(next.startAt)).toBe(ALICE);
  });

  it("can be called on a free slot past the user's limit, and books it once the limit frees", async () => {
    const w = world([first, next]);
    w.hold(ALICE, first.startAt);
    await w.dibs.call(ALICE, next.id, [162], null);

    await w.dibs.sweep("ahead");
    expect(w.holder(next.startAt)).toBeUndefined();
    expect(w.store.openDibs()).toHaveLength(1);

    w.free(first.startAt);
    await w.dibs.sweep("ahead");
    expect(w.holder(next.startAt)).toBe(ALICE);
  });

  it("still refuses a free slot the user could book right now", async () => {
    const w = world([first, next]);
    const error = await w.dibs.call(ALICE, next.id, [162], null).catch((e: AppError) => e);
    expect((error as AppError).code).toBe("NOT_TAKEN");
  });

  it("swaps a free slot ranked above a booking in at once", async () => {
    const w = world([first, next]);
    w.hold(ALICE, first.startAt);
    await w.dibs.call(ALICE, next.id, [162], null);
    w.dibs.setPriority(ALICE, [next.id, first.id]);

    await w.dibs.sweep("ahead");
    await settle();
    expect(w.holder(next.startAt)).toBe(ALICE);
    expect(w.holder(first.startAt)).toBeUndefined();
  });

  it("tries a swap that falls through only once, until the order changes", async () => {
    const w = world([first, next]);
    w.hold(ALICE, first.startAt);
    await w.dibs.call(ALICE, next.id, [162], null);
    w.dibs.setPriority(ALICE, [next.id, first.id]);

    // Something besides the limit refuses her: somebody books it the moment
    // her booking is cancelled.
    const record = w.calls.push.bind(w.calls);
    let intercept = true;
    w.calls.push = (entry: string) => {
      if (intercept && entry.startsWith("cancel")) {
        w.hold("3333-3333-333", next.startAt);
        intercept = false;
      }
      return record(entry);
    };
    await w.dibs.sweep("ahead");
    expect(w.holder(first.startAt)).toBe(ALICE);

    w.free(next.startAt);
    await w.dibs.sweep("ahead");
    await w.dibs.sweep("ahead");
    expect(w.calls.filter((c) => c.startsWith("cancel"))).toHaveLength(1);
    expect(w.holder(first.startAt)).toBe(ALICE);

    w.dibs.setPriority(ALICE, [next.id, first.id]);
    await w.dibs.sweep("ahead");
    await settle();
    expect(w.holder(next.startAt)).toBe(ALICE);
  });
});
