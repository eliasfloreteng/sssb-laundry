import { describe, expect, it } from "bun:test";
import { createPrivateKey, createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { ApnsClient, loadApnsConfig } from "../src/apns.js";

/** Reaches the private token minter without exporting it from the module. */
function providerToken(client: ApnsClient): string {
  return (client as unknown as { providerToken: () => string }).providerToken();
}

describe("apns provider token", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const client = new ApnsClient({
    keyId: "JJKLZDADS4",
    teamId: "XQ9HKBVB36",
    topic: "se.floreteng.SSSBLaundry",
    privateKey
  });

  it("signs an ES256 JWT that verifies against the public key", () => {
    const token = providerToken(client);
    const [header, claims, signature] = token.split(".");
    expect(header && claims && signature).toBeTruthy();

    expect(JSON.parse(Buffer.from(header!, "base64url").toString())).toEqual({
      alg: "ES256",
      kid: "JJKLZDADS4"
    });
    const payload = JSON.parse(Buffer.from(claims!, "base64url").toString());
    expect(payload.iss).toBe("XQ9HKBVB36");
    expect(typeof payload.iat).toBe("number");

    // Raw R||S, not DER — APNs rejects DER signatures outright.
    const raw = Buffer.from(signature!, "base64url");
    expect(raw.length).toBe(64);
    expect(
      verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, raw)
    ).toBe(true);
  });

  it("reuses the cached token rather than minting one per push", () => {
    expect(providerToken(client)).toBe(providerToken(client));
  });
});

describe("apns config", () => {
  it("returns null when the key is not configured", () => {
    const saved = { ...process.env };
    delete process.env.APNS_KEY_ID;
    delete process.env.APNS_KEY_P8;
    delete process.env.APNS_KEY_PATH;
    expect(loadApnsConfig()).toBeNull();
    Object.assign(process.env, saved);
  });

  it("accepts an inline PEM with escaped newlines", () => {
    const saved = { ...process.env };
    const pem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({
      type: "pkcs8",
      format: "pem"
    }) as string;
    process.env.APNS_KEY_ID = "KEY";
    process.env.APNS_TEAM_ID = "TEAM";
    process.env.APNS_TOPIC = "topic";
    process.env.APNS_KEY_P8 = pem.replace(/\n/g, "\\n");
    delete process.env.APNS_KEY_PATH;

    const config = loadApnsConfig();
    expect(config?.keyId).toBe("KEY");
    expect(config?.privateKey.asymmetricKeyType).toBe("ec");

    for (const key of ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_KEY_P8"]) delete process.env[key];
    Object.assign(process.env, saved);
  });
});

describe("the real signing key", () => {
  const path = "secrets/AuthKey_JJKLZDADS4.p8";
  // Gitignored, so it is only present on a machine that has the key.
  const present = existsSync(path);

  it.skipIf(!present)("is a P-256 key usable for ES256", () => {
    const key = createPrivateKey(readFileSync(path, "utf8"));
    expect(key.asymmetricKeyType).toBe("ec");
    expect(key.asymmetricKeyDetails?.namedCurve).toBe("prime256v1");
    expect(createPublicKey(key)).toBeTruthy();
  });
});
