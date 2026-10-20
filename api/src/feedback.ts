import { hashObjectId, type LoggerLike } from "./aptus-client.js";
import { AppError } from "./errors.js";

/** Telegram refuses a message over 4096 characters; the context lines need some of that. */
export const FEEDBACK_MAX_LENGTH = 3500;
/** Per object id, per window — enough for anyone writing in good faith. */
const RATE_LIMIT = 5;
const RATE_WINDOW_MS = 10 * 60 * 1000;

/** What the app knows about where it is running, all optional and all shown as-is. */
export interface FeedbackContext {
  appVersion?: string;
  osVersion?: string;
  device?: string;
  locale?: string;
  laundryRoom?: string;
}

export interface FeedbackSender {
  send(text: string): Promise<void>;
}

/**
 * Feedback from inside the app, forwarded as a Telegram message. Nothing is
 * stored: the chat is the record, and a message that could not be forwarded is
 * an error the app shows, so the resident still has their text to send again.
 *
 * The message carries the object id, so a report can be reproduced against the
 * apartment it came from. That makes the chat as sensitive as the id itself;
 * the log still only ever sees the hash.
 */
export class FeedbackService {
  private readonly sender: FeedbackSender;
  private readonly logger?: LoggerLike;
  private readonly now: () => number;
  private readonly recent = new Map<string, number[]>();

  constructor(args: { sender: FeedbackSender; logger?: LoggerLike; now?: () => number }) {
    this.sender = args.sender;
    this.logger = args.logger;
    this.now = args.now ?? Date.now;
  }

  async submit(objectId: string, message: string, context: FeedbackContext): Promise<void> {
    const objectKey = hashObjectId(objectId);
    this.throttle(objectKey);
    try {
      await this.sender.send(format(objectId, message, context));
    } catch (error) {
      this.logger?.error?.({ objectKey, err: error }, "Feedback could not be forwarded");
      throw new AppError({
        statusCode: 502,
        code: "FEEDBACK_FAILED",
        message: "Feedback could not be delivered"
      });
    }
    this.logger?.info?.({ objectKey, length: message.length }, "Feedback forwarded");
  }

  private throttle(objectKey: string): void {
    const now = this.now();
    const recent = (this.recent.get(objectKey) ?? []).filter((at) => now - at < RATE_WINDOW_MS);
    if (recent.length >= RATE_LIMIT) {
      throw new AppError({
        statusCode: 429,
        code: "FEEDBACK_RATE_LIMITED",
        message: "Too much feedback at once — try again in a few minutes"
      });
    }
    recent.push(now);
    this.recent.set(objectKey, recent);
  }
}

function format(objectId: string, message: string, context: FeedbackContext): string {
  const lines = [
    context.appVersion && `App ${context.appVersion}`,
    [context.device, context.osVersion].filter(Boolean).join(", "),
    context.laundryRoom,
    context.locale && `Locale ${context.locale}`,
    `Object number ${objectId}`
  ].filter(Boolean);
  return `💬 SSSB Laundry feedback\n\n${message}\n\n${lines.join("\n")}`;
}

class TelegramSender implements FeedbackSender {
  constructor(
    private readonly token: string,
    private readonly chatId: string
  ) {}

  async send(text: string): Promise<void> {
    const response = await fetch(`https://api.telegram.org/bot${this.token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // Plain text on purpose: what a resident writes is never parsed as markup.
      body: JSON.stringify({ chat_id: this.chatId, text, disable_web_page_preview: true }),
      signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) {
      // The URL holds the bot token, so only the status is worth reporting.
      throw new Error(`Telegram answered ${response.status}`);
    }
  }
}

export function createFeedbackService(logger?: LoggerLike): FeedbackService | null {
  const token = process.env.FEEDBACK_TELEGRAM_BOT_TOKEN;
  const chatId = process.env.FEEDBACK_TELEGRAM_CHAT_ID;
  if (!token || !chatId) {
    logger?.warn?.({}, "FEEDBACK_TELEGRAM_BOT_TOKEN or FEEDBACK_TELEGRAM_CHAT_ID is unset; feedback is disabled");
    return null;
  }
  return new FeedbackService({ sender: new TelegramSender(token, chatId), logger });
}
