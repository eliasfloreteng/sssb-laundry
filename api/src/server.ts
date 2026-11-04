import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import fastifyStatic from "@fastify/static";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { AppError, asError } from "./errors.js";
import { AndroidReleases } from "./android-release.js";
import { AptusClient } from "./aptus-client.js";
import type { PushEnvironment, PushPlatform } from "./db.js";
import { createDemoBackend, isDemoObjectId } from "./demo.js";
import { createDibsService, PRIORITY_LIMIT, type DibsService } from "./dibs.js";
import { createFeedbackService, FEEDBACK_MAX_LENGTH, type FeedbackContext, type FeedbackService } from "./feedback.js";
import { createPushService, type PushService } from "./notifications.js";
import { decodeTimeslotId } from "./timeslot-id.js";
import { createUpstreamCheck, type UpstreamCheck } from "./upstream-check.js";

interface TimeslotsQuery {
  date?: string;
}

interface ActionBody {
  groupIds?: unknown;
}

interface TimeslotParams {
  timeslotId: string;
}

interface DeviceBody {
  /** "ios" (the default, so older iPhone builds need not send it) or "android". */
  platform?: unknown;
  deviceToken?: unknown;
  /** APNs only. */
  environment?: unknown;
  enabled?: unknown;
  alertMinutes?: unknown;
  secondAlertMinutes?: unknown;
  /** Absent from builds older than the field — they know only the original titles. */
  pushVersion?: unknown;
}

interface FeedbackBody {
  message?: unknown;
  context?: unknown;
}

/**
 * What a route reaches for on the caller's behalf. Live, that is Aptus and the
 * services around it; for the demo object number it is `demo.ts`, in memory.
 */
export interface Backend {
  aptus: Pick<AptusClient, "listTimeslots" | "bookTimeslot" | "cancelTimeslot">;
  push: Pick<PushService, "supports" | "registerDevice" | "unregisterDevice" | "enqueueTestNotification" | "onBooked" | "onCancelled"> | null;
  dibs: Pick<DibsService, "call" | "drop" | "dropAll" | "setPriority" | "annotate" | "onReleased"> | null;
  feedback: Pick<FeedbackService, "submit"> | null;
}

export interface LaundryServer extends FastifyInstance {
  /** Present only when push is configured; started by startServer(), never by tests. */
  push: PushService | null;
  /** Present only alongside push; started by startServer(), never by tests. */
  dibs: DibsService | null;
  /** The upstream probe behind `/status`; started by startServer(), never by tests. */
  upstream: UpstreamCheck;
}

