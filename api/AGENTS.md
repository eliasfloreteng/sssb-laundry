# sssb-laundry-api

Always use Bun.

This is a minimal structued HTTP API for booking laundry sessions at SSSB that wraps their Aptus Portal laundry booking service.

Find example requests in the `./requests` directory. This directory is gitignored as it contains sensitive authentication details

# Requirements

- Timeslots are the canonical entities.
- Available actions: viewing timeslots, booking a timeslot, cancelling a booking.
- Data (for example dates and times) extracted should be parsed and structured (not simply strings).
- Authentication should consist of only supplying the object id to each request as a header, the underlying sessions should be reused and reauthenticated if expired.
- The categories should be completely transparent (does not need to be supplied) as most cases it has only one called something like "Laundry" or "Tvätt".
- Do not draw assumptions or hard-code unknown details. Rather ask or interview if unsure.
- Use a DOM/HTML parser for extracting structured information from the responses and use only RegEx if more appropriate.
- Multiple groups (up to two) should be able to be booked for a timeslot with a single request.
- If the booking for one group fails, a partial success should be returned with the successful and failed bookings.
- Errors should also be returned in a structured format with handling of unknown errors.
- Focus on brevity and being concise in the implementation.
- The application should be stateless except for saving the sessions in memory.
- The list of timeslots should be able to return a cursor (date) for the next week of timeslots.
- Cancellations should support multiple groups. Same partial success/failure handling as for bookings.
- For the password encoding implement the same logic as the upstream application.
- Do not include any object ids in the repository as they are considered sensitive.

# Notes about Aptus API

## Invariants

- Only one timeslot can be booked at a time but for up to two groups for that same timeslot.
- Times that are not activated (by going into the laundry room) within 15 minutes of start are automatically cancelled and available for anyone to book again.
- Number of locations (groups) can vary, some object ids (logins/locations) only have two groups and some have up to nine or more (for different buildings).
- The timeslots structure/times vary between object ids (logins/locations).
- Timeslots can span across midnight.

## Technical details

> The upstream (`https://sssb.aptustotal.se/AptusPortal/`) is an ASP.NET MVC HTML app with short session lifetimes, XOR-encoded client-side passwords, and a location-specific set of "laundry groups".

- Multiple requests to the underlying Aptus API may be needed to fullfil a single client request.
- The object id is both username and password for login.
- All responses return HTML.
- All times are in Europe/Stockholm (dates from the portal are without timezone). Be aware of DST.
- Anti-forgery is only enforced on `POST /Account/Login`; other endpoints are plain GETs.
- `__RequestVerificationToken` cookie and form value must come from the same GET; do not mix them across requests.
- The server responds with **empty body** to requests without a `User-Agent`. Always set one.
- Some endpoints redirect to `/Account/Error` when they receive `X-Requested-With: XMLHttpRequest` without a matching `Referer`.
- All cookies `ASP.NET_SessionId`, `__RequestVerificationToken_L0FwdHVzUG9ydGFs0` and `.ASPXAUTH` need to be sent on subsequent requests.
- The `passDate` param at `/AptusPortal/CustomerBooking/BookingCalendar` dictates which week of timesslots to show. It is usually the monday of that week but any date from that week works.
