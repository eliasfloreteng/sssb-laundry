# SSSB AptusPortal Laundry Booking — API Endpoints

> Based on HAR capture; session on `https://sssb.aptustotal.se/AptusPortal/`
> Application: AptusPortal Styra 8.8.5 (ASP.NET MVC 5.2, IIS/10.0)

---

## Common Response Headers

All responses include these headers:

```
cache-control: no-cache, no-store, must-revalidate
pragma: no-cache
expires: -1
server: Microsoft-IIS/10.0
x-aspnetmvc-version: 5.2
x-aspnet-version: 4.0.30319
x-powered-by: ASP.NET
x-frame-options: SAMEORIGIN
```

---

## Authentication

The application uses **ASP.NET Forms Authentication** — entirely cookie-based, no Bearer tokens.

| Cookie | Purpose |
|--------|---------|
| `ASP.NET_SessionId` | Server-side session identifier |
| `__RequestVerificationToken_L0FwdHVzUG9ydGFs0` | CSRF anti-forgery token (login form only) |
| `.ASPXAUTH` | Authentication ticket, set on successful login |

The `.ASPXAUTH` cookie attributes: `path=/; HttpOnly; SameSite=Lax` (no `Secure` flag, no explicit expiry — session cookie).

When the session expires or `.ASPXAUTH` is missing/invalid, all page requests return a **302 redirect** to `/AptusPortal/Account/Login`.

### `GET /AptusPortal/Account/Login`

Renders the login page. The HTML form contains a `PasswordSalt` hidden field (e.g. `197`) used for client-side password encoding via `/AptusPortal/Scripts/pwEnc.js`.

- **Response**: `200` — HTML login page

**Example response body** (key elements extracted from HTML):

```html
<form action="/AptusPortal/Account/Login" method="post">
  <input id="DeviceType" name="DeviceType" type="hidden" value="PC" />
  <input name="__RequestVerificationToken" type="hidden"
         value="urMFziOq...fcQ1" />
  <input id="UserName" name="UserName" placeholder="Användarnamn/E-post" type="text" />
  <input id="Password" name="Password" placeholder="Lösenord" type="password" />
  <input id="PwEnc" name="PwEnc" type="hidden" value="" />
  <input id="PasswordSalt" name="PasswordSalt" type="hidden" value="197" />
  <button id="btnLogin" type="submit">Logga in</button>
</form>
```

The login page also contains language switch links:
- `/AptusPortal/Account/SetCustomerLanguage?lang=sv-SE&returnController=Account&returnAction=Login` (Svenska)
- `/AptusPortal/Account/SetCustomerLanguage?lang=en-GB&returnController=Account&returnAction=Login` (English)

And a password reset link:
- `/AptusPortal/Account/ResetPassword`

**Client-side password encoding** (from `btnLogin` click handler):
```js
encodedPW = enc_str($("#Password").val().trim(), $("#PasswordSalt").val().trim());
$("#PwEnc").val(encodedPW);
```

### `POST /AptusPortal/Account/Login`

Submits login credentials. On success, sets the `.ASPXAUTH` cookie and redirects.

- **Content-Type**: `application/x-www-form-urlencoded`
- **Form Fields**:
  | Field | Example | Description |
  |-------|---------|-------------|
  | `DeviceType` | `PC` | Client device type |
  | `DesktopSelected` | `true` | Desktop layout flag (radio: `true`=Dator, `false`=Mobil) |
  | `__RequestVerificationToken` | `urMFziOq...` | Anti-forgery token from login page |
  | `UserName` | *(user ID)* | Apartment/user ID |
  | `Password` | *(raw password)* | Raw password |
  | `PwEnc` | `(encoded)` | Client-side encoded password (URL-encoded bytes) |
  | `PasswordSalt` | `197` | Salt used for encoding |

**Example request body:**

```
DeviceType=PC&DesktopSelected=true&__RequestVerificationToken=urMFziOq...fcQ1&UserName=XXXX-XXXX-XXX&Password=XXXX-XXXX-XXX&PwEnc=%C3%B4%C3%B0...&PasswordSalt=197
```

**Example response:**

```
HTTP/2 302
location: /AptusPortal/
set-cookie: .ASPXAUTH=75CBDFBB...CD4830; path=/; HttpOnly; SameSite=Lax
content-length: 130
```

- **Response**: `302` → `/AptusPortal/`
- **Set-Cookie**: `.ASPXAUTH=...`

### `GET /AptusPortal/Account/LogOff`

Logs the user out. Referenced in the navigation menu on all authenticated pages.

### `GET /AptusPortal/Account/SetCustomerLanguage`

Switches the UI language.

| Param | Type | Description |
|-------|------|-------------|
| `lang` | query | Language code: `sv-SE` or `en-GB` |
| `returnController` | query | Controller to redirect back to (e.g. `Account`) |
| `returnAction` | query | Action to redirect back to (e.g. `Login`) |

### `GET /AptusPortal/Account/ResetPassword`

Renders the password reset page.

---

## Main Pages

### `GET /AptusPortal/`

Portal home page. Navigation links: Hem (Home), Boka (Book), Installningar (Settings), Logga ut (Logout).

- **Response**: `200` — HTML

**Example response body** (key content):

```html
<h1 class="startPageHeader">Aptusportal</h1>
<p class="startPageBody">Kul att du använder Aptusportal Styra. </p>
<div id="divMessages" class="homepageSection">
    <!-- Messages loaded via AJAX -->
</div>
<div id="divArticles" class="homepageSection">
    <!-- Articles loaded via AJAX -->
</div>
```

