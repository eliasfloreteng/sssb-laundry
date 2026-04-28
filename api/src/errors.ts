export class AppError extends Error {
  readonly statusCode: number;
  readonly code: string;
  readonly details?: unknown;
  readonly upstream?: {
    path: string;
    status?: number;
    location?: string;
    feedback?: string;
  };

  constructor(args: {
    statusCode: number;
    code: string;
    message: string;
    details?: unknown;
    upstream?: {
      path: string;
      status?: number;
      location?: string;
      feedback?: string;
    };
  }) {
    super(args.message);
    this.name = "AppError";
    this.statusCode = args.statusCode;
    this.code = args.code;
    this.details = args.details;
    this.upstream = args.upstream;
  }
}

export function asError(input: unknown): Error {
  if (input instanceof Error) return input;
  return new Error("Unknown error", { cause: input });
}
