import { describe, expect, it, vi } from "vitest";
import { fmtShortDateTime, timeAgo } from "./format";

describe("fmtShortDateTime", () => {
  it("formats compact date and time", () => {
    expect(fmtShortDateTime("2026-06-03T08:30:00.000Z")).toMatch(
      /Jun 3 · \d{1,2}:30(am|pm)/,
    );
  });
});

describe("timeAgo", () => {
  it("uses relative time for minutes", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-03T09:00:00.000Z"));

    expect(timeAgo("2026-06-03T08:30:00.000Z", "en")).toBe("30 minutes ago");

    vi.useRealTimers();
  });
});