The home page loads messages via:
```js
$.ajax({
    type: "GET",
    url: '/AptusPortal/Home/CustomerMessages?showAll=true',
    success: function (data) { $('#divMessages').html(data); }
});
```

### `GET /AptusPortal/Home/CustomerMessages`

Returns HTML fragment with customer messages for the home page.

| Param | Type | Description |
|-------|------|-------------|
| `showAll` | query | `true` to show all messages |

- **Response**: `200` — HTML fragment

### `GET /AptusPortal/CustomerBooking`

Main booking page showing "Mina bokningar" (My bookings) with existing bookings and a "Ny bokning" (New booking) button.

- **Response**: `200` — HTML
- **Bookings shown as cards** with booking ID, time, date, group name, and an unbook button containing the booking ID and unbook URL.

**Example response — no active bookings (only history):**

```html
<div id="content" style="display:none; background-color:white;">
    <p id="cancellationMsg" tabindex="-1" role="alert" aria-hidden="true"
       style="font-size:0">Avbokning pågår.</p>
    <div style="overflow:hidden">
        <div id="newBookingCard" class="bookingCard" style="position:relative">
            <button type="button" class="cardSmallFont" id="btnNewBooking" ...>
                <img src="/AptusPortal/Images/Booking/ny_bokning.png" alt="" />
                Ny bokning
            </button>
        </div>
    </div>
    <!-- HISTORIK section -->
    <div><h2>HISTORIK</h2></div>
    <div style="overflow:hidden">
        <div class="bookingCard" data-disabled="disabled">
            <div>21:00-23:30</div>
            <div class="cardSmallFont">TOR 19 FEB</div>
            <div style="padding:1rem">
                <img src="/AptusPortal/Images/Booking/tvatt_g.png" alt="" />
            </div>
            <div>Grupp 1</div>
            <button data-disabled="disabled" disabled="disabled" type="button"
                    class="bookButtonDisabled bookButton" tabindex="-1">
                Använt
            </button>
        </div>
    </div>
</div>
<div id="dialog-categories" title="Partial dialog"></div>
<div id="dialog-locationsGroups" title="Partial dialog"></div>
```

**Example response — with active bookings (after booking confirmation):**

The page includes a `FeedbackDialog` JS call for confirmations:

```html
<script>
$(document).ready(setTimeout(function(){
    FeedbackDialog('Ditt valda pass fredag 6 mars 11:00-13:30 är bokat.', 'INFORMATION', 'Stäng');
}, 500));
</script>
```

Active booking card with unbook button:

```html
<div class="bookingCard">
    <div>11:00-13:30</div>
    <div class="cardSmallFont">FRE 6 MAR</div>
    <div style="padding:1rem">
        <img src="/AptusPortal/Images/Booking/tvatt.png" alt="" />
    </div>
    <div>Grupp 2</div>
    <div class="cardSmallFont">Vad skall bokas?</div>
    <button aria-label="Avboka Tvätt 2026-03-06 11:00" class="unbookButton"
            id="2314155" title="Avboka" type="button">Avboka</button>
    <script>
        ConfirmCancelBooking('2314155',
            '/AptusPortal/CustomerBooking/Unbook/2314155',
            'Vill du avboka din bokning <b>11:00-13:30</b> på fredag 6 mars?',
            'AVBOKA?', 'Avboka', 'Avbryt');
    </script>
</div>
```

**Example response — with two active bookings:**

```html
<div class="bookingCard">
    <div>16:00-18:30</div>
    <div class="cardSmallFont">LÖR 7 MAR</div>
    <div style="padding:1rem">
        <img src="/AptusPortal/Images/Booking/tvatt.png" alt="" />
    </div>
    <div>Grupp 1</div>
    <button aria-label="Avboka Tvätt 2026-03-07 16:00" class="unbookButton"
            id="2314157" title="Avboka" type="button">Avboka</button>
    <script>ConfirmCancelBooking('2314157', '/AptusPortal/CustomerBooking/Unbook/2314157', ...);</script>
</div>
<div class="bookingCard">
    <div>16:00-18:30</div>
    <div class="cardSmallFont">LÖR 7 MAR</div>
    <div style="padding:1rem">
        <img src="/AptusPortal/Images/Booking/tvatt.png" alt="" />
    </div>
    <div>Grupp 2</div>
    <button aria-label="Avboka Tvätt 2026-03-07 16:00" class="unbookButton"
            id="2314158" title="Avboka" type="button">Avboka</button>
    <script>ConfirmCancelBooking('2314158', '/AptusPortal/CustomerBooking/Unbook/2314158', ...);</script>
</div>
```

**Booking card image conventions:**
- `tvatt.png` — active/upcoming laundry booking
- `tvatt_g.png` — past (greyed out) laundry booking in HISTORIK section

**Booking card structure:**
1. Time slot (e.g. `16:00-18:30`)
2. Day and date in Swedish abbreviated format (e.g. `LÖR 7 MAR`)
3. Category icon image
4. Group name (e.g. `Grupp 1`)
5. Subtitle `Vad skall bokas?`
6. For active bookings: `Avboka` button with `class="unbookButton"` and `id="{bookingId}"`
7. For past bookings: disabled button with text `Använt` and `class="bookButtonDisabled bookButton"`

---

## Booking Navigation (AJAX Endpoints)

These are called via `$.ajax` / jQuery `.load()` and require the `X-Requested-With: XMLHttpRequest` header.

**Required AJAX request headers:**

For JSON endpoints:
```
Accept: application/json, text/javascript, */*; q=0.01
X-Requested-With: XMLHttpRequest
```

For HTML fragment endpoints:
```
Accept: text/html, */*; q=0.01
X-Requested-With: XMLHttpRequest
```

