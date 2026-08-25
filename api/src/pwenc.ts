import { AppError } from "./errors.js";

export function encodePwEnc(password: string, passwordSalt: string): string {
  const salt = Number(passwordSalt);
  if (!Number.isInteger(salt) || salt < 0 || salt > 65535) {
    throw new AppError({
      statusCode: 502,
      code: "UPSTREAM_PARSE_ERROR",
      message: "Invalid PasswordSalt from Aptus login page",
      details: { passwordSalt }
    });
  }

  let output = "";
  for (const char of password) {
    output += String.fromCharCode(char.charCodeAt(0) ^ salt);
  }
  return output;
}
