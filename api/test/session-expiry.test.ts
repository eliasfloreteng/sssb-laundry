import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { AptusClient } from "../src/aptus-client.js";

const OBJECT_ID = "0000000000000";
const SALT = "4015";

// Minimal stand-in for the Aptus portal. The behaviour that matters here is the
// one the live portal shows once ASP.NET session state is dropped while the
// client still sends .ASPXAUTH: a 302 to /Account/LogOff rather than to
// /Account/Login.
function startFakePortal() {
  const liveSessions = new Set<string>();
  let loginCount = 0;
  let nextSessionId = 0;

  const loginPage = `<html><body><form action="/AptusPortal/Account/Login" method="post">
    <input name="__RequestVerificationToken" value="token" />
    <input name="PasswordSalt" value="${SALT}" />
    <input name="DeviceType" value="PC" />
    <input name="DesktopSelected" value="true" checked="checked" />
  </form></body></html>`;

  const categoriesPage = `<button class="bookingNavigation" onclick="LoadLocationGroupDialog('35')">Laundry</button>`;

  const groupsPage = `<button class="bookingNavigation" aria-label="Grupp 1"
    onclick="document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=162'">
    <table><tr><td></td><td>Jerum 21 Tvättstuga<br>Grupp 1</td></tr></table></button>`;

  const calendarPage = `<div class="dayColumn"><div class="weekDay" id="weekDay_0"></div>
    <div class="interval bookable"><div>06:00 - 08:00</div></div></div>`;

  const server = Bun.serve({
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      const cookies = request.headers.get("cookie") ?? "";
      const sessionId = /ASP\.NET_SessionId=([^;]+)/.exec(cookies)?.[1];
      const authenticated = cookies.includes(".ASPXAUTH=");

      if (url.pathname === "/AptusPortal/Account/Login") {
        if (request.method === "GET") {
          return new Response(loginPage, { headers: { "content-type": "text/html" } });
        }
        loginCount += 1;
        const id = `session-${nextSessionId++}`;
        liveSessions.add(id);
        const headers = new Headers({ location: "/AptusPortal/" });
        headers.append("set-cookie", `ASP.NET_SessionId=${id}; path=/`);
        headers.append("set-cookie", `.ASPXAUTH=ticket; path=/`);
        return new Response("", { status: 302, headers });
      }

      // Authenticated but session state gone -> LogOff, the same as upstream.
      if (authenticated && !(sessionId && liveSessions.has(sessionId))) {
        return new Response(
          `<html><head><title>Object moved</title></head><body>` +
            `<h2>Object moved to <a href="/AptusPortal/Account/LogOff">here</a>.</h2></body></html>`,
          { status: 302, headers: { location: "/AptusPortal/Account/LogOff" } }
        );
      }

      if (!authenticated) {
        return new Response("", {
          status: 302,
          headers: { location: `/AptusPortal/Account/Login?ReturnUrl=${encodeURIComponent(url.pathname)}` }
        });
      }

      if (url.pathname === "/AptusPortal/CustomerBooking/CustomerCategories") {
        return new Response(categoriesPage, { headers: { "content-type": "text/html" } });
      }
      if (url.pathname === "/AptusPortal/CustomerBooking/CustomerLocationGroups") {
        return new Response(groupsPage, { headers: { "content-type": "text/html" } });
      }
      if (url.pathname === "/AptusPortal/CustomerBooking/BookingCalendar") {
        return new Response(calendarPage, { headers: { "content-type": "text/html" } });
      }
      return new Response("", { status: 404 });
    }
  });

  return {
    server,
    baseUrl: `http://localhost:${server.port}`,
    dropSessionState: () => liveSessions.clear(),
    get loginCount() {
      return loginCount;
    }
  };
}

describe("Aptus session expiry", () => {
  let portal: ReturnType<typeof startFakePortal>;

  beforeAll(() => {
    portal = startFakePortal();
  });

  afterAll(() => {
    portal.server.stop(true);
  });

  it("reauthenticates when the portal redirects a cached session to LogOff", async () => {
    const client = new AptusClient({ baseUrl: portal.baseUrl });

    const first = await client.listTimeslots(OBJECT_ID, "2026-08-23");
    expect(first.groups).toHaveLength(1);
    expect(portal.loginCount).toBe(1);

    // The cached session keeps sending .ASPXAUTH after the portal forgets it.
    portal.dropSessionState();

    const second = await client.listTimeslots(OBJECT_ID, "2026-08-23");
    expect(second.groups).toHaveLength(1);
    expect(second.timeslots.length).toBeGreaterThan(0);
    expect(portal.loginCount).toBe(2);
  });
});