### `GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerCategoryId`

Checks whether the user has access to one or multiple booking categories.

| Param | Type | Description |
|-------|------|-------------|
| `_` | query | Cache-buster timestamp (e.g. `1772701802510`) |

- **Response**: `200` — `application/json; charset=utf-8`
  - Single category: `{"status":"OK","Payload":"{categoryId}"}`
  - Multiple: `{"status":"OK","Payload":"Multi"}`

**Example request:**

```
GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerCategoryId?_=1772701802510 HTTP/2
Host: sssb.aptustotal.se
X-Requested-With: XMLHttpRequest
Accept: application/json, text/javascript, */*; q=0.01
Cookie: .ASPXAUTH=...; ASP.NET_SessionId=...
```

**Example response:**

```json
{"status":"OK","Payload":"Multi"}
```

### `GET /AptusPortal/CustomerBooking/CustomerCategories`

Returns an HTML fragment listing all booking categories available to the user.

- **Response**: `200` — `text/html; charset=utf-8` (HTML fragment)

**Example request:**

```
GET /AptusPortal/CustomerBooking/CustomerCategories HTTP/2
Host: sssb.aptustotal.se
X-Requested-With: XMLHttpRequest
Accept: text/html, */*; q=0.01
Cookie: .ASPXAUTH=...; ASP.NET_SessionId=...
```

**Example response body:**

```html
<button class="bookingNavigation" aria-label="Tvätt" type="button"
        onclick="LoadLocationGroupDialog('35')" style="float:left">
    <table style="width:100%">
        <tr>
            <td style="width:1px;">
                <img src="/AptusPortal/Images/Booking/tvatt_s.png" alt="" width="24" height="24" />
            </td>
            <td style="white-space:nowrap;">Tvätt</td>
            <td style="width:1px; text-align:right">
                <img src="/AptusPortal/Images/hoger.png" alt=" " />
            </td>
        </tr>
    </table>
</button>
<hr aria-hidden="true" class="hrDevider" style="margin:0; float:left; width:100%" />
```

Category buttons call `LoadLocationGroupDialog('{categoryId}')` on click.

### `GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerLocationGroupId`

Checks whether a category has one or multiple location groups.

| Param | Type | Description |
|-------|------|-------------|
| `categoryId` | query | Category ID (e.g. `35`) |
| `_` | query | Cache-buster timestamp |

- **Response**: `200` — `application/json; charset=utf-8`
  - Single group: `{"status":"OK","Payload":"{groupId}"}`
  - Multiple: `{"status":"OK","Payload":"Multi"}`

**Example request:**

```
GET /AptusPortal/CustomerBooking/JsonGetSingleCustomerLocationGroupId?categoryId=35&_=1772701802511 HTTP/2
```

**Example response:**

```json
{"status":"OK","Payload":"Multi"}
```

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

**Example response (without `passDate`):**

```html
<button class="bookingNavigation" type="button" style="float:left"
        aria-label="Första lediga tid"
        onclick="$('#dialog-locationsGroups').focus();
                 document.location.href = '/AptusPortal/CustomerBooking/FirstAvailable?categoryId=35&amp;firstX=10';">
    <table style="width:100%">
        <tr>
            <td style="width:1px"><img src="/AptusPortal/Images/Booking/forsta_lediga.png" alt="" /></td>
            <td style="white-space:nowrap; text-align:left">Första lediga tid</td>
            <td style="width:1px; text-align:right"><img src="/AptusPortal/Images/hoger.png" alt=" " /></td>
        </tr>
    </table>
</button>
<hr aria-hidden="true" style="margin:0; float:left; width:100%" />
<button class="bookingNavigation" type="button" aria-label="Grupp 1"
        onclick="$('#dialog-locationsGroups').focus();
                 document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=185'"
        style="float:left">
    <table style="width:100%">
        <tr>
            <td style="width:1px;"><img src="/AptusPortal/Images/Booking/plats.png" alt="" /></td>
            <td style="white-space:nowrap">Vad skall bokas? <br />Grupp 1</td>
            <td style="width:1px; text-align:right"><img src="/AptusPortal/Images/hoger.png" alt=" " /></td>
        </tr>
    </table>
</button>
<hr aria-hidden="true" class="hrDevider" style="margin:0; float:left; width:100%" />
<button class="bookingNavigation" type="button" aria-label="Grupp 2"
        onclick="$('#dialog-locationsGroups').focus();
                 document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=186'"
        style="float:left">
    <table style="width:100%">
        <tr>
            <td style="width:1px;"><img src="/AptusPortal/Images/Booking/plats.png" alt="" /></td>
            <td style="white-space:nowrap">Vad skall bokas? <br />Grupp 2</td>
            <td style="width:1px; text-align:right"><img src="/AptusPortal/Images/hoger.png" alt=" " /></td>
        </tr>
    </table>
</button>
<hr aria-hidden="true" class="hrDevider" style="margin:0; float:left; width:100%" />
```

**Example response (with `passDate=2026-03-02`):**

When `passDate` is provided, the "Första lediga tid" option is omitted, and group links include `overviewOffsetMonday`:

```html
<button class="bookingNavigation" type="button" aria-label="Grupp 1"
        onclick="$('#dialog-locationsGroups').focus();
                 document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=185&amp;overviewOffsetMonday=2026-03-02'"
        style="float:left">
    ...
</button>
<button class="bookingNavigation" type="button" aria-label="Grupp 2"
        onclick="$('#dialog-locationsGroups').focus();
                 document.location.href='/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=186&amp;overviewOffsetMonday=2026-03-02'"
        style="float:left">
    ...
</button>
```

