import { load } from "cheerio";
import { DateTime } from "luxon";
import { AppError } from "./errors.js";
import { encodePwEnc } from "./pwenc.js";
import { decodeTimeslotId, encodeTimeslotId } from "./timeslot-id.js";
import type {
  ActionResponse,
  BookingGroup,
  CanonicalTimeslot,
  GroupActionResult,
  GroupSlot,
  TimeslotsResponse,
  WeekWindow
} from "./types.js";
import { STOCKHOLM_TZ } from "./types.js";

interface SessionState {
  cookies: Map<string, string>;
  authenticatedAt: number;
}

interface HttpResult {
  status: number;
  body: string;
  path: string;
  location?: string;
}

interface RequestOptions {
  method?: "GET" | "POST";
  body?: string;
  headers?: Record<string, string>;
  refererPath?: string;
  xRequestedWith?: boolean;
}

interface ParsedCalendar {
  slots: GroupSlot[];
  week: WeekWindow;
  feedback?: string;
}

interface LoginFormData {
  actionPath: string;
  requestVerificationToken: string;
  passwordSalt: string;
  deviceType: string;
  desktopSelected: string;
  feedback?: string;
}

interface CanonicalTarget {
  startAt: string;
  endAt: string;
}

export class AptusClient {
  private readonly origin: string;
  private readonly portalPath = "/AptusPortal";
  private readonly userAgent: string;
  private readonly sessions = new Map<string, SessionState>();

