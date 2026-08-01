import { describe, expect, it } from "vitest";
import {
  formatPageCapture,
  formatSelectionCapture,
  normalizeAPIBaseURL,
  queueAdmissionError,
  queueScopeKey,
  readyQueueItems,
  retryDelayMs,
  shouldRetry,
  type QueueItem,
} from "@/core";

describe("capture formatting", () => {
  it("keeps the selected text and a searchable source URL", () => {
    expect(
      formatSelectionCapture(
        "A useful paragraph",
        "Docs [draft]",
        "https://example.com/a_(b)",
      ),
    ).toBe(
      "A useful paragraph\n\n[Docs \\[draft\\]](https://example.com/a_%28b%29)",
    );
  });

  it("falls back to the URL when the page has no title", () => {
    expect(formatPageCapture("", "https://example.com")).toBe(
      "https://example.com",
    );
  });
});

describe("API origin validation", () => {
  it("accepts HTTPS and localhost HTTP only", () => {
    expect(normalizeAPIBaseURL("https://example.com/api/")).toBe(
      "https://example.com/api",
    );
    expect(normalizeAPIBaseURL("http://localhost:8080")).toBe(
      "http://localhost:8080",
    );
    expect(() => normalizeAPIBaseURL("http://example.com")).toThrow(/HTTPS/);
  });
});

describe("queue retry policy", () => {
  it("isolates queues by API origin and token fingerprint", async () => {
    const first = await queueScopeKey({
      apiBaseURL: "https://one.example/api",
      token: "chr_cap_first",
    });
    const otherOrigin = await queueScopeKey({
      apiBaseURL: "https://two.example/api",
      token: "chr_cap_first",
    });
    const otherToken = await queueScopeKey({
      apiBaseURL: "https://one.example/api",
      token: "chr_cap_second",
    });
    expect(first).not.toBe(otherOrigin);
    expect(first).not.toBe(otherToken);
    expect(first).not.toContain("chr_cap_first");
  });

  it("retries network, rate limit, and server failures", () => {
    expect(shouldRetry()).toBe(true);
    expect(shouldRetry(429)).toBe(true);
    expect(shouldRetry(503)).toBe(true);
    expect(shouldRetry(401)).toBe(false);
  });

  it("caps exponential backoff and selects only ready pending items", () => {
    expect(retryDelayMs(1)).toBe(5_000);
    expect(retryDelayMs(20)).toBe(5 * 60_000);
    const ready: QueueItem = {
      id: "1",
      rawText: "ready",
      createdAt: "2026-01-01T00:00:00Z",
      attempts: 1,
      nextAttemptAt: "2026-01-01T00:00:00Z",
      status: "pending",
    };
    const failed: QueueItem = { ...ready, id: "2", status: "failed" };
    expect(readyQueueItems([ready, failed], new Date("2026-01-02"))).toEqual([
      ready,
    ]);
  });

  it("rejects oversized captures and a full offline queue", () => {
    const item: QueueItem = {
      id: "1",
      rawText: "queued",
      createdAt: "2026-01-01T00:00:00Z",
      attempts: 0,
      nextAttemptAt: "2026-01-01T00:00:00Z",
      status: "pending",
    };
    expect(queueAdmissionError([], "x".repeat(101 * 1024))).toMatch(
      /too large/,
    );
    expect(
      queueAdmissionError(
        Array.from({ length: 50 }, (_, index) => ({
          ...item,
          id: String(index),
        })),
        "small",
      ),
    ).toMatch(/queue is full/);
  });
});