---

## Client-Side Booking Navigation Logic

The "Ny bokning" button triggers this flow (extracted from inline `<script>` on the CustomerBooking page):

```js
var categoryDialogOpened = false;

$("#btnNewBooking").click(function () {
    var categoryId = AjaxGetSingleCustomerCategoryId();
    if (categoryId == -1) return;
    if (categoryId == 'Multi') {
        LoadCategoryDialog();
    } else {
        var bookingGroupId = AjaxGetSingleCustomerLocationGroupId(categoryId);
        if (bookingGroupId == 'Multi') {
            LoadLocationGroupDialog(categoryId);
        } else {
            location.href = 'CustomerBooking/BookingCalendarOverview?bookingGroupId=' + bookingGroupId;
        }
    }
});
```

- If only **one category** exists → skip category dialog, check groups directly
- If only **one group** exists → skip group dialog, go directly to `BookingCalendarOverview`
- Category dialog title: `"Välj en kategori"`
- Location group dialog title: `"Välj en plats där du vill boka"`
- Both dialogs auto-close after **120 seconds** (`SetCloseDialogTimeout`)
- Error responses from AJAX `.load()` calls are expected as JSON: `{"result":"Redirect","url":"..."}`

---

## Booking Views

### `GET /AptusPortal/CustomerBooking/FirstAvailable`

Shows the first N available booking slots across all location groups.

| Param | Type | Description |
|-------|------|-------------|
| `categoryId` | query | Category ID (e.g. `35`) |
| `firstX` | query | Number of slots to show (e.g. `10`) |

- **Response**: `200` — HTML page
- **Page title**: `Boka — Första lediga tid — Tvätt`
- Each slot rendered as a `bookingCard` with a `DoBooking()` button

**Example response body** (booking cards only):

```html
<div id="content" style="display:none; background-color:white">
    <p id="bookingMsg" tabindex="-1" role="alert" aria-hidden="true"
       style="font-size:0">Bokning pågår.</p>

    <!-- Slot 1: passNo=9 on 2026-03-05, Grupp 1 -->
    <div class="bookingCard">
        <div>23:30-02:00</div>
        <div class="cardSmallFont">TOR 5 MAR</div>
        <div style="padding:1rem">
            <img src="/AptusPortal/Images/Booking/tvatt.png" alt="" />
        </div>
        <div>Grupp 1</div>
        <button type="button" ...
            onclick="DoBooking('/AptusPortal/CustomerBooking/BookFirstAvailable?passNo=9&amp;passDate=2026-03-05&amp;bookingGroupId=185'); return false;">
        </button>
    </div>

    <!-- Slot 2: same time, Grupp 2 -->
    <div class="bookingCard">
        <div>23:30-02:00</div>
        <div class="cardSmallFont">TOR 5 MAR</div>
        <div style="padding:1rem">
            <img src="/AptusPortal/Images/Booking/tvatt.png" alt="" />
        </div>
        <div>Grupp 2</div>
        <button type="button" ...
            onclick="DoBooking('/AptusPortal/CustomerBooking/BookFirstAvailable?passNo=9&amp;passDate=2026-03-05&amp;bookingGroupId=186'); return false;">
        </button>
    </div>

    <!-- ... up to 10 slots total -->
</div>
```

**All 10 slots from observed session:**

| # | Time | Date | Group | passNo | passDate | bookingGroupId |
|---|------|------|-------|--------|----------|----------------|
| 1 | 23:30-02:00 | TOR 5 MAR | Grupp 1 | 9 | 2026-03-05 | 185 |
| 2 | 23:30-02:00 | TOR 5 MAR | Grupp 2 | 9 | 2026-03-05 | 186 |
| 3 | 02:00-04:00 | FRE 6 MAR | Grupp 1 | 0 | 2026-03-06 | 185 |
| 4 | 02:00-04:00 | FRE 6 MAR | Grupp 2 | 0 | 2026-03-06 | 186 |
| 5 | 04:00-06:00 | FRE 6 MAR | Grupp 1 | 1 | 2026-03-06 | 185 |
| 6 | 04:00-06:00 | FRE 6 MAR | Grupp 2 | 1 | 2026-03-06 | 186 |
| 7 | 06:00-08:30 | FRE 6 MAR | Grupp 1 | 2 | 2026-03-06 | 185 |
| 8 | 06:00-08:30 | FRE 6 MAR | Grupp 2 | 2 | 2026-03-06 | 186 |
| 9 | 11:00-13:30 | FRE 6 MAR | Grupp 2 | 4 | 2026-03-06 | 186 |
| 10 | 23:30-02:00 | FRE 6 MAR | Grupp 1 | 9 | 2026-03-06 | 185 |

**DoBooking function** (inline JS):

```js
function DoBooking(locationHref) {
    $("#bookingMsg").removeAttr("aria-hidden").focus();
    ShowWorkingOverlay();
    document.location.href = locationHref;
}
```

### `GET /AptusPortal/CustomerBooking/BookingCalendarOverview`

Multi-week calendar overview for a specific location group showing which days have available slots.

| Param | Type | Description |
|-------|------|-------------|
| `bookingGroupId` | query | Location group ID (e.g. `185` or `186`) |
| `overviewOffsetMonday` | query | *(optional)* Monday date to offset the overview display (e.g. `2026-03-02`) |

- **Response**: `200` — HTML page
- **Page title**: `Boka — Tvätt — Grupp 1` (or Grupp 2)
- Days with availability are colored and link to `BookingCalendar` with the corresponding week's Monday date
- Shows **5 weeks** at a time

**Example response body** (calendar structure):

