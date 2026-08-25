import { existsSync, readFileSync } from "node:fs";
import { DateTime } from "luxon";
import { describe, expect, it } from "bun:test";
import {
  parseBookingCalendar,
  parseCategories,
  parseFeedbackDialog,
  parseGroups
} from "../src/aptus-client.js";

const hasFixtures =
  existsSync("requests/Categories.txt") &&
  existsSync("requests/Locations.txt") &&
  existsSync("requests/BookingCalendarAfterBooking.txt");

describe.skipIf(!hasFixtures)("parser fixtures", () => {
  it("parses first category", () => {
    const html = readFileSync("requests/Categories.txt", "utf8");
    const categories = parseCategories(html);
    expect(categories[0]).toEqual({ id: 35, name: "Laundry" });
  });

  it("parses groups from location dialog", () => {
    const html = readFileSync("requests/Locations.txt", "utf8");
    const groups = parseGroups(html);
    expect(groups.length).toBeGreaterThan(1);
    expect(groups[0]?.id).toBeTypeOf("number");
    expect(groups[0]?.location).toContain("Tvättstuga");
    expect(groups[0]?.name).toBe("Grupp 1");
  });

  it("parses own slot and cross-midnight slot", () => {
    const html = readFileSync("requests/BookingCalendarAfterBooking.txt", "utf8");
    const parsed = parseBookingCalendar(html, 162, "2026-05-03");

    const own = parsed.slots.find(
      (slot) => slot.localDate === "2026-05-03" && slot.startTime === "06:00" && slot.endTime === "08:00"
    );
    expect(own?.status).toBe("own");
    expect(own?.unbookUrl).toContain("/AptusPortal/CustomerBooking/Unbook/");

    const midnight = parsed.slots.find(
      (slot) => slot.localDate === "2026-05-03" && slot.startTime === "22:00" && slot.endTime === "00:00"
    );
    expect(midnight?.spansMidnight).toBe(true);
    const endDate = midnight ? DateTime.fromISO(midnight.endAt, { zone: "Europe/Stockholm" }).toISODate() : null;
    expect(endDate).toBe("2026-05-04");
  });

  it("parses feedback dialog", () => {
    const html = readFileSync("requests/BookingCalendarAfterBooking.txt", "utf8");
    const feedback = parseFeedbackDialog(html);
    expect(feedback).toContain("has been booked");
  });
});
