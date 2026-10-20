import { describe, expect, it } from "bun:test";
import { FeedbackService, type FeedbackSender } from "../src/feedback.js";
import { buildServer } from "../src/server.js";

const OBJECT_ID = "1111-1111-111";

function recordingSender(fail = false): FeedbackSender & { sent: string[] } {
  const sent: string[] = [];
  return {
    sent,
    async send(text) {
      if (fail) throw new Error("Telegram answered 500");
      sent.push(text);
    }
  };
}

async function serverWith(feedbackService: FeedbackService | null) {
  const app = buildServer({ pushService: null, dibsService: null, feedbackService });
  await app.ready();
  return app;
}

function post(app: Awaited<ReturnType<typeof serverWith>>, body: unknown, objectId: string | null = OBJECT_ID) {
  return app.inject({
    method: "POST",
    url: "/feedback",
    headers: objectId ? { "x-object-id": objectId } : {},
    payload: body as Record<string, unknown>
  });
}

describe("POST /feedback", () => {
  it("forwards the message with its context and the object id", async () => {
    const sender = recordingSender();
    const app = await serverWith(new FeedbackService({ sender }));
    try {
      const response = await post(app, {
        message: "  The week list is great  ",
        context: { appVersion: "1.0 (11)", osVersion: "iOS 26.1", device: "iPhone", laundryRoom: 42 }
      });
      expect(response.statusCode).toBe(200);
      expect(sender.sent).toHaveLength(1);
      const [text] = sender.sent;
      expect(text).toContain("The week list is great");
      expect(text).toContain("App 1.0 (11)");
      expect(text).toContain("iPhone, iOS 26.1");
      expect(text).toContain(`Object number ${OBJECT_ID}`);
      expect(text).not.toContain("42");
    } finally {
      await app.close();
    }
  });

  it("refuses an empty message and a missing object id", async () => {
    const sender = recordingSender();
    const app = await serverWith(new FeedbackService({ sender }));
    try {
      expect((await post(app, { message: "   " })).statusCode).toBe(400);
      expect((await post(app, { message: "x".repeat(4000) })).statusCode).toBe(400);
      expect((await post(app, { message: "hi" }, null)).statusCode).toBe(400);
      expect(sender.sent).toHaveLength(0);
    } finally {
      await app.close();
    }
  });

  it("rate limits per object id", async () => {
    const sender = recordingSender();
    let now = 0;
    const app = await serverWith(new FeedbackService({ sender, now: () => now }));
    try {
      for (let i = 0; i < 5; i++) expect((await post(app, { message: `#${i}` })).statusCode).toBe(200);
      const limited = await post(app, { message: "one more" });
      expect(limited.statusCode).toBe(429);
      expect(limited.json().error.code).toBe("FEEDBACK_RATE_LIMITED");
      expect((await post(app, { message: "someone else" }, "2222-2222-222")).statusCode).toBe(200);
      now += 10 * 60 * 1000;
      expect((await post(app, { message: "later" })).statusCode).toBe(200);
    } finally {
      await app.close();
    }
  });

  it("reports a failed forward instead of claiming it went through", async () => {
    const app = await serverWith(new FeedbackService({ sender: recordingSender(true) }));
    try {
      const response = await post(app, { message: "hello" });
      expect(response.statusCode).toBe(502);
      expect(response.json().error.code).toBe("FEEDBACK_FAILED");
    } finally {
      await app.close();
    }
  });

  it("answers FEEDBACK_DISABLED when nothing is configured", async () => {
    const app = await serverWith(null);
    try {
      const response = await post(app, { message: "hello" });
      expect(response.statusCode).toBe(503);
      expect(response.json().error.code).toBe("FEEDBACK_DISABLED");
    } finally {
      await app.close();
    }
  });
});
