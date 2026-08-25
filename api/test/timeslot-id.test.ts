import { describe, expect, it } from "bun:test";
import { decodeTimeslotId, encodeTimeslotId } from "../src/timeslot-id.js";

describe("timeslot id", () => {
  it("round-trips start and end datetimes", () => {
    const id = encodeTimeslotId("2026-05-03T06:00:00.000+02:00", "2026-05-03T08:00:00.000+02:00");
    expect(decodeTimeslotId(id)).toEqual({
      startAt: "2026-05-03T06:00:00.000+02:00",
      endAt: "2026-05-03T08:00:00.000+02:00"
    });
  });

  it("rejects invalid id", () => {
    expect(() => decodeTimeslotId("bad")).toThrow("Invalid timeslot id");
  });
});