export function buildServer(args?: {
  aptusClient?: AptusClient;
  pushService?: PushService | null;
  dibsService?: DibsService | null;
  feedbackService?: FeedbackService | null;
  upstreamCheck?: UpstreamCheck;
  demoBackend?: Backend;
  androidReleases?: AndroidReleases;
}): LaundryServer {
  const logLevel = process.env.LOG_LEVEL ?? "info";
  const app = Fastify({
    logger: { level: logLevel },
    routerOptions: {
      maxParamLength: 256
    }
  });
  const aptus = args?.aptusClient ?? new AptusClient({ logger: app.log });
  // Built here so it shares the Aptus session cache and the request logger, but
  // its timers are only started by startServer() — tests must stay timer-free.
  const push = args?.pushService !== undefined ? args.pushService : createPushService(aptus, app.log);
  const dibs = args?.dibsService !== undefined ? args.dibsService : createDibsService(push, aptus, app.log);
  const upstream = args?.upstreamCheck ?? createUpstreamCheck(aptus, app.log);
  const androidReleases = args?.androidReleases ?? new AndroidReleases({ logger: app.log });
  const feedback = args?.feedbackService !== undefined ? args.feedbackService : createFeedbackService(app.log);
  const live: Backend = { aptus, push, dibs, feedback };
  // Store reviewers sign in with the demo object number, and are served from
  // memory instead: nothing of theirs reaches Aptus, the database or APNs.
  const demo = args?.demoBackend ?? createDemoBackend({ feedback, logger: app.log });

  /** The caller's object id, and the backend that serves it. Every route asks here. */
  const caller = (request: FastifyRequest): { objectId: string; backend: Backend } => {
    const objectId = requireObjectId(request);
    return { objectId, backend: isDemoObjectId(objectId) ? demo : live };
  };

  // The app's landing page, on the same host the app already talks to. `site/`
  // is a flat folder of static files; every route below is registered
  // explicitly and so wins over the wildcard @fastify/static installs.
  app.register(fastifyStatic, {
    root: fileURLToPath(new URL("../site", import.meta.url))
  });

  // Liveness only, and deliberately blind to Aptus: this is what the container
  // healthcheck runs, and a portal outage is not a reason to call this process
  // sick. Upstream health is `/status`, on its own monitor.
  app.get("/health", async () => ({ ok: true }));

  // Is the thing this API wraps still answering? The body is the last probe's
  // result — `/status` never reaches upstream itself, so it is safe to poll and
  // safe to leave public. `503` is the signal a monitor acts on.
  app.get("/status", async (_request, reply) => {
    const snapshot = upstream.snapshot();
    reply.code(snapshot.ok ? 200 : 503);
    return { ok: snapshot.ok, upstream: snapshot };
  });

  // Universal links. iOS fetches this from `/.well-known/` and nowhere else, and
  // insists on `application/json` — which the static plugin cannot give an
  // extensionless file, so the route is explicit and sets the type itself.
  app.get("/.well-known/apple-app-site-association", async (_request, reply) => {
    reply.type("application/json");
    return APP_SITE_ASSOCIATION;
  });

  // App Links, Android's universal links: the certificates allowed to open
  // `/invite`. Android only looks under `/.well-known/`, and the static plugin
  // will not serve a dot-folder, so this too is a route of its own.
  app.get("/.well-known/assetlinks.json", async (_request, reply) => {
    reply.type("application/json");
    return ASSET_LINKS;
  });

  // The privacy policy both stores link to.
  app.get("/privacy", (_request, reply) => {
    reply.sendFile("privacy.html");
  });

  // How to join the Android test on Google Play.
  app.get("/android", (_request, reply) => {
    reply.sendFile("android.html");
  });

  // The APK of the newest release: Play's universal APK, which android-release.yml
  // attaches to every release, so it is signed like the Play build. GitHub's own
  // "latest" link is only the fallback, as it 404s while a new release still waits
  // for its APK.
  app.get("/android/download", async (_request, reply) => {
    const release = await androidReleases.latest();
    return reply.redirect(release?.apkUrl ?? ANDROID_APK_URL);
  });

  // What an APK install compares itself with to offer an update. Public, like the
  // download: it says nothing about anyone.
  app.get("/android/latest", async (_request, reply) => {
    const release = await androidReleases.latest();
    if (!release) {
      throw new AppError({ statusCode: 503, code: "NO_RELEASE", message: "No Android release is available" });
    }
    reply.header("cache-control", "public, max-age=300");
    return { versionCode: release.versionCode, versionName: release.versionName };
  });

  // An invite. Reached only when the app is *not* installed — with it, iOS opens
  // the app on this URL instead of loading anything. The object number is in the
  // fragment, so it never arrives here and never reaches the log; the page reads
  // it in the browser.
  app.get("/invite", (_request, reply) => {
    reply.sendFile("invite.html");
  });

  app.get<{ Querystring: TimeslotsQuery }>("/timeslots", async (request) => {
    const { objectId, backend } = caller(request);
    const date = request.query.date;
    if (!date) {
      throw new AppError({
        statusCode: 400,
        code: "MISSING_DATE",
        message: "Query parameter 'date' is required (YYYY-MM-DD)"
      });
    }

    const response = await backend.aptus.listTimeslots(objectId, date, request.id);
    return backend.dibs ? backend.dibs.annotate(objectId, response) : response;
  });

  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/book", async (request) => {
    const { objectId, backend } = caller(request);
    const groupIds = parseGroupIds(request.body.groupIds);
    const response = await backend.aptus.bookTimeslot(objectId, request.params.timeslotId, groupIds, request.id);

    if (backend.push) {
      const booked = succeededGroupIds(response.results, BOOK_SUCCESS);
      if (booked.length > 0) {
        const { startAt, endAt } = decodeTimeslotId(request.params.timeslotId);
        // The device that booked is recorded so the "new booking" push skips it.
        backend.push.onBooked(objectId, startAt, endAt, booked, deviceToken(request));
      }
    }

    return response;
  });

  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/cancel", async (request) => {
    const { objectId, backend } = caller(request);
    const groupIds = parseGroupIds(request.body.groupIds);
    const response = await backend.aptus.cancelTimeslot(objectId, request.params.timeslotId, groupIds, request.id);

    if (backend.push) {
      const cancelled = succeededGroupIds(response.results, CANCEL_SUCCESS);
      if (cancelled.length > 0) {
        const { startAt } = decodeTimeslotId(request.params.timeslotId);
        backend.push.onCancelled(objectId, startAt, cancelled);
      }
    }

    // Whoever is waiting on a slot this app just released gets it now.
    const released = succeededGroupIds(response.results, new Set(["cancelled"]));
    if (backend.dibs && released.length > 0) {
      const { startAt, endAt } = decodeTimeslotId(request.params.timeslotId);
      backend.dibs.onReleased(startAt, endAt, released);
    }

    return response;
  });

  // Dibs: a place in line for a timeslot somebody else holds, booked by the
  // server the moment it frees. See `dibs.ts`.
  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/dibs", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.dibs) throw pushDisabled();
    const groupIds = parseGroupIds(request.body?.groupIds);
    const rows = await backend.dibs.call(objectId, request.params.timeslotId, groupIds, deviceToken(request), request.id);
    return { timeslotId: request.params.timeslotId, groupIds: rows.map((r) => r.groupId) };
  });

  app.delete<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/dibs", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.dibs) throw pushDisabled();
    const groupIds = parseGroupIds(request.body?.groupIds);
    backend.dibs.drop(objectId, request.params.timeslotId, groupIds);
    return { ok: true };
  });

  // The order the caller wants their dibs and bookings in, most wanted first.
  app.put<{ Body: { timeslotIds?: unknown } }>("/dibs/priority", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.dibs) throw pushDisabled();
    backend.dibs.setPriority(objectId, parseTimeslotIds(request.body?.timeslotIds));
    return { ok: true };
  });

  // Every dibs and the order with them — the app's dibs setting was turned off.
  app.delete("/dibs", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.dibs) throw pushDisabled();
    backend.dibs.dropAll(objectId);
    return { ok: true };
  });

  app.put<{ Body: DeviceBody }>("/notifications/device", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.push) throw pushDisabled();
    const body = request.body ?? {};
    const platform = parsePlatform(body.platform);
    if (!backend.push.supports(platform)) throw pushDisabled();
    backend.push.registerDevice({
      token: parseDeviceToken(body.deviceToken, platform),
      objectId,
      platform,
      // Android has no sandbox: FCM decides from the token alone.
      environment: platform === "android" ? "production" : parseEnvironment(body.environment),
      enabled: body.enabled !== false,
      alertMinutes: parseAlertMinutes(body.alertMinutes, "alertMinutes"),
      secondAlertMinutes: parseAlertMinutes(body.secondAlertMinutes, "secondAlertMinutes"),
      // Lenient on purpose: a value this server does not understand must not
      // cost the device its reminders. It only falls back to the oldest titles.
      pushVersion: Number.isInteger(body.pushVersion) && (body.pushVersion as number) > 0 ? (body.pushVersion as number) : 0
    });
    return { ok: true };
  });

  app.delete<{ Body: DeviceBody }>("/notifications/device", async (request) => {
    const { backend } = caller(request);
    if (!backend.push) throw pushDisabled();
    const body = request.body ?? {};
    backend.push.unregisterDevice(parseDeviceToken(body.deviceToken, parsePlatform(body.platform)));
    return { ok: true };
  });

  // Feedback from inside the app, forwarded to the developer with the object id
  // it came from. Requiring it also keeps this from being an open relay.
  app.post<{ Body: FeedbackBody }>("/feedback", async (request) => {
    const { objectId, backend } = caller(request);
    if (!backend.feedback) {
      throw new AppError({
        statusCode: 503,
        code: "FEEDBACK_DISABLED",
        message: "Feedback is not configured on this server"
      });
    }
    const body = request.body ?? {};
    await backend.feedback.submit(objectId, parseFeedbackMessage(body.message), parseFeedbackContext(body.context));
    return { ok: true };
  });

  if (process.env.NODE_ENV !== "production") {
    app.post("/notifications/test", async (request) => {
      const { objectId, backend } = caller(request);
      if (!backend.push) throw pushDisabled();
      return { ok: true, devices: backend.push.enqueueTestNotification(objectId) };
    });
  }

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof AppError) {
      app.log.warn(
        {
          err: error,
          reqId: request.id,
          method: request.method,
          url: request.url,
          code: error.code,
          details: error.details,
          upstream: error.upstream
        },
        "Handled application error"
      );
      reply.code(error.statusCode).send({
        error: {
          code: error.code,
          message: error.message,
          details: error.details,
          upstream: error.upstream
        }
      });
      return;
    }

    const known = asError(error);
    app.log.error(
      {
        err: known,
        reqId: request.id,
        method: request.method,
        url: request.url
      },
      "Unhandled error"
    );
    reply.code(500).send({
      error: {
        code: "UNKNOWN_ERROR",
        message: known.message || "Unknown error"
      }
    });
  });

  const server = Object.assign(app, { push, dibs, upstream }) as unknown as LaundryServer;
  return server;
}

