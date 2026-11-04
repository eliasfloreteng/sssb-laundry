import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import type { ApnsOutcome } from "./apns.js";
import type { LoggerLike } from "./aptus-client.js";

/** Same three outcomes as APNs, so the sender treats both services alike. */
export type FcmOutcome = ApnsOutcome;

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/** Google access tokens live an hour; renewing five minutes early avoids racing the expiry. */
const TOKEN_MARGIN_MS = 5 * 60 * 1000;

/** FCM error codes that mean the registration token is dead and the device row should go. */
const DEAD_TOKEN_CODES = new Set(["UNREGISTERED", "SENDER_ID_MISMATCH"]);

export interface FcmConfig {
  projectId: string;
  clientEmail: string;
  tokenUri: string;
  privateKey: KeyObject;
}

export interface FcmRequest {
  token: string;
  /** FCM data values must all be strings. */
  data: Record<string, string>;
  /** Pushes with the same key replace one another while still undelivered. */
  collapseKey?: string;
  /** Epoch seconds after which FCM should stop trying. */
  expiration?: number;
}

/**
 * Reads a Google service account key from FCM_SERVICE_ACCOUNT_JSON (inline,
 * production) or FCM_SERVICE_ACCOUNT_PATH (dev). The account needs only the
 * Firebase Cloud Messaging API Admin role on the project.
 */
export function loadFcmConfig(): FcmConfig | null {
  const inline = process.env.FCM_SERVICE_ACCOUNT_JSON;
  const path = process.env.FCM_SERVICE_ACCOUNT_PATH;
  if (!inline && !path) return null;

  const key = JSON.parse(inline ?? readFileSync(path!, "utf8")) as {
    project_id?: string;
    client_email?: string;
    token_uri?: string;
    private_key?: string;
  };
  if (!key.project_id || !key.client_email || !key.private_key) return null;
  return {
    projectId: key.project_id,
    clientEmail: key.client_email,
    tokenUri: key.token_uri ?? "https://oauth2.googleapis.com/token",
    privateKey: createPrivateKey(key.private_key)
  };
}

/** Sends data messages through the FCM HTTP v1 API, which is how Android gets its pushes. */
export class FcmClient {
  private readonly config: FcmConfig;
  private readonly logger?: LoggerLike;
  private cachedToken?: { value: string; expiresAt: number };

  constructor(config: FcmConfig, logger?: LoggerLike) {
    this.config = config;
    this.logger = logger;
  }

  async send(request: FcmRequest): Promise<FcmOutcome> {
    const outcome = await this.attempt(request);
    // A revoked or expired access token looks like this; one fresh token tells
    // that apart from a key that no longer works.
    if (outcome.kind === "failed" && outcome.status === 401) {
      this.cachedToken = undefined;
      return this.attempt(request);
    }
    return outcome;
  }

  private async attempt(request: FcmRequest): Promise<FcmOutcome> {
    let accessToken: string;
    try {
      accessToken = await this.accessToken();
    } catch (error) {
      this.logger?.warn?.({ err: describe(error) }, "FCM access token request failed");
      return { kind: "failed", status: 0, reason: describe(error), retryable: true };
    }

    const android: Record<string, unknown> = {
      // Every push here is either shown or takes a shown one down, which is
      // what Android expects of a high-priority message.
      priority: "HIGH"
    };
    if (request.collapseKey) android.collapse_key = request.collapseKey;
    if (request.expiration !== undefined) {
      android.ttl = `${Math.max(0, request.expiration - Math.floor(Date.now() / 1000))}s`;
    }

    let response: Response;
    try {
      response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${this.config.projectId}/messages:send`,
        {
          method: "POST",
          headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
          body: JSON.stringify({ message: { token: request.token, data: request.data, android } }),
          signal: AbortSignal.timeout(15_000)
        }
      );
    } catch (error) {
      return { kind: "failed", status: 0, reason: describe(error), retryable: true };
    }
    if (response.ok) return { kind: "sent" };
    return classify(response.status, await response.text().catch(() => ""));
  }

  /** An OAuth access token from a self-signed JWT, cached until shortly before it expires. */
  private async accessToken(): Promise<string> {
    const cached = this.cachedToken;
    if (cached && Date.now() < cached.expiresAt - TOKEN_MARGIN_MS) return cached.value;

    const iat = Math.floor(Date.now() / 1000);
    const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const claims = base64url(
      JSON.stringify({
        iss: this.config.clientEmail,
        scope: SCOPE,
        aud: this.config.tokenUri,
        iat,
        exp: iat + 3600
      })
    );
    const signingInput = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(signingInput), this.config.privateKey);
    const assertion = `${signingInput}.${signature.toString("base64url")}`;

    const response = await fetch(this.config.tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion
      }),
      signal: AbortSignal.timeout(15_000)
    });
    const body = (await response.json().catch(() => ({}))) as {
      access_token?: string;
      expires_in?: number;
      error?: string;
      error_description?: string;
    };
    if (!response.ok || !body.access_token) {
      throw new Error(`Token endpoint answered ${response.status}: ${body.error_description ?? body.error ?? "no token"}`);
    }
    this.cachedToken = {
      value: body.access_token,
      expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000
    };
    return body.access_token;
  }
}

/** Reads the FCM error code out of a v1 error document. */
export function classify(status: number, raw: string): FcmOutcome {
  let code = "";
  let message = raw.slice(0, 200) || "Unknown";
  try {
    const parsed = JSON.parse(raw) as {
      error?: { status?: string; message?: string; details?: { errorCode?: string }[] };
    };
    code = parsed.error?.details?.find((d) => d.errorCode)?.errorCode ?? parsed.error?.status ?? "";
    if (parsed.error?.message) message = parsed.error.message;
  } catch {
    // Not JSON: keep the raw body as the reason.
  }
  const reason = code ? `${code}: ${message}` : message;

  // A malformed token comes back as INVALID_ARGUMENT, the same code as a bad
  // payload; only the message tells them apart.
  if (DEAD_TOKEN_CODES.has(code) || (code === "INVALID_ARGUMENT" && /registration token/i.test(message))) {
    return { kind: "unregistered", reason };
  }
  const retryable = status === 401 || status === 429 || status >= 500;
  return { kind: "failed", status, reason, retryable };
}

function base64url(input: string): string {
  return Buffer.from(input, "utf8").toString("base64url");
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
