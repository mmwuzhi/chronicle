import { describe, expect, it, vi } from "vitest";
import {
  fmtFileSize,
  fmtListTime,
  fmtPreciseDateTime,
  timeAgo,
} from "./format";

describe("fmtListTime", () => {
  it("uses relative time under seven days", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-03T09:00:00.000Z"));

    expect(fmtListTime("2026-06-03T08:30:00.000Z", "en")).toBe(
      "30 minutes ago",
    );
    expect(fmtListTime("2026-05-30T09:00:00.000Z", "en")).toBe("4 days ago");

    vi.useRealTimers();
  });

  it("uses the short date past seven days, adding the year across years", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-05T12:00:00.000Z"));

    expect(fmtListTime("2026-06-03T08:30:00.000Z", "en")).toBe("Jun 3");
    expect(fmtListTime("2025-06-03T08:30:00.000Z", "en")).toBe("Jun 3, 2025");

    vi.useRealTimers();
  });
});

describe("fmtPreciseDateTime", () => {
  it("formats a full date and time", () => {
    expect(fmtPreciseDateTime("2026-06-03T08:30:00.000Z", "en")).toMatch(
      /Jun 3, 2026 · \d{1,2}:30(am|pm)/,
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