/** Served verbatim under `/.well-known/`; the app's half is the `applinks:` entitlement. */
const APP_SITE_ASSOCIATION = readFileSync(
  fileURLToPath(new URL("../site/apple-app-site-association", import.meta.url)),
  "utf8"
);

/**
 * Served verbatim under `/.well-known/`. Lists the upload key, which signs builds
 * installed outside Play, and Play's app signing key, which signs every install
 * from the store; both come from Play Console under App integrity.
 */
const ANDROID_APK_URL = "https://github.com/eliasfloreteng/sssb-laundry/releases/latest/download/sssb-laundry.apk";
const ASSET_LINKS = readFileSync(fileURLToPath(new URL("../site/assetlinks.json", import.meta.url)), "utf8");

/** Per-group statuses that count as a real state change worth notifying about. */
const BOOK_SUCCESS = new Set(["booked"]);
const CANCEL_SUCCESS = new Set(["cancelled", "not_booked"]);

function succeededGroupIds(
  results: { groupId: number; status: string }[],
  accepted: Set<string>
): number[] {
  return results.filter((r) => accepted.has(r.status)).map((r) => r.groupId);
}

/** APNs tokens are 32 bytes of hex; FCM registration tokens are long, opaque and URL-safe. */
const APNS_TOKEN = /^[0-9a-fA-F]{64}$/;
const FCM_TOKEN = /^[A-Za-z0-9_:-]{100,4096}$/;

