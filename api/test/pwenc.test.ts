import { describe, expect, it } from "vitest";
import { encodePwEnc } from "../src/pwenc.js";

describe("encodePwEnc", () => {
  it("encodes password with XOR salt", () => {
    const encoded = encodePwEnc("abc123", "4015");
    const codePoints = [...encoded].map((char) => char.codePointAt(0));
    expect(codePoints).toEqual([4046, 4045, 4044, 3998, 3997, 3996]);
  });

  it("throws on invalid salt", () => {
    expect(() => encodePwEnc("abc", "not-a-number")).toThrow("Invalid PasswordSalt");
  });
});