  constructor(args?: { baseUrl?: string; userAgent?: string }) {
    this.origin = (args?.baseUrl ?? "https://sssb.aptustotal.se").replace(/\/$/, "");
    this.userAgent =
      args?.userAgent ??
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:151.0) Gecko/20100101 Firefox/151.0";
  }

  async listTimeslots(objectId: string, date: string): Promise<TimeslotsResponse> {
    assertISODate(date, "date");

    const { groups } = await this.getLaundryGroups(objectId);
    const calendars: Array<{ groupId: number; parsed: ParsedCalendar }> = [];
    for (const group of groups) {
      calendars.push({
        groupId: group.id,
        parsed: await this.fetchCalendar(objectId, group.id, date)
      });
    }

    const week = calendars[0]?.parsed.week ?? weekWindowForDate(date);
    const timeslots = buildCanonicalTimeslots(groups, calendars.map((c) => ({ groupId: c.groupId, slots: c.parsed.slots })));

    return { week, groups, timeslots };
  }

  async bookTimeslot(objectId: string, timeslotId: string, groupIds: number[]): Promise<ActionResponse> {
    const target = decodeCanonicalTarget(timeslotId);
    const passDate = startDateOfTarget(target);

    const { groups } = await this.getLaundryGroups(objectId);
    validateGroupIds(groupIds, groups);

    const results: GroupActionResult[] = [];
    for (const groupId of groupIds) {
      results.push(await this.bookForGroup(objectId, groupId, passDate, target));
    }

    return {
      timeslotId,
      results,
      overallStatus: computeOverallStatus(results, new Set(["booked", "already_booked"]))
    };
  }

  async cancelTimeslot(objectId: string, timeslotId: string, groupIds: number[]): Promise<ActionResponse> {
    const target = decodeCanonicalTarget(timeslotId);
    const passDate = startDateOfTarget(target);

    const { groups } = await this.getLaundryGroups(objectId);
    validateGroupIds(groupIds, groups);

    const results: GroupActionResult[] = [];
    for (const groupId of groupIds) {
      results.push(await this.cancelForGroup(objectId, groupId, passDate, target));
    }

    return {
      timeslotId,
      results,
      overallStatus: computeOverallStatus(results, new Set(["cancelled", "not_booked"]))
    };
  }

  private async getLaundryGroups(objectId: string): Promise<{ groups: BookingGroup[] }> {
    const categoriesRes = await this.requestWithAuth(objectId, "/CustomerBooking/CustomerCategories", {
      refererPath: "/CustomerBooking",
      xRequestedWith: true
    });

    const categories = parseCategories(categoriesRes.body);
    if (!categories.length) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_PARSE_ERROR",
        message: "No Aptus categories found",
        upstream: { path: categoriesRes.path, status: categoriesRes.status }
      });
    }

    const category = categories[0];
    const groupsRes = await this.requestWithAuth(
      objectId,
      `/CustomerBooking/CustomerLocationGroups?categoryId=${category.id}`,
      {
        refererPath: "/CustomerBooking",
        xRequestedWith: true
      }
    );

    const groups = parseGroups(groupsRes.body);
    if (!groups.length) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_PARSE_ERROR",
        message: "No Aptus booking groups found",
        upstream: { path: groupsRes.path, status: groupsRes.status }
      });
    }

    return { groups };
  }

  private async fetchCalendar(objectId: string, groupId: number, passDate: string): Promise<ParsedCalendar> {
    const path = `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`;
    const response = await this.requestWithAuth(objectId, path, {
      refererPath: `/CustomerBooking/BookingCalendarOverview?bookingGroupId=${groupId}`
    });

    if (response.status >= 300 && response.status < 400 && response.location) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_REDIRECT",
        message: "Unexpected redirect while loading BookingCalendar",
        upstream: {
          path: response.path,
          status: response.status,
          location: response.location
        }
      });
    }

    return parseBookingCalendar(response.body, groupId, passDate);
  }

  private async bookForGroup(
    objectId: string,
    groupId: number,
    passDate: string,
    target: CanonicalTarget
  ): Promise<GroupActionResult> {
    const before = await this.fetchCalendar(objectId, groupId, passDate);
    const slot = findMatchingSlot(before.slots, target);
    if (!slot) {
      return actionFailure(groupId, "BOOK_SLOT_NOT_FOUND", "Timeslot does not exist in group calendar", {
        target
      });
    }

    if (slot.status === "own") {
      return { groupId, status: "already_booked", message: "Timeslot is already booked" };
    }

    if (!slot.bookUrl) {
      return { groupId, status: "not_bookable", message: "Timeslot is not bookable for this group" };
    }

    await this.requestWithAuth(objectId, slot.bookUrl, {
      refererPath: `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`
    });

    const after = await this.fetchCalendar(objectId, groupId, passDate);
    const updated = findMatchingSlot(after.slots, target);
    if (updated?.status === "own") {
      return { groupId, status: "booked", message: after.feedback ?? "Booked" };
    }

    return actionFailure(groupId, "BOOK_FAILED", after.feedback ?? "Booking did not succeed", {
      feedback: after.feedback,
      target
    });
  }

  private async cancelForGroup(
    objectId: string,
    groupId: number,
    passDate: string,
    target: CanonicalTarget
  ): Promise<GroupActionResult> {
    const before = await this.fetchCalendar(objectId, groupId, passDate);
    const slot = findMatchingSlot(before.slots, target);
    if (!slot) {
      return actionFailure(groupId, "CANCEL_SLOT_NOT_FOUND", "Timeslot does not exist in group calendar", {
        target
      });
    }

    if (slot.status !== "own") {
      return { groupId, status: "not_booked", message: "Timeslot is not booked for this group" };
    }

    if (!slot.unbookUrl) {
      return actionFailure(groupId, "NOT_CANCELLABLE", "Timeslot cannot be cancelled from upstream response", {
        target
      });
    }

    await this.requestWithAuth(objectId, slot.unbookUrl, {
      refererPath: `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`
    });

    const after = await this.fetchCalendar(objectId, groupId, passDate);
    const updated = findMatchingSlot(after.slots, target);
    if (!updated || updated.status !== "own") {
      return { groupId, status: "cancelled", message: after.feedback ?? "Cancelled" };
    }

    return actionFailure(groupId, "CANCEL_FAILED", after.feedback ?? "Cancellation did not succeed", {
      feedback: after.feedback,
      target
    });
  }

  private async requestWithAuth(objectId: string, path: string, options?: RequestOptions): Promise<HttpResult> {
    await this.ensureAuthenticated(objectId);

    let session = this.sessions.get(objectId)!;
    let response = await this.requestRaw(session, path, options);

    if (looksLikeSessionExpired(response)) {
      this.sessions.delete(objectId);
      const loginLocation = isLoginRedirect(response) && response.location
        ? response.location
        : "/AptusPortal/Account/Login";
      await this.login(objectId, loginLocation);
      session = this.sessions.get(objectId)!;
      response = await this.requestRaw(session, path, options);
    }

    if (isLoginRedirect(response) || response.status === 401) {
      throw new AppError({
        statusCode: 401,
        code: "AUTH_FAILED",
        message: "Authentication failed after retry",
        upstream: {
          path: response.path,
          status: response.status,
          location: response.location
        }
      });
    }

    if (isAccountErrorRedirect(response)) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_ACCOUNT_ERROR",
        message: "Aptus returned Account/Error",
        upstream: {
          path: response.path,
          status: response.status,
          location: response.location
        }
      });
    }

    return response;
  }

  private async ensureAuthenticated(objectId: string): Promise<void> {
    if (this.sessions.has(objectId)) return;
    await this.login(objectId, "/AptusPortal/Account/Login");
  }

  private async login(objectId: string, loginLocation: string): Promise<void> {
    const session: SessionState = { cookies: new Map(), authenticatedAt: Date.now() };

    const loginPath = normalizePortalPath(loginLocation, this.origin, this.portalPath);
    const loginPage = await this.requestRawFollowingRedirects(session, loginPath, {}, 8);
    const form = parseLoginForm(loginPage.body, loginPage.path);

    const postPath = normalizePortalPath(form.actionPath, this.origin, this.portalPath);
    const payload = new URLSearchParams({
      DeviceType: form.deviceType,
      DesktopSelected: form.desktopSelected,
      __RequestVerificationToken: form.requestVerificationToken,
      UserName: objectId,
      Password: objectId,
      PwEnc: encodePwEnc(objectId, form.passwordSalt),
      PasswordSalt: form.passwordSalt
    });

    const post = await this.requestRaw(session, postPath, {
      method: "POST",
      body: payload.toString(),
      refererPath: loginPath,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Origin: this.origin
      }
    });

    if (!session.cookies.has(".ASPXAUTH")) {
      const feedback = parseFeedbackDialog(post.body) ?? form.feedback;
      throw new AppError({
        statusCode: 401,
        code: "AUTH_FAILED",
        message: feedback ?? "Aptus login failed",
        upstream: {
          path: post.path,
          status: post.status,
          location: post.location,
          feedback
        }
      });
    }

    session.authenticatedAt = Date.now();
    this.sessions.set(objectId, session);
  }

  private async requestRaw(session: SessionState, path: string, options?: RequestOptions): Promise<HttpResult> {
    const method = options?.method ?? "GET";
    const url = toAbsolutePortalUrl(path, this.origin, this.portalPath);

    const headers: Record<string, string> = {
      "User-Agent": this.userAgent,
      Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Encoding": "identity",
      ...options?.headers
    };

    if (options?.refererPath) {
      headers.Referer = toAbsolutePortalUrl(options.refererPath, this.origin, this.portalPath);
    }

    if (options?.xRequestedWith) {
      headers["X-Requested-With"] = "XMLHttpRequest";
    }

    const cookieHeader = serializeCookies(session.cookies);
    if (cookieHeader) {
      headers.Cookie = cookieHeader;
    }

    const response = await fetch(url, {
      method,
      headers,
      body: options?.body,
      redirect: "manual"
    });

    for (const rawSetCookie of readSetCookies(response.headers)) {
      mergeCookie(session.cookies, rawSetCookie);
    }

    return {
      status: response.status,
      body: await response.text(),
      path: toPathWithQuery(response.url || url),
      location: response.headers.get("location") ?? undefined
    };
  }

  private async requestRawFollowingRedirects(
    session: SessionState,
    initialPath: string,
    options: RequestOptions,
    maxRedirects: number
  ): Promise<HttpResult> {
    let currentPath = initialPath;

    for (let i = 0; i <= maxRedirects; i++) {
      const response = await this.requestRaw(session, currentPath, options);
      if (!(response.status >= 300 && response.status < 400 && response.location)) {
        return response;
      }
      currentPath = normalizePortalPath(response.location, this.origin, this.portalPath);
    }

    throw new AppError({
      statusCode: 502,
      code: "UPSTREAM_REDIRECT_LOOP",
      message: "Too many redirects while loading Aptus login page",
      upstream: { path: currentPath }
    });
  }
}

