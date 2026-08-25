import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect, constants, type ClientHttp2Session } from "node:http2";
import type { LoggerLike } from "./aptus-client.js";
import type { PushEnvironment } from "./db.js";

const HOSTS: Record<PushEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com"
};

/**
 * Apple rejects provider tokens refreshed more often than every 20 minutes and
 * tokens older than 60. Forty minutes sits safely inside both bounds.
 */
const TOKEN_MAX_AGE_MS = 40 * 60 * 1000;

/** Reasons that mean the token is dead and the device row should go. */
const DEAD_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "Unregistered",
  "DeviceTokenNotForTopic"
]);

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  topic: string;
  privateKey: KeyObject;
}

export type ApnsOutcome =
  | { kind: "sent" }
  /** The device token is dead — delete it rather than retrying. */
  | { kind: "unregistered"; reason: string }
  | { kind: "failed"; status: number; reason: string; retryable: boolean };

export interface ApnsRequest {
  token: string;
  environment: PushEnvironment;
  payload: unknown;
  /** "background" for a silent wake-up, which APNs only accepts at priority 5. */
  pushType?: "alert" | "background";
  collapseId?: string;
  /** Epoch seconds after which APNs should stop trying. */
  expiration?: number;
  priority?: number;
}

/** Reads the .p8 from APNS_KEY_P8 (inline PEM, production) or APNS_KEY_PATH (dev). */
export function loadApnsConfig(): ApnsConfig | null {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const topic = process.env.APNS_TOPIC;
  const inline = process.env.APNS_KEY_P8;
  const path = process.env.APNS_KEY_PATH;

  if (!keyId || !teamId || !topic || (!inline && !path)) return null;

  const pem = inline ? inline.replace(/\\n/g, "\n") : readFileSync(path!, "utf8");
  return { keyId, teamId, topic, privateKey: createPrivateKey(pem) };
}

export class ApnsClient {
  private readonly config: ApnsConfig;
  private readonly logger?: LoggerLike;
  private readonly sessions = new Map<PushEnvironment, ClientHttp2Session>();
  private cachedToken?: { value: string; issuedAt: number };

  constructor(config: ApnsConfig, logger?: LoggerLike) {
    this.config = config;
    this.logger = logger;
  }

  async send(request: ApnsRequest): Promise<ApnsOutcome> {
    const outcome = await this.attempt(request);
    // A provider token can expire between minting and use; one forced refresh
    // is enough to tell that apart from a genuinely bad configuration.
    if (outcome.kind === "failed" && outcome.reason === "ExpiredProviderToken") {
      this.cachedToken = undefined;
      return this.attempt(request);
    }
    return outcome;
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private async attempt(request: ApnsRequest): Promise<ApnsOutcome> {
    let session: ClientHttp2Session;
    try {
      session = this.session(request.environment);
    } catch (error) {
      return { kind: "failed", status: 0, reason: describe(error), retryable: true };
    }

    const body = JSON.stringify(request.payload);
    const headers: Record<string, string | number> = {
      [constants.HTTP2_HEADER_METHOD]: "POST",
      [constants.HTTP2_HEADER_PATH]: `/3/device/${request.token}`,
      [constants.HTTP2_HEADER_SCHEME]: "https",
      authorization: `bearer ${this.providerToken()}`,
      "apns-topic": this.config.topic,
      "apns-push-type": request.pushType ?? "alert",
      "apns-priority": request.priority ?? 10,
      "content-length": Buffer.byteLength(body)
    };
    if (request.collapseId) headers["apns-collapse-id"] = request.collapseId.slice(0, 64);
    if (request.expiration !== undefined) headers["apns-expiration"] = request.expiration;

    return new Promise<ApnsOutcome>((resolve) => {
      let settled = false;
      const finish = (outcome: ApnsOutcome) => {
        if (settled) return;
        settled = true;
        resolve(outcome);
      };

      const stream = session.request(headers);
      stream.setEncoding("utf8");
      stream.setTimeout(15_000, () => {
        stream.close();
        finish({ kind: "failed", status: 0, reason: "Timeout", retryable: true });
      });

      let status = 0;
      let raw = "";
      stream.on("response", (responseHeaders) => {
        status = Number(responseHeaders[constants.HTTP2_HEADER_STATUS] ?? 0);
      });
      stream.on("data", (chunk: string) => {
        raw += chunk;
      });
      stream.on("error", (error) => {
        finish({ kind: "failed", status: 0, reason: describe(error), retryable: true });
      });
      stream.on("end", () => {
        finish(classify(status, raw));
      });

      stream.end(body);
    });
  }

  /** One long-lived connection per environment; dropped on error so the next send reconnects. */
  private session(environment: PushEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;

    const session = connect(HOSTS[environment]);
    const forget = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on("error", (error) => {
      this.logger?.warn?.({ environment, err: describe(error) }, "APNs session error");
      forget();
    });
    session.on("goaway", forget);
    session.on("close", forget);
    session.unref();
    this.sessions.set(environment, session);
    return session;
  }

  private providerToken(): string {
    const cached = this.cachedToken;
    if (cached && Date.now() - cached.issuedAt < TOKEN_MAX_AGE_MS) return cached.value;

    const issuedAt = Date.now();
    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const claims = base64url(
      JSON.stringify({ iss: this.config.teamId, iat: Math.floor(issuedAt / 1000) })
    );
    const signingInput = `${header}.${claims}`;
    // ieee-p1363 is raw R||S, which is exactly what JOSE ES256 wants — DER would be rejected.
    const signature = sign("sha256", Buffer.from(signingInput), {
      key: this.config.privateKey,
      dsaEncoding: "ieee-p1363"
    });
    const value = `${signingInput}.${signature.toString("base64url")}`;
    this.cachedToken = { value, issuedAt };
    return value;
  }
}

function classify(status: number, raw: string): ApnsOutcome {
  if (status === 200) return { kind: "sent" };

  let reason = "Unknown";
  try {
    const parsed = JSON.parse(raw) as { reason?: string };
    if (parsed.reason) reason = parsed.reason;
  } catch {
    // APNs sends a JSON problem document on every error; a non-JSON body is
    // itself the diagnosis, so keep whatever arrived.
    if (raw) reason = raw.slice(0, 200);
  }

  if (status === 410 || DEAD_TOKEN_REASONS.has(reason)) {
    return { kind: "unregistered", reason };
  }
  const retryable = status === 429 || status >= 500 || reason === "ExpiredProviderToken";
  return { kind: "failed", status, reason, retryable };
}

function base64url(input: string): string {
  return Buffer.from(input, "utf8").toString("base64url");
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
