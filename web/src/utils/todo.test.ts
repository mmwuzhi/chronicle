import { describe, expect, it } from "vitest";
import { todoProgress } from "@/utils/todo";

describe("todoProgress", () => {
  it("counts only flagged captures", () => {
    expect(
      todoProgress([
        { todoAt: null, doneAt: null },
        { todoAt: "2026-07-01T00:00:00Z", doneAt: null },
        { todoAt: "2026-07-01T00:00:00Z", doneAt: "2026-07-02T00:00:00Z" },
      ]),
    ).toEqual({ done: 1, total: 2 });
  });

  it("returns zero totals when nothing is flagged", () => {
    expect(todoProgress([{ todoAt: null }, {}])).toEqual({ done: 0, total: 0 });
  });

  it("never counts a done capture that was not flagged", () => {
    // The API's CHECK constraint makes this state impossible, but the derived
    // count must not invent progress if it ever sees one.
    expect(
      todoProgress([{ todoAt: null, doneAt: "2026-07-02T00:00:00Z" }]),
    ).toEqual({
      done: 0,
      total: 0,
    });
  });
});