function actionFailure(
  groupId: number,
  code: string,
  message: string,
  details?: unknown
): GroupActionResult {
  return {
    groupId,
    status: "failed",
    message,
    error: {
      code,
      message,
      details
    }
  };
}

function decodeCanonicalTarget(timeslotId: string): CanonicalTarget {
  const target = decodeTimeslotId(timeslotId);
  if (!DateTime.fromISO(target.startAt).isValid || !DateTime.fromISO(target.endAt).isValid) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_ID",
      message: "Timeslot id has invalid datetime fields"
    });
  }
  return target;
}

function startDateOfTarget(target: CanonicalTarget): string {
  const dt = DateTime.fromISO(target.startAt, { zone: STOCKHOLM_TZ });
  if (!dt.isValid) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_ID",
      message: "Timeslot start datetime is invalid",
      details: { startAt: target.startAt }
    });
  }
  return dt.toISODate()!;
}

function findMatchingSlot(slots: GroupSlot[], target: CanonicalTarget): GroupSlot | undefined {
  return slots.find((slot) => slot.startAt === target.startAt && slot.endAt === target.endAt);
}

function computeOverallStatus(
  results: GroupActionResult[],
  successStatuses: Set<string>
): "success" | "partial_success" | "failed" {
  const successCount = results.filter((result) => successStatuses.has(result.status)).length;
  if (successCount === results.length) return "success";
  if (successCount > 0) return "partial_success";
  return "failed";
}

