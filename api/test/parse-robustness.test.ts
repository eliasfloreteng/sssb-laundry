import { describe, expect, it } from "bun:test";
import { parseCategories, parseGroups } from "../src/aptus-client.js";

describe("robust parser patterns", () => {
  it("parses categories when LoadLocationGroupDialog includes extra args", () => {
    const html = `
      <button class="bookingNavigation" type="button"
        onclick="LoadLocationGroupDialog('35', '2026-04-29')">
        Laundry
      </button>
    `;

    const categories = parseCategories(html);
    expect(categories).toEqual([{ id: 35, name: "Laundry" }]);
  });

  it("parses booking groups when onclick includes query params", () => {
    const html = `
      <button class="bookingNavigation" type="button" aria-label="Grupp 1"
        onclick="document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=162&passDate=2026-05-03'">
        <table><tr><td></td><td>Jerum 21 Tvättstuga<br>Grupp 1</td></tr></table>
      </button>
    `;

    const groups = parseGroups(html);
    expect(groups).toEqual([{ id: 162, location: "Jerum 21 Tvättstuga", name: "Grupp 1" }]);
  });
});