```html
<div id="content" style="display:none; background-color:white;">
    <div id="weekDays">
        <div style="display:table-row">
            <div class="weekDay" ...>Vecka</div>
            <div class="weekDay">Måndag</div>
            <div class="weekDay">Tisdag</div>
            <div class="weekDay">Onsdag</div>
            <div class="weekDay">Torsdag</div>
            <div class="weekDay">Fredag</div>
            <div class="weekDay">Lördag</div>
            <div class="weekDay">Söndag</div>
        </div>
    </div>

    <!-- Week row — clickable, links to BookingCalendar -->
    <div class="weekWrapperDiv" role="button" tabindex="0" title="Välj vecka 10"
         data-new-location="/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185&amp;passDate=2026-03-02"
         aria-label="Välj Vecka 10, Från 2026-03-02 Till 2026-03-08">
        <div class="weekNumber">10</div>

        <!-- Each day shows availability blocks -->
        <div class="dayWrapperDiv">
            <div class="sectionsWrapper">
                <div class="dayBlock notBookable"></div>
                <div class="dayBlock notBookable"></div>
                <div class="dayBlock notBookable"></div>
                <div class="dayBlock notBookable"></div>
                <div class="dayBlock freeBookable"></div>  <!-- at least one slot available -->
            </div>
            <div ...>5<br /><div ...>MAR</div></div>
        </div>
        <!-- ... 7 days per week -->
    </div>
    <!-- ... 5 weeks total -->
</div>
```

**Day block CSS classes:**
- `dayBlock notBookable` — no available slots (past or fully booked)
- `dayBlock freeBookable` — at least one slot available

**Observed weeks (for bookingGroupId=185):**

| Week | passDate (Monday) |
|------|-------------------|
| 10 | 2026-03-02 |
| 11 | 2026-03-09 |
| 12 | 2026-03-16 |
| 13 | 2026-03-23 |
| 14 | 2026-03-30 |

**Footer navigation:**

```html
<footer class="footer" ...>
    <table style="width:100%">
        <tr>
            <td style="text-align:left">
                <a aria-label="Föregående vecka"
                   href="/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=185&amp;overviewOffsetMonday=2026-01-26"
                   title="Föregående vecka">
                    <img src="/AptusPortal/Images/bakat_vit.png" alt=" " />
                </a>
            </td>
            <td style="width:1px;">
                <a href="/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=185"
                   title="NU">
                    <img src="/AptusPortal/Images/Booking/now.png" alt=" " />
                </a>
            </td>
            <td style="text-align:right">
                <a aria-label="Nästa vecka"
                   href="/AptusPortal/CustomerBooking/BookingCalendarOverview?bookingGroupId=185&amp;overviewOffsetMonday=2026-04-06"
                   title="Nästa vecka">
                    <img src="/AptusPortal/Images/framat_vit.png" alt=" " />
                </a>
            </td>
        </tr>
    </table>
</footer>
```

The overview jumps **5 weeks** back/forward per navigation click. The "NU" (now) button links without `overviewOffsetMonday` to reset to the current view.

### `GET /AptusPortal/CustomerBooking/BookingCalendar`

Weekly calendar detail view showing all time slots for each day, with their availability status.

| Param | Type | Description |
|-------|------|-------------|
| `bookingGroupId` | query | Location group ID |
| `passDate` | query | The Monday of the week to display (e.g. `2026-03-02`). If omitted, defaults to current week. |

- **Response**: `200` — HTML page
- Available slots have buttons calling `DoBooking('/AptusPortal/CustomerBooking/Book?passNo=X&passDate=YYYY-MM-DD&bookingGroupId=N')`
- Week navigation via `passDate` for previous/next Monday

**Example response body** (calendar structure):

```html
<div id="content" style="display:none; background-color:#fff;" role="application">
    <p id="bookingMsg" tabindex="-1" role="alert" aria-hidden="true"
       style="font-size:0">Bokning pågår.</p>
    <p id="cancellationMsg" tabindex="-1" role="alert" aria-hidden="true"
       style="font-size:0">Avbokning pågår.</p>

    <div style="display:table; width:100%;" id="week">
        <div style="display:table-row">
            <div id="weekDays" role="application"></div>

            <!-- Day column (7 per week: Mon–Sun) -->
            <div class="dayColumn">
                <div class="weekDay" ...
                     aria-label="Måndag 2 Mars 0 bokningsbara pass "
                     id="weekDay_0" tabindex="0">Måndag</div>
                <div class="dayOfMonth">2</div>

                <!-- Non-bookable interval (past/taken) -->
                <div class="interval">
                    <div ...>02:00 - 04:00<br /></div>
                    &nbsp;
                </div>

                <!-- ... more intervals ... -->
            </div>

            <!-- Day with bookable slots -->
            <div class="dayColumn">
                <div class="weekDay" ...
                     aria-label="Torsdag 5 Mars 1 bokningsbara pass ">Torsdag</div>
                <div class="dayOfMonth">5</div>

                <!-- Bookable interval -->
                <div class="interval bookable">
                    <div ...>23:30 - 02:00<br /></div>
                    <button type="button"
                            id="button&#95;3&#95;1"
                            class="bookButton bookButtonNotUnbookable"
                            title="Boka"
                            aria-label="Boka Grupp 1 den 5 mars 2026 23:30 Till 02:00"
                            onclick="DoBooking('/AptusPortal/CustomerBooking/Book?passNo=9&amp;passDate=2026-03-05&amp;bookingGroupId=185')">
                    </button>
                </div>
            </div>
        </div>
    </div>
</div>
```

**After booking — own booking slot:**