function validateGroupIds(groupIds: number[], groups: BookingGroup[]): void {
  const available = new Set(groups.map((group) => group.id));
  const invalid = groupIds.filter((groupId) => !available.has(groupId));
  if (invalid.length) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_GROUP_IDS",
      message: "Unknown booking group ids",
      details: {
        invalid,
        available: [...available]
      }
    });
  }
}

function buildCanonicalTimeslots(
  groups: BookingGroup[],
  calendars: Array<{ groupId: number; slots: GroupSlot[] }>
): CanonicalTimeslot[] {
  const grouped = new Map<
    string,
    {
      startAt: string;
      endAt: string;
      localDate: string;
      startTime: string;
      endTime: string;
      spansMidnight: boolean;
      byGroup: Map<number, GroupSlot>;
    }
  >();

  for (const calendar of calendars) {
    for (const slot of calendar.slots) {
      const key = `${slot.startAt}|${slot.endAt}`;
      const existing = grouped.get(key);
      if (existing) {
        existing.byGroup.set(calendar.groupId, slot);
      } else {
        grouped.set(key, {
          startAt: slot.startAt,
          endAt: slot.endAt,
          localDate: slot.localDate,
          startTime: slot.startTime,
          endTime: slot.endTime,
          spansMidnight: slot.spansMidnight,
          byGroup: new Map([[calendar.groupId, slot]])
        });
      }
    }
  }

  return [...grouped.values()]
    .map((entry) => ({
      id: encodeTimeslotId(entry.startAt, entry.endAt),
      startAt: entry.startAt,
      endAt: entry.endAt,
      localDate: entry.localDate,
      startTime: entry.startTime,
      endTime: entry.endTime,
      spansMidnight: entry.spansMidnight,
      groups: groups.map((group) => {
        const slot = entry.byGroup.get(group.id);
        return {
          groupId: group.id,
          status: slot?.status ?? "unavailable",
          canBook: Boolean(slot?.bookUrl),
          canCancel: Boolean(slot?.unbookUrl)
        };
      })
    }))
    .sort((a, b) => a.startAt.localeCompare(b.startAt));
}

