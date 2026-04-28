import { AppError } from "./errors.js";

interface RawTimeslotId {
  s: string;
  e: string;
}

export function encodeTimeslotId(startAt: string, endAt: string): string {
  const payload: RawTimeslotId = { s: startAt, e: endAt };
  return `ts_${Buffer.from(JSON.stringify(payload), "utf8").toString("base64url")}`;
}

export function decodeTimeslotId(id: string): { startAt: string; endAt: string } {
  if (!id.startsWith("ts_")) {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_ID",
      message: "Invalid timeslot id format"
    });
  }

  try {
    const encoded = id.slice(3);
    const raw = Buffer.from(encoded, "base64url").toString("utf8");
    const parsed = JSON.parse(raw) as RawTimeslotId;
    if (!parsed?.s || !parsed?.e) throw new Error("Missing fields");
    return { startAt: parsed.s, endAt: parsed.e };
  } catch {
    throw new AppError({
      statusCode: 400,
      code: "INVALID_TIMESLOT_ID",
      message: "Failed to decode timeslot id"
    });
  }
}
