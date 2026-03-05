# SSSB AptusPortal Laundry Booking — API Endpoints

> Based on HAR capture; session on `https://sssb.aptustotal.se/AptusPortal/`
> Application: AptusPortal Styra 8.8.5 (ASP.NET MVC 5.2, IIS/10.0)

---

## Authentication

The application uses **ASP.NET Forms Authentication** — entirely cookie-based, no Bearer tokens.

| Cookie | Purpose |
|--------|---------|
| `ASP.NET_SessionId` | Server-side session identifier |
| `__RequestVerificationToken_L0FwdHVzUG9ydGFs0` | CSRF anti-forgery token (login form only) |
| `.ASPXAUTH` | Authentication ticket, set on successful login |

### `GET /AptusPortal/Account/Login`

Renders the login page. The HTML form contains a `PasswordSalt` hidden field (e.g. `197`) used for client-side password encoding via `/AptusPortal/Scripts/pwEnc.js`.

- **Response**: `200` — HTML login page

### `POST /AptusPortal/Account/Login`

Submits login credentials. On success, sets the `.ASPXAUTH` cookie and redirects.

- **Content-Type**: `application/x-www-form-urlencoded`
- **Form Fields**:
  | Field | Example | Description |
  |-------|---------|-------------|
  | `DeviceType` | `PC` | Client device type |
  | `DesktopSelected` | `true` | Desktop layout flag |
  | `__RequestVerificationToken` | `urMFziOq...` | Anti-forgery token from login page |
  | `UserName` | `XXXX-XXXX-XXX` | Apartment/user ID |
  | `Password` | `XXXX-XXXX-XXX` | Raw password |
  | `PwEnc` | `(encoded)` | Client-side encoded password |
  | `PasswordSalt` | `197` | Salt used for encoding |
- **Response**: `302` → `/AptusPortal/`
- **Set-Cookie**: `.ASPXAUTH=...`

---

## Main Pages

### `GET /AptusPortal/`

Portal home page. Navigation links: Hem (Home), Boka (Book), Installningar (Settings), Logga ut (Logout).

- **Response**: `200` — HTML

### `GET /AptusPortal/CustomerBooking`

Main booking page showing "Mina bokningar" (My bookings) with existing bookings and a "Ny bokning" (New booking) button.

- **Response**: `200` — HTML
- **Bookings shown as cards** with booking ID, time, date, group name, and an unbook button containing the booking ID and unbook URL.

---

## Booking Navigation (AJAX Endpoints)

These are called via `$.ajax` / jQuery `.load()` and require the `X-Requested-With: XMLHttpRequest` header.

### `GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerCategoryId`

Checks whether the user has access to one or multiple booking categories.

| Param | Type | Description |
|-------|------|-------------|
| `_` | query | Cache-buster timestamp |

- **Response**: `200` — JSON
  - Single category: `{"status":"OK","Payload":"{categoryId}"}`
  - Multiple: `{"status":"OK","Payload":"Multi"}`

### `GET /AptusPortal/CustomerBooking/CustomerCategories`

Returns an HTML fragment listing all booking categories available to the user.

- **Response**: `200` — HTML fragment
- **Example**: Button for "Tvatt" (Laundry) with `onclick="LoadLocationGroupDialog('35')"` → category ID **35**

### `GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerLocationGroupId`

Checks whether a category has one or multiple location groups.

| Param | Type | Description |
|-------|------|-------------|
| `categoryId` | query | Category ID (e.g. `35`) |
| `_` | query | Cache-buster timestamp |

- **Response**: `200` — JSON
  - Single group: `{"status":"OK","Payload":"{groupId}"}`
  - Multiple: `{"status":"OK","Payload":"Multi"}`

### `GET /AptusPortal/CustomerBooking/CustomerLocationGroups`

Returns an HTML fragment listing location groups for a category.

| Param | Type | Description |
|-------|------|-------------|
| `categoryId` | query | Category ID (e.g. `35`) |
| `passDate` | query | *(optional)* If provided, omits "First available" option and adds `overviewOffsetMonday` to group links |

- **Response**: `200` — HTML fragment
- **Options include**:
  - "Forsta lediga tid" (First available time) → links to `FirstAvailable`
  - "Grupp 1" → links to `BookingCalendarOverview?bookingGroupId=185`
  - "Grupp 2" → links to `BookingCalendarOverview?bookingGroupId=186`

---

## Booking Views

### `GET /AptusPortal/CustomerBooking/FirstAvailable`

Shows the first N available booking slots across all location groups.

| Param | Type | Description |
|-------|------|-------------|
| `categoryId` | query | Category ID (e.g. `35`) |
| `firstX` | query | Number of slots to show (e.g. `10`) |

- **Response**: `200` — HTML page
- Each slot links to `BookFirstAvailable` with `passNo`, `passDate`, `bookingGroupId`

### `GET /AptusPortal/CustomerBooking/BookingCalendarOverview`

Multi-week calendar overview for a specific location group showing which days have available slots.

| Param | Type | Description |
|-------|------|-------------|
| `bookingGroupId` | query | Location group ID (e.g. `185` or `186`) |
| `overviewOffsetMonday` | query | *(optional)* Monday date to offset the overview display |

- **Response**: `200` — HTML page
- Days with availability are colored and link to `BookingCalendar` with the corresponding week's Monday date

### `GET /AptusPortal/CustomerBooking/BookingCalendar`

Weekly calendar detail view showing all time slots for each day, with their availability status.

| Param | Type | Description |
|-------|------|-------------|
| `bookingGroupId` | query | Location group ID |
| `passDate` | query | The Monday of the week to display (e.g. `2026-03-02`) |