export function parseCategories(html: string): Array<{ id: number; name: string }> {
  const $ = load(html);
  const categories: Array<{ id: number; name: string }> = [];

  $("button.bookingNavigation").each((_index, element) => {
    const onclick = $(element).attr("onclick") ?? "";
    const match = onclick.match(/LoadLocationGroupDialog\(['"]?(\d+)['"]?\)/);
    if (!match) return;

    categories.push({
      id: Number(match[1]),
      name: normalizeWhitespace($(element).text())
    });
  });

  return dedupeBy(categories, (item) => item.id);
}

export function parseGroups(html: string): BookingGroup[] {
  const $ = load(html);
  const groups: BookingGroup[] = [];

  $("button.bookingNavigation").each((_index, element) => {
    const onclick = $(element).attr("onclick") ?? "";
    const match = onclick.match(/BookingCalendarOverview\?bookingGroupId=(\d+)/);
    if (!match) return;

    const labelCell = $(element).find("td").eq(1);
    const labelLines = extractLabelLines(labelCell.html() ?? $(element).html() ?? "");
    const fallbackName = normalizeWhitespace($(element).attr("aria-label") ?? "") || normalizeWhitespace($(element).text());

    const location = labelLines.length > 1 ? labelLines[0] : null;
    const name =
      labelLines.length > 1
        ? normalizeWhitespace(labelLines.slice(1).join(" "))
        : labelLines[0] ?? fallbackName;

    groups.push({
      id: Number(match[1]),
      location,
      name
    });
  });

  return dedupeBy(groups, (group) => group.id);
}

export function parseBookingCalendar(html: string, groupId: number, passDate: string): ParsedCalendar {
  assertISODate(passDate, "passDate");

  const $ = load(html);
  const monday = startOfWeek(passDate);
  const slots: GroupSlot[] = [];

  $(".dayColumn").each((columnIndex, element) => {
    const idAttr = $(element).find(".weekDay").first().attr("id") ?? "";
    const idMatch = idAttr.match(/weekDay_(\d+)/);
    const dayIndex = idMatch ? Number(idMatch[1]) : columnIndex;
    const dayDate = monday.plus({ days: dayIndex });

    $(element)
      .children(".interval")
      .each((_slotIndex, intervalElement) => {
        const interval = $(intervalElement);
        const intervalText = normalizeWhitespace(interval.find("> div").first().text());
        const timeRange = parseTimeRange(intervalText);
        if (!timeRange) return;

        const start = DateTime.fromISO(`${dayDate.toISODate()}T${timeRange.start}`, { zone: STOCKHOLM_TZ });
        let end = DateTime.fromISO(`${dayDate.toISODate()}T${timeRange.end}`, { zone: STOCKHOLM_TZ });
        const spansMidnight = end <= start;
        if (spansMidnight) {
          end = end.plus({ days: 1 });
        }

        const classAttr = interval.attr("class") ?? "";
        const status = classAttr.includes("own")
          ? "own"
          : classAttr.includes("bookable")
            ? "bookable"
            : "unavailable";

        const bookOnclick = interval.find("button.bookButton").attr("onclick") ?? "";
        const bookUrl = extractBookUrl(bookOnclick);
        const unbookUrl = extractCancelUrl(interval.find("script").text());

        let bookingId: number | undefined;
        if (unbookUrl) {
          const bookingMatch = unbookUrl.match(/\/Unbook\/(\d+)/);
          bookingId = bookingMatch ? Number(bookingMatch[1]) : undefined;
        }

        let passNo: number | undefined;
        let upstreamPassDate: string | undefined;
        if (bookUrl) {
          const parsed = new URL(toAbsolutePortalUrl(bookUrl, "https://dummy.local", "/AptusPortal"));
          passNo = toNumberOrUndefined(parsed.searchParams.get("passNo"));
          upstreamPassDate = parsed.searchParams.get("passDate") ?? undefined;
        }

        slots.push({
          groupId,
          startAt: start.toISO()!,
          endAt: end.toISO()!,
          localDate: dayDate.toISODate()!,
          startTime: timeRange.start,
          endTime: timeRange.end,
          spansMidnight,
          status,
          bookUrl,
          unbookUrl,
          bookingId,
          passNo,
          passDate: upstreamPassDate
        });
      });
  });

  return {
    slots: slots.sort((a, b) => a.startAt.localeCompare(b.startAt)),
    week: weekWindowForDate(passDate),
    feedback: parseFeedbackDialog(html) ?? undefined
  };
}

export function parseFeedbackDialog(html: string): string | null {
  const feedbackMatch = html.match(/FeedbackDialog\('([\s\S]*?)',\s*'[^']*',\s*'[^']*'\)/);
  if (!feedbackMatch) return null;

  const raw = feedbackMatch[1].replace(/\\'/g, "'");
  const withBreaks = raw.replace(/<br\s*\/?\s*>/gi, " ");
  const $ = load(`<div>${withBreaks}</div>`);
  return normalizeWhitespace($("div").text());
}

function parseLoginForm(html: string, path: string): LoginFormData {
  const $ = load(html);

  const form = $("form").first();
  if (!form.length) {
    throw new AppError({
      statusCode: 502,
      code: "UPSTREAM_PARSE_ERROR",
      message: "Aptus login form not found",
      upstream: { path },
      details: {
        htmlPreview: normalizeWhitespace(html).slice(0, 400)
      }
    });
  }

  const requestVerificationToken =
    form.find('input[name="__RequestVerificationToken"]').attr("value") ?? "";
  const passwordSalt = form.find('input[name="PasswordSalt"]').attr("value") ?? "";
  const actionPath = form.attr("action") ?? "/AptusPortal/Account/Login";
  const deviceType = form.find('input[name="DeviceType"]').attr("value") ?? "PC";
  const desktopSelected =
    form.find('input[name="DesktopSelected"][checked="checked"]').attr("value") ?? "true";

  if (!requestVerificationToken || !passwordSalt) {
    throw new AppError({
      statusCode: 502,
      code: "UPSTREAM_PARSE_ERROR",
      message: "Aptus login fields missing",
      upstream: { path }
    });
  }

  return {
    actionPath,
    requestVerificationToken,
    passwordSalt,
    deviceType,
    desktopSelected,
    feedback: parseFeedbackDialog(html) ?? undefined
  };
}

function extractBookUrl(onclick: string): string | undefined {
  const match = onclick.match(/DoBooking\('([^']+)'\)/);
  if (!match) return undefined;
  return decodeHtmlAmpersands(match[1]);
}

function extractCancelUrl(scriptBody: string): string | undefined {
  const match = scriptBody.match(/ConfirmCancelBooking\([^,]+,\s*'([^']+)'/);
  if (!match) return undefined;
  return decodeHtmlAmpersands(match[1]);
}

function parseTimeRange(text: string): { start: string; end: string } | null {
  const match = text.match(/^(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})$/);
  if (!match) return null;
  return { start: match[1], end: match[2] };
}

function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function extractLabelLines(html: string): string[] {
  const withLineBreaks = html.replace(/<br\s*\/?>/gi, "\n");
  const $ = load(`<div>${withLineBreaks}</div>`);
  return $("div")
    .text()
    .split("\n")
    .map(normalizeWhitespace)
    .filter(Boolean);
}

function dedupeBy<T>(items: T[], keySelector: (item: T) => string | number): T[] {
  const map = new Map<string | number, T>();
  for (const item of items) {
    map.set(keySelector(item), item);
  }
  return [...map.values()];
}

function weekWindowForDate(date: string): WeekWindow {
  const monday = startOfWeek(date);
  return {
    fromDate: monday.toISODate()!,
    toDate: monday.plus({ days: 6 }).toISODate()!,
    timezone: STOCKHOLM_TZ
  };
}

function startOfWeek(date: string): DateTime {
  const dt = DateTime.fromISO(date, { zone: STOCKHOLM_TZ });
  if (!dt.isValid) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_DATE",
      message: `Invalid date: ${date}`
    });
  }
  return dt.minus({ days: dt.weekday - 1 }).startOf("day");
}