```html
<!-- User's own booked slot -->
<div class="interval own">
    <div ...>16:00 - 18:30<br /></div>
    <button aria-label="Avboka Grupp 1 2026-03-07 16:00 - 18:30"
            class="unbookButton unbookButtonNotBookable"
            id="button_5_4" title="Avboka" type="button"></button>
    <script>
        ConfirmCancelBooking('button_5_4',
            '/AptusPortal/CustomerBooking/Unbook/2314157?passDate=2026-03-07&bookingGroupId=185',
            'Vill du avboka din bokning <b>16:00&nbsp;-&nbsp;18:30</b> på lördag 7 mars?',
            'AVBOKA?', 'Avboka', 'Avbryt');
    </script>
</div>
```

**Interval CSS classes:**
- `interval` — not bookable (past, or taken by someone else)
- `interval bookable` — available for booking (contains a `bookButton`)
- `interval own` — booked by the current user (contains an `unbookButton`)

**Button CSS classes:**
- `bookButton bookButtonNotUnbookable` — book button (the slot can be booked but not currently owned)
- `unbookButton unbookButtonNotBookable` — unbook button (the slot is owned but the book button is hidden)

**Button ID format:** `button&#95;{dayIndex}&#95;{passIndex}` (e.g. `button_5_4` = day 5 (Saturday), pass 4)

**Week day header aria-label format:** `"{DayName} {dayNum} {MonthName} {N} bokningsbara pass "`

**Bookable slots observed in week 10 (bookingGroupId=185):**

| passNo | passDate | Time |
|--------|----------|------|
| 9 | 2026-03-05 | 23:30-02:00 |
| 0 | 2026-03-06 | 02:00-04:00 |
| 1 | 2026-03-06 | 04:00-06:00 |
| 2 | 2026-03-06 | 06:00-08:30 |
| 9 | 2026-03-06 | 23:30-02:00 |
| 0 | 2026-03-07 | 02:00-04:00 |
| 1 | 2026-03-07 | 04:00-06:00 |
| 2 | 2026-03-07 | 06:00-08:30 |
| 6 | 2026-03-07 | 16:00-18:30 |
| 7 | 2026-03-07 | 18:30-21:00 |
| 8 | 2026-03-07 | 21:00-23:30 |
| 9 | 2026-03-07 | 23:30-02:00 |
| 0 | 2026-03-08 | 02:00-04:00 |
| 1 | 2026-03-08 | 04:00-06:00 |
| 2 | 2026-03-08 | 06:00-08:30 |
| 9 | 2026-03-08 | 23:30-02:00 |

**Footer navigation:**

```html
<footer class="footer" ...>
    <table style="width:100%;">
        <tr>
            <td style="text-align:left">
                <a aria-label="Föregående vecka"
                   href="/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185&amp;passDate=2026-02-23"
                   title="Föregående vecka">
                    <img src="/AptusPortal/Images/bakat_vit.png" alt=" " />
                </a>
            </td>
            <td style="width:1px;">
                Vecka 10 &nbsp;
                <a href="/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185"
                   title="NU">
                    <img src="/AptusPortal/Images/Booking/now.png" alt=" " />
                </a>
            </td>
            <td style="text-align:right">
                <a aria-label="Nästa vecka"
                   href="/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185&amp;passDate=2026-03-09"
                   title="Nästa vecka">
                    <img src="/AptusPortal/Images/framat_vit.png" alt=" " />
                </a>
            </td>
        </tr>
    </table>
</footer>
```

Navigation advances/retreats by **1 week** (7 days). The "NU" button links without `passDate` to show the current week.

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

**Example request:**

```
GET /AptusPortal/CustomerBooking/BookFirstAvailable?passNo=4&passDate=2026-03-06&bookingGroupId=186 HTTP/2
Host: sssb.aptustotal.se
Cookie: .ASPXAUTH=...; ASP.NET_SessionId=...
```

**Example response:**

```
HTTP/2 302
location: /AptusPortal/CustomerBooking
```

- **Response**: `302` → `/AptusPortal/CustomerBooking`
- **Confirmation** (on redirected page): `FeedbackDialog('Ditt valda pass fredag 6 mars 11:00-13:30 är bokat.', 'INFORMATION', 'Stäng')`

**FeedbackDialog format:** `FeedbackDialog('{message}', '{type}', '{buttonText}')`

### `GET /AptusPortal/CustomerBooking/Book`

Books a time slot from the calendar view.

| Param | Type | Description |
|-------|------|-------------|
| `passNo` | query | Time slot index (0–9) |
| `passDate` | query | Date to book |
| `bookingGroupId` | query | Location group ID |

**Example request:**

```
GET /AptusPortal/CustomerBooking/Book?passNo=6&passDate=2026-03-07&bookingGroupId=185 HTTP/2
```

**Example response:**

```
HTTP/2 302
location: /AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185&passDate=2026-03-07
```

- **Response**: `302` → `/AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId={id}&passDate={date}`
- **Confirmation** (on redirected page): `FeedbackDialog('Ditt valda pass lördag 7 mars 16:00-18:30 är bokat.', 'INFORMATION', 'Stäng')`

**Note:** The redirect `passDate` in the `Book` response is the booked date itself (not necessarily the Monday of the week), so the calendar view centers on the booked day's week.

### `GET /AptusPortal/CustomerBooking/Unbook/{bookingId}`

Cancels/removes an existing booking.

| Param | Type | Description |
|-------|------|-------------|
| `{bookingId}` | path | The numeric booking ID (e.g. `2314155`) |
| `passDate` | query | *(optional, calendar view only)* Date for redirect back |
| `bookingGroupId` | query | *(optional, calendar view only)* Group ID for redirect back |