/**
 * Optional: the app identifies its push token so it can be skipped on
 * announcements. Either kind is accepted; an APNs one is stored lowercase.
 */
function deviceToken(request: FastifyRequest): string | null {
  const raw = request.headers["x-device-token"];
  if (typeof raw !== "string") return null;
  const token = raw.trim();
  if (APNS_TOKEN.test(token)) return token.toLowerCase();
  return FCM_TOKEN.test(token) ? token : null;
}

function parsePlatform(value: unknown): PushPlatform {
  if (value === undefined || value === null || value === "ios") return "ios";
  if (value === "android") return "android";
  throw new AppError({
    statusCode: 400,
    code: "INVALID_PLATFORM",
    message: "platform must be 'ios' or 'android'"
  });
}

function pushDisabled(): AppError {
  return new AppError({
    statusCode: 503,
    code: "PUSH_DISABLED",
    message: "Push notifications are not configured on this server"
  });
}

function parseDeviceToken(value: unknown, platform: PushPlatform): string {
  const token = typeof value === "string" ? value.trim() : "";
  if (platform === "android") {
    if (FCM_TOKEN.test(token)) return token;
    throw new AppError({
      statusCode: 400,
      code: "INVALID_DEVICE_TOKEN",
      message: "deviceToken must be an FCM registration token"
    });
  }
  if (APNS_TOKEN.test(token)) return token.toLowerCase();
  throw new AppError({
    statusCode: 400,
    code: "INVALID_DEVICE_TOKEN",
    message: "deviceToken must be a 64-character hex APNs token"
  });
}