function assertISODate(value: string, field: string): void {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_DATE",
      message: `${field} must be YYYY-MM-DD`
    });
  }

  const parsed = DateTime.fromISO(value, { zone: STOCKHOLM_TZ });
  if (!parsed.isValid) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_DATE",
      message: `${field} is invalid`
    });
  }
}

function toAbsolutePortalUrl(path: string, origin: string, portalPath: string): string {
  if (/^https?:\/\//i.test(path)) return path;

  if (path.startsWith(`${portalPath}/`)) {
    return `${origin}${path}`;
  }

  if (path.startsWith("/")) {
    return `${origin}${portalPath}${path}`;
  }

  return `${origin}${portalPath}/${path}`;
}

function normalizePortalPath(location: string, origin: string, portalPath: string): string {
  if (!location) return `${portalPath}/Account/Login`;

  const absolute = toAbsolutePortalUrl(location, origin, portalPath);
  const url = new URL(absolute);
  return `${url.pathname}${url.search}`;
}

function toPathWithQuery(urlLike: string): string {
  const url = new URL(urlLike, "https://dummy.local");
  return `${url.pathname}${url.search}`;
}

function isLoginRedirect(response: HttpResult): boolean {
  if (!(response.status >= 300 && response.status < 400)) return false;
  return (response.location ?? "").includes("/Account/Login");
}

function isAccountErrorRedirect(response: HttpResult): boolean {
  if (!(response.status >= 300 && response.status < 400)) return false;
  return (response.location ?? "").includes("/Account/Error");
}

function looksLikeSessionExpired(response: HttpResult): boolean {
  if (isLoginRedirect(response)) return true;
  if (isAccountErrorRedirect(response)) return true;
  if (response.status === 401) return true;
  if (response.status === 200 && containsLoginForm(response.body)) return true;
  return false;
}

function containsLoginForm(body: string): boolean {
  return body.includes('name="PasswordSalt"') && body.includes('name="UserName"');
}

function decodeHtmlAmpersands(input: string): string {
  return input.replaceAll("&amp;", "&");
}

function toNumberOrUndefined(input: string | null): number | undefined {
  if (input === null) return undefined;
  const value = Number(input);
  return Number.isFinite(value) ? value : undefined;
}

function serializeCookies(cookies: Map<string, string>): string {
  return [...cookies.entries()].map(([key, value]) => `${key}=${value}`).join("; ");
}

function mergeCookie(cookies: Map<string, string>, setCookieHeader: string): void {
  const [pair] = setCookieHeader.split(";");
  const index = pair.indexOf("=");
  if (index < 1) return;

  const name = pair.slice(0, index).trim();
  const value = pair.slice(index + 1).trim();
  if (!value) {
    cookies.delete(name);
  } else {
    cookies.set(name, value);
  }
}

function readSetCookies(headers: Headers): string[] {
  const dynamicHeaders = headers as Headers & { getSetCookie?: () => string[] };
  if (typeof dynamicHeaders.getSetCookie === "function") {
    return dynamicHeaders.getSetCookie();
  }

  const single = headers.get("set-cookie");
  if (!single) return [];
  return single.split(/,(?=[^\s;,]+=)/g);
}
