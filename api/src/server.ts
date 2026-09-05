import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import fastifyStatic from "@fastify/static";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { AppError, asError } from "./errors.js";
import { AptusClient } from "./aptus-client.js";
import type { PushEnvironment } from "./db.js";
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
  deviceToken?: unknown;
  environment?: unknown;
  enabled?: unknown;
  alertMinutes?: unknown;
  secondAlertMinutes?: unknown;
}

export interface LaundryServer extends FastifyInstance {
  /** Present only when push is configured; started by startServer(), never by tests. */
  push: PushService | null;
  /** The upstream probe behind `/status`; started by startServer(), never by tests. */
  upstream: UpstreamCheck;
}

export function buildServer(args?: {
  aptusClient?: AptusClient;
  pushService?: PushService | null;
  upstreamCheck?: UpstreamCheck;
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
  const upstream = args?.upstreamCheck ?? createUpstreamCheck(aptus, app.log);

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

  // An invite. Reached only when the app is *not* installed — with it, iOS opens
  // the app on this URL instead of loading anything. The object number is in the
  // fragment, so it never arrives here and never reaches the log; the page reads
  // it in the browser.
  app.get("/invite", (_request, reply) => {
    reply.sendFile("invite.html");
  });

  app.get<{ Querystring: TimeslotsQuery }>("/timeslots", async (request) => {
    const objectId = requireObjectId(request);
    const date = request.query.date;
    if (!date) {
      throw new AppError({
        statusCode: 400,
        code: "MISSING_DATE",
        message: "Query parameter 'date' is required (YYYY-MM-DD)"
      });
    }

    return aptus.listTimeslots(objectId, date, request.id);
  });

  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/book", async (request) => {
    const objectId = requireObjectId(request);
    const groupIds = parseGroupIds(request.body.groupIds);
    const response = await aptus.bookTimeslot(objectId, request.params.timeslotId, groupIds, request.id);

    if (push) {
      const booked = succeededGroupIds(response.results, BOOK_SUCCESS);
      if (booked.length > 0) {
        const { startAt, endAt } = decodeTimeslotId(request.params.timeslotId);
        // The device that booked is recorded so the "new booking" push skips it.
        push.onBooked(objectId, startAt, endAt, booked, deviceToken(request));
      }
    }

    return response;
  });

  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/cancel", async (request) => {
    const objectId = requireObjectId(request);
    const groupIds = parseGroupIds(request.body.groupIds);
    const response = await aptus.cancelTimeslot(objectId, request.params.timeslotId, groupIds, request.id);

    if (push) {
      const cancelled = succeededGroupIds(response.results, CANCEL_SUCCESS);
      if (cancelled.length > 0) {
        const { startAt } = decodeTimeslotId(request.params.timeslotId);
        push.onCancelled(objectId, startAt, cancelled);
      }
    }

    return response;
  });

  app.put<{ Body: DeviceBody }>("/notifications/device", async (request) => {
    const objectId = requireObjectId(request);
    if (!push) throw pushDisabled();
    const body = request.body ?? {};
    push.registerDevice({
      token: parseDeviceToken(body.deviceToken),
      objectId,
      environment: parseEnvironment(body.environment),
      enabled: body.enabled !== false,
      alertMinutes: parseAlertMinutes(body.alertMinutes, "alertMinutes"),
      secondAlertMinutes: parseAlertMinutes(body.secondAlertMinutes, "secondAlertMinutes")
    });
    return { ok: true };
  });

  app.delete<{ Body: DeviceBody }>("/notifications/device", async (request) => {
    requireObjectId(request);
    if (!push) throw pushDisabled();
    push.unregisterDevice(parseDeviceToken((request.body ?? {}).deviceToken));
    return { ok: true };
  });

  if (process.env.NODE_ENV !== "production") {
    app.post("/notifications/test", async (request) => {
      const objectId = requireObjectId(request);
      if (!push) throw pushDisabled();
      return { ok: true, devices: push.enqueueTestNotification(objectId) };
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

  const server = Object.assign(app, { push, upstream }) as unknown as LaundryServer;
  return server;
}

/** Served verbatim under `/.well-known/`; the app's half is the `applinks:` entitlement. */
const APP_SITE_ASSOCIATION = readFileSync(
  fileURLToPath(new URL("../site/apple-app-site-association", import.meta.url)),
  "utf8"
);

/** Per-group statuses that count as a real state change worth notifying about. */
const BOOK_SUCCESS = new Set(["booked"]);
const CANCEL_SUCCESS = new Set(["cancelled", "not_booked"]);

function succeededGroupIds(
  results: { groupId: number; status: string }[],
  accepted: Set<string>
): number[] {
  return results.filter((r) => accepted.has(r.status)).map((r) => r.groupId);
}

/** Optional: the app identifies its APNs token so it can be skipped on announcements. */
function deviceToken(request: FastifyRequest): string | null {
  const raw = request.headers["x-device-token"];
  return typeof raw === "string" && /^[0-9a-fA-F]{64}$/.test(raw.trim())
    ? raw.trim().toLowerCase()
    : null;
}

function pushDisabled(): AppError {
  return new AppError({
    statusCode: 503,
    code: "PUSH_DISABLED",
    message: "Push notifications are not configured on this server"
  });
}

function parseDeviceToken(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-fA-F]{64}$/.test(value.trim())) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_DEVICE_TOKEN",
      message: "deviceToken must be a 64-character hex APNs token"
    });
  }
  return value.trim().toLowerCase();
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
  app.upstream.start();

  const port = Number(process.env.PORT ?? 3000);
  const host = process.env.HOST ?? "0.0.0.0";
  await app.listen({ host, port });

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.once(signal, () => {
      app.push?.stop();
      app.upstream.stop();
      void app.close().then(() => process.exit(0));
    });
  }
}