function parseEnvironment(value: unknown): PushEnvironment {
  if (value === "sandbox" || value === "production") return value;
  throw new AppError({
    statusCode: 400,
    code: "INVALID_ENVIRONMENT",
    message: "environment must be 'sandbox' or 'production'"
  });
}

/** Minutes before the timeslot start; null/absent means that alert is off. */
function parseAlertMinutes(value: unknown, field: string): number | null {
  if (value === null || value === undefined) return null;
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < 0 || numeric > 40320) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_ALERT_MINUTES",
      message: `${field} must be an integer between 0 and 40320, or null`
    });
  }
  return numeric;
}

function requireObjectId(request: FastifyRequest): string {
  const objectId = request.headers["x-object-id"];
  if (typeof objectId !== "string" || !objectId.trim()) {
    throw new AppError({
      statusCode: 400,
      code: "MISSING_OBJECT_ID",
      message: "Header 'X-Object-Id' is required"
    });
  }
  return objectId.trim();
}

function parseFeedbackMessage(value: unknown): string {
  const message = typeof value === "string" ? value.trim() : "";
  if (!message || message.length > FEEDBACK_MAX_LENGTH) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_FEEDBACK",
      message: `message must be a non-empty string of at most ${FEEDBACK_MAX_LENGTH} characters`
    });
  }
  return message;
}

/** Lenient: context only helps read the message, so a bad field is dropped, not refused. */
function parseFeedbackContext(value: unknown): FeedbackContext {
  if (typeof value !== "object" || value === null) return {};
  const raw = value as Record<string, unknown>;
  const field = (key: keyof FeedbackContext) => {
    const v = raw[key];
    return typeof v === "string" && v.trim() ? v.trim().slice(0, 100) : undefined;
  };
  return {
    appVersion: field("appVersion"),
    osVersion: field("osVersion"),
    device: field("device"),
    locale: field("locale"),
    laundryRoom: field("laundryRoom")
  };
}

function parseTimeslotIds(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > PRIORITY_LIMIT || !value.every((id) => typeof id === "string")) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_IDS",
      message: `Body must contain timeslotIds as an array of at most ${PRIORITY_LIMIT} timeslot ids`
    });
  }
  return value;
}

function parseGroupIds(value: unknown): number[] {
  if (!Array.isArray(value)) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_GROUP_IDS",
      message: "Body must contain groupIds as an array with 1-2 numbers"
    });
  }

  if (value.length < 1 || value.length > 2) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_GROUP_IDS",
      message: "groupIds must contain 1-2 group ids"
    });
  }

  const parsed: number[] = [];
  for (const raw of value) {
    const numeric = Number(raw);
    if (!Number.isInteger(numeric) || numeric < 1) {
      throw new AppError({
        statusCode: 400,
        code: "INVALID_GROUP_IDS",
        message: "Each group id must be a positive integer"
      });
    }
    parsed.push(numeric);
  }

  const unique = [...new Set(parsed)];
  if (unique.length !== parsed.length) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_GROUP_IDS",
      message: "groupIds must be unique"
    });
  }

  return unique;
}

export async function startServer(): Promise<void> {
  const app = buildServer();
  app.push?.start();
  app.dibs?.start();
  app.upstream.start();

  const port = Number(process.env.PORT ?? 3000);
  const host = process.env.HOST ?? "0.0.0.0";
  await app.listen({ host, port });

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.once(signal, () => {
      app.push?.stop();
      app.dibs?.stop();
      app.upstream.stop();
      void app.close().then(() => process.exit(0));
    });
  }
}
