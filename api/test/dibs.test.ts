import { describe, expect, it } from "bun:test";
import { DateTime } from "luxon";
import { Store } from "../src/db.js";
import { DibsService, DIBS_LIMIT, type DibsAptus } from "../src/dibs.js";
import { PushService, buildPayload } from "../src/notifications.js";
import { encodeTimeslotId } from "../src/timeslot-id.js";
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
    }
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
    const slots = [futureSlot(48), futureSlot(52), futureSlot(56)];
    let current = slots[0]!;
    const { dibs } = setup({ listing: () => week(current, "unavailable") });

    await dibs.call(ALICE, current.id, [162, 163], null);
    current = slots[1]!;
    await dibs.call(ALICE, current.id, [162], null);
    // A second group on a slot already waited on is not a new timeslot.
    await dibs.call(ALICE, current.id, [163], null);

    current = slots[2]!;
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

    const soon = buildPayload({ ...row, offsetMinutes: 5 }, labels, [162]) as { aps: { alert: Record<string, unknown> } };
    expect(soon.aps.alert["title-loc-key"]).toBe("notification.title.dibsWon");
    expect(soon.aps.alert["loc-key"]).toBe("notification.body.machines.activate");

    const later = buildPayload({ ...row, offsetMinutes: 600 }, labels, [162]) as { aps: { alert: Record<string, unknown> } };
    expect(later.aps.alert["loc-key"]).toBe("notification.body.machines");
  });
});
