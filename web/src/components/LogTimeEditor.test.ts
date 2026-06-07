import { describe, expect, it } from "vitest";
import {
  emptyLogTimeDraft,
  logTimeDraftFromValue,
  logTimePayload,
} from "../utils/log-time";

describe("logTimePayload", () => {
  it("creates a duration-only payload", () => {
    expect(
      logTimePayload({
        ...emptyLogTimeDraft,
        mode: "duration",
        minutes: "25",
      }),
    ).toEqual({ inputMode: "duration", durationSec: 1500 });
  });

  it("rejects a duration longer than the selected range", () => {
    expect(
      logTimePayload({
        mode: "range",
        minutes: "45",
        startedAt: "2026-06-06T09:00",
        endedAt: "2026-06-06T09:30",
      }),
    ).toBeNull();
  });

  it("round-trips a range value into local form state", () => {
    const draft = logTimeDraftFromValue({
      inputMode: "range",
      durationSec: 1800,
      startedAt: "2026-06-06T09:00:00Z",
      endedAt: "2026-06-06T10:00:00Z",
    });
    expect(draft.mode).toBe("range");
    expect(draft.minutes).toBe("30");
    expect(logTimePayload(draft)?.durationSec).toBe(1800);
  });
});
