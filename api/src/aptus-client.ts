import { load } from "cheerio";
import { createHash } from "node:crypto";
import { DateTime } from "luxon";
import { AppError, asError } from "./errors.js";
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

interface LoggerLike {
  debug?: (obj: Record<string, unknown>, msg?: string) => void;
  info?: (obj: Record<string, unknown>, msg?: string) => void;
  warn?: (obj: Record<string, unknown>, msg?: string) => void;
  error?: (obj: Record<string, unknown>, msg?: string) => void;
}

interface LogContext {
  requestId?: string;
  objectKey: string;
  operation: "list_timeslots" | "book_timeslot" | "cancel_timeslot";
}

export class AptusClient {
  private readonly origin: string;
  private readonly portalPath = "/AptusPortal";
  private readonly userAgent: string;
  private readonly logger?: LoggerLike;
  private readonly sessions = new Map<string, SessionState>();

  constructor(args?: { baseUrl?: string; userAgent?: string; logger?: LoggerLike }) {
    this.origin = (args?.baseUrl ?? "https://sssb.aptustotal.se").replace(/\/$/, "");
    this.userAgent =
      args?.userAgent ??
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:151.0) Gecko/20100101 Firefox/151.0";
    this.logger = args?.logger;
  }

  async listTimeslots(objectId: string, date: string, requestId?: string): Promise<TimeslotsResponse> {
    assertISODate(date, "date");
    const context = this.buildLogContext(objectId, "list_timeslots", requestId);
    this.log("info", context, { date }, "Listing Aptus timeslots");

    const { groups } = await this.getLaundryGroups(objectId, context);
    const calendars: Array<{ groupId: number; parsed: ParsedCalendar }> = [];
    for (const group of groups) {
      calendars.push({
        groupId: group.id,
        parsed: await this.fetchCalendar(objectId, group.id, date, context)
      });
    }

    const week = calendars[0]?.parsed.week ?? weekWindowForDate(date);
    const timeslots = buildCanonicalTimeslots(groups, calendars.map((c) => ({ groupId: c.groupId, slots: c.parsed.slots })));
    this.log(
      "info",
      context,
      { date, groups: groups.length, timeslots: timeslots.length, week },
      "Listed Aptus timeslots"
    );

    return { week, groups, timeslots };
  }

  async bookTimeslot(objectId: string, timeslotId: string, groupIds: number[], requestId?: string): Promise<ActionResponse> {
    const context = this.buildLogContext(objectId, "book_timeslot", requestId);
    const target = decodeCanonicalTarget(timeslotId);
    const passDate = startDateOfTarget(target);
    this.log("info", context, { timeslotId, groupIds, passDate }, "Booking Aptus timeslot");

    const { groups } = await this.getLaundryGroups(objectId, context);
    validateGroupIds(groupIds, groups);

    const results: GroupActionResult[] = [];
    for (const groupId of groupIds) {
      results.push(await this.bookForGroup(objectId, groupId, passDate, target, context));
    }

    const response: ActionResponse = {
      timeslotId,
      results,
      overallStatus: computeOverallStatus(results, new Set(["booked", "already_booked"]))
    };
    this.log("info", context, { timeslotId, groupIds, overallStatus: response.overallStatus }, "Booked Aptus timeslot");
    return response;
  }

  async cancelTimeslot(
    objectId: string,
    timeslotId: string,
    groupIds: number[],
    requestId?: string
  ): Promise<ActionResponse> {
    const context = this.buildLogContext(objectId, "cancel_timeslot", requestId);
    const target = decodeCanonicalTarget(timeslotId);
    const passDate = startDateOfTarget(target);
    this.log("info", context, { timeslotId, groupIds, passDate }, "Cancelling Aptus timeslot");

    const { groups } = await this.getLaundryGroups(objectId, context);
    validateGroupIds(groupIds, groups);

    const results: GroupActionResult[] = [];
    for (const groupId of groupIds) {
      results.push(await this.cancelForGroup(objectId, groupId, passDate, target, context));
    }

    const response: ActionResponse = {
      timeslotId,
      results,
      overallStatus: computeOverallStatus(results, new Set(["cancelled", "not_booked"]))
    };
    this.log(
      "info",
      context,
      { timeslotId, groupIds, overallStatus: response.overallStatus },
      "Cancelled Aptus timeslot"
    );
    return response;
  }

  private async getLaundryGroups(objectId: string, context: LogContext): Promise<{ groups: BookingGroup[] }> {
    const categoriesRes = await this.requestDialogPage(objectId, "/CustomerBooking/CustomerCategories", context);

    const categories = parseCategories(categoriesRes.body);
    if (!categories.length) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_PARSE_ERROR",
        message: "No Aptus categories found",
        upstream: { path: categoriesRes.path, status: categoriesRes.status },
        details: {
          htmlPreview: normalizeWhitespace(categoriesRes.body).slice(0, 400)
        }
      });
    }

    const category = categories[0];
    const groupsRes = await this.requestDialogPage(
      objectId,
      `/CustomerBooking/CustomerLocationGroups?categoryId=${category.id}`,
      context
    );

    const groups = parseGroups(groupsRes.body);
    if (!groups.length) {
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_PARSE_ERROR",
        message: "No Aptus booking groups found",
        upstream: { path: groupsRes.path, status: groupsRes.status },
        details: {
          categoryId: category.id,
          htmlPreview: normalizeWhitespace(groupsRes.body).slice(0, 400)
        }
      });
    }

    return { groups };
  }

  private async requestDialogPage(objectId: string, path: string, context: LogContext): Promise<HttpResult> {
    try {
      const withXRequestedWith = await this.requestWithAuth(objectId, path, context, {
        refererPath: "/CustomerBooking",
        xRequestedWith: true
      });
      if (withXRequestedWith.body.trim()) return withXRequestedWith;
      this.log(
        "warn",
        context,
        { path, reason: "EMPTY_BODY" },
        "Aptus dialog response was empty with X-Requested-With, retrying without it"
      );
    } catch (error) {
      if (!(error instanceof AppError) || error.code !== "UPSTREAM_ACCOUNT_ERROR") {
        throw error;
      }
      this.log(
        "warn",
        context,
        { path, reason: error.code },
        "Aptus dialog request rejected with X-Requested-With, retrying without it"
      );
    }

    return this.requestWithAuth(objectId, path, context, {
      refererPath: "/CustomerBooking"
    });
  }

  private async fetchCalendar(objectId: string, groupId: number, passDate: string, context: LogContext): Promise<ParsedCalendar> {
    const path = `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`;
    const response = await this.requestWithAuth(objectId, path, context, {
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
    target: CanonicalTarget,
    context: LogContext
  ): Promise<GroupActionResult> {
    const before = await this.fetchCalendar(objectId, groupId, passDate, context);
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

    await this.requestWithAuth(objectId, slot.bookUrl, context, {
      refererPath: `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`
    });

    const after = await this.fetchCalendar(objectId, groupId, passDate, context);
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
    target: CanonicalTarget,
    context: LogContext
  ): Promise<GroupActionResult> {
    const before = await this.fetchCalendar(objectId, groupId, passDate, context);
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

    await this.requestWithAuth(objectId, slot.unbookUrl, context, {
      refererPath: `/CustomerBooking/BookingCalendar?bookingGroupId=${groupId}&passDate=${passDate}`
    });

    const after = await this.fetchCalendar(objectId, groupId, passDate, context);
    const updated = findMatchingSlot(after.slots, target);
    if (!updated || updated.status !== "own") {
      return { groupId, status: "cancelled", message: after.feedback ?? "Cancelled" };
    }

    return actionFailure(groupId, "CANCEL_FAILED", after.feedback ?? "Cancellation did not succeed", {
      feedback: after.feedback,
      target
    });
  }

  private async requestWithAuth(
    objectId: string,
    path: string,
    context: LogContext,
    options?: RequestOptions
  ): Promise<HttpResult> {
    await this.ensureAuthenticated(objectId, context);

    let session = this.sessions.get(objectId)!;
    let response = await this.requestRaw(session, path, options, context);

    if (looksLikeSessionExpired(response)) {
      this.log(
        "info",
        context,
        {
          path: response.path,
          status: response.status,
          location: response.location
        },
        "Aptus session appears expired, reauthenticating"
      );
      this.sessions.delete(objectId);
      const loginLocation = isLoginRedirect(response) && response.location
        ? response.location
        : "/AptusPortal/Account/Login";
      await this.login(objectId, loginLocation, context);
      session = this.sessions.get(objectId)!;
      response = await this.requestRaw(session, path, options, context);
    }

    if (isLoginRedirect(response) || response.status === 401) {
      this.log(
        "warn",
        context,
        {
          path: response.path,
          status: response.status,
          location: response.location
        },
        "Aptus authentication failed after retry"
      );
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
      this.log(
        "warn",
        context,
        {
          path: response.path,
          status: response.status,
          location: response.location
        },
        "Aptus returned Account/Error redirect"
      );
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

  private async ensureAuthenticated(objectId: string, context: LogContext): Promise<void> {
    if (this.sessions.has(objectId)) return;
    this.log("info", context, {}, "Aptus session missing, performing login");
    await this.login(objectId, "/AptusPortal/Account/Login", context);
  }

  private async login(objectId: string, loginLocation: string, context: LogContext): Promise<void> {
    const session: SessionState = { cookies: new Map(), authenticatedAt: Date.now() };

    const loginPath = normalizePortalPath(loginLocation, this.origin, this.portalPath);
    this.log("info", context, { loginPath }, "Logging into Aptus");
    const loginPage = await this.requestRawFollowingRedirects(session, loginPath, {}, 8, context);
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

    const post = await this.requestRaw(
      session,
      postPath,
      {
        method: "POST",
        body: payload.toString(),
        refererPath: loginPath,
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Origin: this.origin
        }
      },
      context
    );

    if (!session.cookies.has(".ASPXAUTH")) {
      const feedback = parseFeedbackDialog(post.body) ?? form.feedback;
      this.log(
        "warn",
        context,
        {
          path: post.path,
          status: post.status,
          location: post.location,
          feedback
        },
        "Aptus login did not yield .ASPXAUTH cookie"
      );
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
    this.log("info", context, { authAgeMs: 0 }, "Aptus login successful");
  }

  private async requestRaw(
    session: SessionState,
    path: string,
    options?: RequestOptions,
    context?: LogContext
  ): Promise<HttpResult> {
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

    const start = Date.now();
    let response: Response;
    try {
      response = await fetch(url, {
        method,
        headers,
        body: options?.body,
        redirect: "manual"
      });
    } catch (error) {
      const known = asError(error);
      this.log(
        "error",
        context,
        {
          path: toPathWithQuery(url),
          method,
          message: known.message
        },
        "Aptus upstream request failed"
      );
      throw new AppError({
        statusCode: 502,
        code: "UPSTREAM_NETWORK_ERROR",
        message: "Failed to reach Aptus upstream",
        upstream: { path: toPathWithQuery(url) },
        details: { reason: known.message }
      });
    }

    for (const rawSetCookie of readSetCookies(response.headers)) {
      mergeCookie(session.cookies, rawSetCookie);
    }

    const result = {
      status: response.status,
      body: await response.text(),
      path: toPathWithQuery(response.url || url),
      location: response.headers.get("location") ?? undefined
    };
    this.log(
      "debug",
      context,
      {
        path: result.path,
        status: result.status,
        location: result.location,
        method,
        durationMs: Date.now() - start
      },
      "Aptus upstream response"
    );
    return result;
  }

  private async requestRawFollowingRedirects(
    session: SessionState,
    initialPath: string,
    options: RequestOptions,
    maxRedirects: number,
    context?: LogContext
  ): Promise<HttpResult> {
    let currentPath = initialPath;

    for (let i = 0; i <= maxRedirects; i++) {
      const response = await this.requestRaw(session, currentPath, options, context);
      if (!(response.status >= 300 && response.status < 400 && response.location)) {
        return response;
      }
      this.log(
        "debug",
        context,
        {
          fromPath: response.path,
          location: response.location,
          status: response.status
        },
        "Following Aptus redirect"
      );
      currentPath = normalizePortalPath(response.location, this.origin, this.portalPath);
    }

    throw new AppError({
      statusCode: 502,
      code: "UPSTREAM_REDIRECT_LOOP",
      message: "Too many redirects while loading Aptus login page",
      upstream: { path: currentPath }
    });
  }

  private buildLogContext(
    objectId: string,
    operation: LogContext["operation"],
    requestId?: string
  ): LogContext {
    return {
      requestId,
      objectKey: hashObjectId(objectId),
      operation
    };
  }

  private log(
    level: "debug" | "info" | "warn" | "error",
    context: LogContext | undefined,
    data: Record<string, unknown>,
    message: string
  ): void {
    const logger = this.logger;
    if (!logger) return;

    const payload: Record<string, unknown> = { ...data };
    if (context) {
      payload.operation = context.operation;
      payload.objectKey = context.objectKey;
      if (context.requestId) payload.reqId = context.requestId;
    }
    switch (level) {
      case "debug":
        logger.debug?.(payload, message);
        break;
      case "info":
        logger.info?.(payload, message);
        break;
      case "warn":
        logger.warn?.(payload, message);
        break;
      case "error":
        logger.error?.(payload, message);
        break;
    }
  }
}

function hashObjectId(objectId: string): string {
  return createHash("sha256").update(objectId).digest("hex").slice(0, 12);
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
    const button = $(element);
    const onclick = button.attr("onclick") ?? "";
    const id =
      extractFirstNumberFromFunctionCall(onclick, "LoadLocationGroupDialog") ??
      extractFirstNumberFromText(button.attr("data-category-id") ?? "") ??
      extractFirstNumberFromText(button.find("a").attr("href") ?? "");
    if (!id) return;

    categories.push({
      id,
      name: normalizeWhitespace(button.text())
    });
  });

  return dedupeBy(categories, (item) => item.id);
}

export function parseGroups(html: string): BookingGroup[] {
  const $ = load(html);
  const groups: BookingGroup[] = [];

  $("button.bookingNavigation").each((_index, element) => {
    const button = $(element);
    const id =
      extractGroupIdFromText(button.attr("onclick") ?? "") ??
      extractGroupIdFromText(button.attr("data-url") ?? "") ??
      extractGroupIdFromText(button.attr("href") ?? "") ??
      extractGroupIdFromText(button.find("a").attr("href") ?? "") ??
      extractFirstNumberFromText(button.attr("data-booking-group-id") ?? "");
    if (!id) return;

    const labelCell = button.find("td").eq(1);
    const labelLines = extractLabelLines(labelCell.html() ?? button.html() ?? "");
    const fallbackName = normalizeWhitespace(button.attr("aria-label") ?? "") || normalizeWhitespace(button.text());

    const location = labelLines.length > 1 ? labelLines[0] : null;
    const name =
      labelLines.length > 1
        ? normalizeWhitespace(labelLines.slice(1).join(" "))
        : labelLines[0] ?? fallbackName;

    groups.push({
      id,
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

function extractGroupIdFromText(input: string): number | undefined {
  const match = input.match(/bookingGroupId=(\d+)/i);
  if (match) return Number(match[1]);

  const overviewMatch = input.match(/BookingCalendarOverview[^0-9]*(\d+)/i);
  if (overviewMatch) return Number(overviewMatch[1]);

  return undefined;
}

function extractFirstNumberFromFunctionCall(input: string, name: string): number | undefined {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const callMatch = input.match(new RegExp(`${escapedName}\\(([^)]*)\\)`, "i"));
  if (!callMatch) return undefined;
  return extractFirstNumberFromText(callMatch[1]);
}

function extractFirstNumberFromText(input: string): number | undefined {
  const match = input.match(/\d+/);
  if (!match) return undefined;
  return Number(match[0]);
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
  if ((response.location ?? "").includes("/Account/Login")) return true;
  // Aptus may omit the Location header on AJAX (X-Requested-With) redirects
  // and only embed the destination in the "Object moved" HTML body.
  return /href="[^"]*\/Account\/Login/i.test(response.body);
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
