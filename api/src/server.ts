import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import { AppError, asError } from "./errors.js";
import { AptusClient } from "./aptus-client.js";

interface TimeslotsQuery {
  date?: string;
}

interface ActionBody {
  groupIds?: unknown;
}

interface TimeslotParams {
  timeslotId: string;
}

export function buildServer(args?: { aptusClient?: AptusClient }): FastifyInstance {
  const logLevel = process.env.LOG_LEVEL ?? "info";
  const app = Fastify({
    logger: { level: logLevel },
    routerOptions: {
      maxParamLength: 256
    }
  });
  const aptus = args?.aptusClient ?? new AptusClient({ logger: app.log });

  app.get("/health", async () => ({ ok: true }));

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
    return aptus.bookTimeslot(objectId, request.params.timeslotId, groupIds, request.id);
  });

  app.post<{ Params: TimeslotParams; Body: ActionBody }>("/timeslots/:timeslotId/cancel", async (request) => {
    const objectId = requireObjectId(request);
    const groupIds = parseGroupIds(request.body.groupIds);
    return aptus.cancelTimeslot(objectId, request.params.timeslotId, groupIds, request.id);
  });

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

  return app;
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
  const port = Number(process.env.PORT ?? 3000);
  const host = process.env.HOST ?? "0.0.0.0";
  await app.listen({ host, port });
}