**Example request (from main booking page):**

```
GET /AptusPortal/CustomerBooking/Unbook/2314155 HTTP/2
```

**Example response:**

```
HTTP/2 302
location: /AptusPortal/CustomerBooking
```

**Example request (from calendar view):**

```
GET /AptusPortal/CustomerBooking/Unbook/2314157?passDate=2026-03-07&bookingGroupId=185 HTTP/2
```

**Example response:**

```
HTTP/2 302
location: /AptusPortal/CustomerBooking/BookingCalendar?bookingGroupId=185&passDate=2026-03-07
```

- **Response**: `302` → `/AptusPortal/CustomerBooking` (from main page) or `/AptusPortal/CustomerBooking/BookingCalendar?...` (from calendar view)
- **Confirmation**: `FeedbackDialog('Ditt pass har blivit avbokat.', 'INFORMATION', 'Stäng')`

**ConfirmCancelBooking call format** (client-side confirmation dialog before unbooking):

```js
ConfirmCancelBooking(
    '{elementId}',                    // button element ID or booking ID
    '{unbookUrl}',                    // full unbook URL with optional query params
    '{confirmMessage}',               // HTML message, e.g. 'Vill du avboka din bokning <b>16:00-18:30</b> på lördag 7 mars?'
    '{dialogTitle}',                  // 'AVBOKA?'
    '{confirmButtonText}',            // 'Avboka'
    '{cancelButtonText}'              // 'Avbryt'
);
```

---

## Settings Pages

### `GET /AptusPortal/CustomerSettings`

Settings page showing available configuration options.

- **Response**: `200` — HTML

**Example response body:**

```html
<div class="wrapper">
    <!-- Entry phone number card -->
    <div class="settingsCard" style="position:relative">
        <div id="divCardText_1130">
            <div ...>Porttelefon</div>
            <label class="cardSmallFont">XXXX-XXXX-XXX</label>
        </div>
        <img src="/AptusPortal/Images/phonenumber.png" width="40" height="40" />
        <button type="button" class="settingsCardButton"
                onclick="location.href = '/AptusPortal/CustomerSettings/ChangeEntryPhoneNumber/1130?isExtraName=False'">
            Ändra
        </button>
    </div>

    <!-- Notification devices card -->
    <div class="settingsCard" style="position:relative">
        <div id="divCardTextDoorman">Notifieringsenheter</div>
        <img src="/AptusPortal/Images/aptus_notifications.png" width="40" height="40" />
        <button type="button" class="settingsCardButton"
                onclick="location.href='/AptusPortal/CustomerSettings/CustomerDevices'">
            Ändra
        </button>
    </div>
</div>
```

### `GET /AptusPortal/CustomerSettings/ChangeEntryPhoneNumber/{entryId}`

Page to change the entry phone number.

| Param | Type | Description |
|-------|------|-------------|
| `{entryId}` | path | Entry ID (e.g. `1130`) |
| `isExtraName` | query | `False` for primary |

- **Response**: `200` — HTML with phone number form

**Example response body:**

```html
<form action="/AptusPortal/CustomerSettings/ChangeEntryPhoneNumber/1130?isExtraName=False"
      method="post">
    <input name="__RequestVerificationToken" type="hidden" value="82Gdv7U_..." />
    <div class="cardWrapper" style="float:left">
        <div>
            <span>Telefonnummer:</span>
            <span>
                <input type="text" maxlength="15" id="phoneNumber" name="phoneNumber"
                       placeholder="+46 76 632 72 7" />
            </span>
        </div>
        <div>
            <button type="button" class="button cancelButton"
                    onclick="location.href='/AptusPortal/CustomerSettings';">Avbryt</button>
            <button type="submit" class="button saveButton">Spara</button>
        </div>
    </div>
</form>
```

### `POST /AptusPortal/CustomerSettings/ChangeEntryPhoneNumber/{entryId}`

Submits the phone number change.

- **Content-Type**: `application/x-www-form-urlencoded`
- **Form Fields**:
  | Field | Description |
  |-------|-------------|
  | `__RequestVerificationToken` | Anti-forgery token from form |
  | `phoneNumber` | New phone number (max 15 chars, digits and `+`, space, `-`, `w`, `~`) |

### `GET /AptusPortal/CustomerSettings/CustomerDevices`

Lists registered notification devices (push notification endpoints).

- **Response**: `200` — HTML

**Example response body:**

```html
<div class="wrapper">
    <div class="settingsCard" style="position:relative">
        <div id="divCardText_15265">
            <div ...>IPHONE15,4</div>
            <div style="padding:1rem">
                <img src="/AptusPortal/Images/aptus_notifications.png" width="40" height="40" />
            </div>
            <div class="cardSmallFont">SENAST ANVÄND</div>
            <div class="cardSmallFont">2026-02-15</div>
        </div>
        <div style="display:table">
            <div style="display:table-cell; width:100%">
                <button type="button" class="notificationUnitCardButton manageKeyButton"
                        onclick="location.href = '/AptusPortal/CustomerSettings/BlockCredentialDevice/15265'">
                    SPÄRRA
                </button>
            </div>
            <div style="display:table-cell; width:100%">
                <button type="button" class="notificationUnitCardButton notificationUnitCardRightButton"
                        onclick="ConfirmSendServiceRequestDialog(
                            '/AptusPortal/CustomerSettings/DeleteCredentialDevice/15265',
                            'Vill du radera enheten från listan över enheter som tar emot notifieringsmeddelanden?',
                            'Radera notifieringsenhet', 'Ta bort', 'Avbryt')">
                    Radera
                </button>
            </div>
        </div>
    </div>
    <!-- More device cards... -->
</div>
```

