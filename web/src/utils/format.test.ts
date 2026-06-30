import { describe, expect, it, vi } from "vitest";
import { fmtFileSize, fmtShortDateTime, timeAgo } from "./format";

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

describe("fmtFileSize", () => {
  it("formats bytes and larger units compactly", () => {
    expect(fmtFileSize(512)).toBe("512 B");
    expect(fmtFileSize(1536)).toBe("1.5 KB");
    expect(fmtFileSize(5 * 1024 * 1024)).toBe("5 MB");
  });

  it("returns an empty label for invalid sizes", () => {
    expect(fmtFileSize(-1)).toBe("");
    expect(fmtFileSize(Number.NaN)).toBe("");
  });
});