- **Response**: `200` — HTML page
- Available slots have buttons calling `DoBooking('/AptusPortal/CustomerBooking/Book?passNo=X&passDate=YYYY-MM-DD&bookingGroupId=N')`
- Week navigation via `passDate` for previous/next Monday

---

## Booking Actions

All booking/unbooking actions use **GET requests** and respond with **302 redirects**. The confirmation message is embedded as a `FeedbackDialog()` JS call in the redirected page.

### `GET /AptusPortal/CustomerBooking/BookFirstAvailable`

Books a time slot from the "First Available" view.

| Param | Type | Description |
|-------|------|-------------|
| `passNo` | query | Time slot index (0–9, see mapping below) |
| `passDate` | query | Date to book (e.g. `2026-03-06`) |
| `bookingGroupId` | query | Location group ID |

- **Response**: `302` → `/AptusPortal/CustomerBooking`
- **Confirmation** (on redirected page): `FeedbackDialog('Ditt valda pass fredag 6 mars 11:00-13:30 ar bokat.', 'INFORMATION', 'Stang')`

### `GET /AptusPortal/CustomerBooking/Book`

Books a time slot from the calendar view.

| Param | Type | Description |
|-------|------|-------------|
| `passNo` | query | Time slot index (0–9) |
| `passDate` | query | Date to book |
| `bookingGroupId` | query | Location group ID |

- **Response**: `302` → `/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId={id}&passDate={date}`
- **Confirmation**: Same `FeedbackDialog(...)` pattern

### `GET /AptusPortal/CustomerBooking/Unbook/{bookingId}`

Cancels/removes an existing booking.

| Param | Type | Description |
|-------|------|-------------|
| `{bookingId}` | path | The numeric booking ID (e.g. `NNNNNNN`) |

- **Response**: `302` → `/AptusPortal/CustomerBooking`
- **Confirmation**: `FeedbackDialog('Ditt pass har blivit avbokat.', 'INFORMATION', 'Stang')`

---

## Pass Number → Time Slot Mapping

| passNo | Time |
|--------|------|
| 0 | 02:00 – 04:00 |
| 1 | 04:00 – 06:00 |
| 2 | 06:00 – 08:30 |
| 3 | 08:30 – 11:00 |
| 4 | 11:00 – 13:30 |
| 5 | 13:30 – 16:00 |
| 6 | 16:00 – 18:30 |
| 7 | 18:30 – 21:00 |
| 8 | 21:00 – 23:30 |
| 9 | 23:30 – 02:00 |

---

## Known IDs from This Session

| Entity | Value |
|--------|-------|
| User/Apartment ID | `XXXX-XXXX-XXX` |
| Category "Tvatt" (Laundry) | `35` |
| Grupp 1 | `bookingGroupId=185` |
| Grupp 2 | `bookingGroupId=186` |

---

## Session Flow Summary

```
1. GET  /Account/Login                          → Login page
2. POST /Account/Login                          → Authenticate, get .ASPXAUTH cookie
3. GET  /                                       → Portal home
4. GET  /CustomerBooking                        → My bookings (empty)
5. GET  /CustomerBooking/JsonGetSingleCustomerCategoryId  → "Multi"
6. GET  /CustomerBooking/CustomerCategories      → [Tvatt (35)]
7. GET  /CustomerBooking/JsonGetSingleCustomerLocationGroupId?categoryId=35 → "Multi"
8. GET  /CustomerBooking/CustomerLocationGroups?categoryId=35 → [First available, Grupp 1, Grupp 2]
9. GET  /CustomerBooking/FirstAvailable?categoryId=35&firstX=10 → 10 available slots
10. GET /CustomerBooking/BookFirstAvailable?passNo=4&passDate=2026-03-06&bookingGroupId=186 → 302 (booked)
11. GET /CustomerBooking                        → Shows booking NNNNNNN
12. GET /CustomerBooking/Unbook/NNNNNNN          → 302 (cancelled)
13. GET /CustomerBooking                        → Empty again
14–17. (Repeat category/group selection flow)
18. GET /CustomerBooking/BookingCalendarOverview?bookingGroupId=185 → Calendar overview
19. GET /CustomerBooking/BookingCalendar?bookingGroupId=185&passDate=2026-03-02 → Weekly view
20. GET /CustomerBooking/Book?passNo=6&passDate=2026-03-07&bookingGroupId=185 → 302 (booked)
21. GET /CustomerBooking/BookingCalendar?...     → Confirmation
22–23. (Switch to Grupp 2)
24. GET /CustomerBooking/BookingCalendarOverview?bookingGroupId=186 → Calendar overview
25. GET /CustomerBooking/BookingCalendar?bookingGroupId=186&passDate=2026-03-02 → Weekly view
26. GET /CustomerBooking/Book?passNo=6&passDate=2026-03-07&bookingGroupId=186 → 302 (booked)
27. GET /CustomerBooking/BookingCalendar?...     → Confirmation
28. GET /CustomerBooking                        → Shows bookings NNNNNNN + NNNNNNN
```

---

## Architectural Notes

- **All booking/unbooking actions use GET** — no POST/PUT/DELETE for state-changing operations.
- **Server-rendered MVC** — not a REST API. Booking actions return 302 redirects; confirmations are embedded in the HTML of the redirected page via `FeedbackDialog()` JS calls.
- **AJAX is only used for the category/group selection dialogs** — jQuery `.load()` for HTML fragments and `$.ajax` for the JSON "single or multi" checks.
- **Booking IDs are sequential integers** (e.g. `NNNNNNN`).
- **Two booking endpoints exist**: `BookFirstAvailable` (from "First Available" list, redirects to main page) and `Book` (from calendar view, redirects back to the calendar).