### `GET /AptusPortal/CustomerSettings/BlockCredentialDevice/{deviceId}`

Blocks a notification device.

| Param | Type | Description |
|-------|------|-------------|
| `{deviceId}` | path | Device ID (e.g. `15265`) |

### `GET /AptusPortal/CustomerSettings/DeleteCredentialDevice/{deviceId}`

Deletes a notification device.

| Param | Type | Description |
|-------|------|-------------|
| `{deviceId}` | path | Device ID (e.g. `15265`) |

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
| Category "Tvatt" (Laundry) | `35` |
| Grupp 1 | `bookingGroupId=185` |
| Grupp 2 | `bookingGroupId=186` |
| Entry phone setting | `entryId=1130` |

---

## Session Flow Summary

```
1. GET  /Account/Login                          → Login page (200)
2. POST /Account/Login                          → Authenticate → 302 → /
3. GET  /                                       → Portal home (200)
4. GET  /CustomerBooking                        → My bookings — empty (200)
5. GET  /CustomerBooking/JsonGetSingleCustomerCategoryId  → {"status":"OK","Payload":"Multi"}
6. GET  /CustomerBooking/CustomerCategories      → [Tvatt (35)]
7. GET  /CustomerBooking/JsonGetSingleCustomerLocationGroupId?categoryId=35 → {"status":"OK","Payload":"Multi"}
8. GET  /CustomerBooking/CustomerLocationGroups?categoryId=35 → [First available, Grupp 1, Grupp 2]
9. GET  /CustomerBooking/FirstAvailable?categoryId=35&firstX=10 → 10 available slots
10. GET /CustomerBooking/BookFirstAvailable?passNo=4&passDate=2026-03-06&bookingGroupId=186 → 302 → /CustomerBooking
11. GET /CustomerBooking                        → Shows booking 2314155 + confirmation dialog
12. GET /CustomerBooking/Unbook/2314155          → 302 → /CustomerBooking
13. GET /CustomerBooking                        → Empty again + unbook confirmation
14–17. (Repeat category/group selection flow)
18. GET /CustomerBooking/BookingCalendarOverview?bookingGroupId=185 → 5-week overview
19. GET /CustomerBooking/BookingCalendar?bookingGroupId=185&passDate=2026-03-02 → Weekly view
20. GET /CustomerBooking/Book?passNo=6&passDate=2026-03-07&bookingGroupId=185 → 302 → /BookingCalendar?bookingGroupId=185&passDate=2026-03-07
21. GET /CustomerBooking/BookingCalendar?bookingGroupId=185&passDate=2026-03-07 → Weekly view + confirmation + own slot
22. GET /CustomerBooking/CustomerLocationGroups?categoryId=35&passDate=2026-03-02 → [Grupp 1, Grupp 2] (no "First available", with overviewOffsetMonday)
23. GET /CustomerBooking/BookingCalendarOverview?bookingGroupId=186&overviewOffsetMonday=2026-03-02 → Overview offset to week 10
24. GET /CustomerBooking/BookingCalendar?bookingGroupId=186&passDate=2026-03-02 → Weekly view
25. GET /CustomerBooking/Book?passNo=6&passDate=2026-03-07&bookingGroupId=186 → 302 → /BookingCalendar?bookingGroupId=186&passDate=2026-03-07
26. GET /CustomerBooking/BookingCalendar?bookingGroupId=186&passDate=2026-03-07 → Weekly view + confirmation
27. GET /CustomerBooking                        → Shows bookings 2314157 + 2314158
28. GET /CustomerSettings                       → Settings page (Porttelefon, Notifieringsenheter)
29. GET /CustomerSettings/ChangeEntryPhoneNumber/1130?isExtraName=False → Phone number form
30. GET /CustomerSettings                       → Back to settings
31. GET /CustomerSettings/CustomerDevices        → Device list (2 iPhones)
32. GET /                                       → Home page
33. GET /CustomerBooking                        → My bookings
```

---

## Architectural Notes

- **All booking/unbooking actions use GET** — no POST/PUT/DELETE for state-changing operations.
- **Server-rendered MVC** — not a REST API. Booking actions return 302 redirects; confirmations are embedded in the HTML of the redirected page via `FeedbackDialog()` JS calls.
- **AJAX is only used for the category/group selection dialogs** — jQuery `.load()` for HTML fragments and `$.ajax` for the JSON "single or multi" checks.
- **Booking IDs are sequential integers** (e.g. `2314155`, `2314157`, `2314158`).
- **Two booking endpoints exist**: `BookFirstAvailable` (from "First Available" list, redirects to main page) and `Book` (from calendar view, redirects back to the calendar).
- **Unbook from calendar view** includes `passDate` and `bookingGroupId` query params so the redirect goes back to the correct calendar view. Unbook from the main booking page has no query params and redirects to `/CustomerBooking`.
- **The calendar overview shows 5 weeks at a time** and navigates in 5-week jumps. The weekly calendar view navigates 1 week at a time.
- **Dialog auto-close**: Category and location group selection dialogs automatically close after 120 seconds.
- **The `firstX` parameter** in FirstAvailable controls how many slots to show (observed value: `10`). Slots are shown across all groups (interleaved by earliest available time).
- **Settings pages use POST with CSRF tokens** (unlike booking actions which use GET). The phone number form includes `__RequestVerificationToken`.
- **Device management** uses `BlockCredentialDevice/{id}` to block and `DeleteCredentialDevice/{id}` to delete, both via GET with client-side confirmation dialogs.
