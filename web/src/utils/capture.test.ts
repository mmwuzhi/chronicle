import { describe, expect, it } from "vitest";
import { captureText, truncateCaptureText } from "@/utils/capture";

describe("Capture text helpers", () => {
  it("prefers raw text and falls back to the transcript", () => {
    expect(captureText({ rawText: "written", transcript: "spoken" })).toBe(
      "written",
    );
    expect(captureText({ rawText: null, transcript: "spoken" })).toBe("spoken");
    expect(captureText({ rawText: "", transcript: "spoken" })).toBe("spoken");
    expect(captureText({ rawText: null, transcript: null })).toBe("");
  });

  it("trims and truncates display text consistently", () => {
    expect(
      truncateCaptureText({ rawText: "  short  ", transcript: null }, 10),
    ).toBe("short");
    expect(
      truncateCaptureText({ rawText: "one two three", transcript: null }, 8),
    ).toBe("one two…");
  });
});
