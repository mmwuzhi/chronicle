import { describe, expect, it } from "vitest";
import type { CaptureBody, CapturePageBody } from "@/api";
import {
  captureMatchesPageParams,
  patchCapturePages,
  prependCaptureToPagesData,
  removeCaptureFromPagesData,
} from "@/utils/capture-cache";

function capture(overrides: Partial<CaptureBody> = {}): CaptureBody {
  return {
    id: "c1",
    rawText: "note",
    mediaUrl: null,
    mediaType: "text",
    source: "web",
    todoAt: null,
    doneAt: null,
    transcript: null,
    transcriptionStatus: "none",
    transcriptionModel: null,
    transcribedAt: null,
    audioDurationSec: null,
    remindAt: null,
    remindHide: true,
    createdAt: "2026-07-01T10:00:00Z",
    deletedAt: null,
    attachments: null,
    ...overrides,
  };
}

function pages(...pageItems: CaptureBody[][]): {
  pages: CapturePageBody[];
  pageParams: unknown[];
} {
  return {
    pages: pageItems.map((items) => ({ items, nextCursor: null })),
    pageParams: pageItems.map(() => undefined),
  };
}

const now = new Date("2026-07-08T12:00:00Z");

describe("captureMatchesPageParams", () => {
  it("matches everything on the unfiltered list", () => {
    expect(captureMatchesPageParams(capture(), undefined, now)).toBe(true);
  });

  it("todo=open requires an open todo", () => {
    const params = { todo: "open" };
    expect(captureMatchesPageParams(capture(), params, now)).toBe(false);
    expect(
      captureMatchesPageParams(
        capture({ todoAt: "2026-07-01T10:00:00Z" }),
        params,
        now,
      ),
    ).toBe(true);
    expect(
      captureMatchesPageParams(
        capture({
          todoAt: "2026-07-01T10:00:00Z",
          doneAt: "2026-07-02T10:00:00Z",
        }),
        params,
        now,
      ),
    ).toBe(false);
  });

  it("todo=done requires a completed todo", () => {
    const params = { todo: "done" };
    expect(captureMatchesPageParams(capture(), params, now)).toBe(false);
    expect(
      captureMatchesPageParams(
        capture({
          todoAt: "2026-07-01T10:00:00Z",
          doneAt: "2026-07-02T10:00:00Z",
        }),
        params,
        now,
      ),
    ).toBe(true);
  });

  it("hides future hiding reminders unless includeReminded", () => {
    const scheduled = capture({ remindAt: "2026-07-09T12:00:00Z" });
    expect(captureMatchesPageParams(scheduled, undefined, now)).toBe(false);
    expect(
      captureMatchesPageParams(scheduled, { includeReminded: true }, now),
    ).toBe(true);
  });

  it("keeps due and notify-only reminders visible", () => {
    const due = capture({ remindAt: "2026-07-08T11:00:00Z" });
    expect(captureMatchesPageParams(due, undefined, now)).toBe(true);
    const notifyOnly = capture({
      remindAt: "2026-07-09T12:00:00Z",
      remindHide: false,
    });
    expect(captureMatchesPageParams(notifyOnly, undefined, now)).toBe(true);
  });
});

describe("patchCapturePages", () => {
  it("replaces the item in place across pages", () => {
    const data = pages(
      [capture({ id: "a" })],
      [capture({ id: "b", rawText: "old" })],
    );
    const next = patchCapturePages(
      data,
      capture({ id: "b", rawText: "new" }),
      undefined,
    );
    expect(next.pages[1].items?.[0].rawText).toBe("new");
    expect(next.pages[0].items?.[0].rawText).toBe("note");
  });

  it("removes the item from a variant it no longer matches", () => {
    const open = capture({ id: "a", todoAt: "2026-07-01T10:00:00Z" });
    const data = pages([open]);
    const next = patchCapturePages(
      data,
      { ...open, doneAt: "2026-07-08T11:00:00Z" },
      { todo: "open" },
    );
    expect(next.pages[0].items).toHaveLength(0);
  });

  it("keeps previously embedded attachments when the update carries null", () => {
    const withAtt = capture({
      id: "a",
      attachments: [
        {
          id: "att1",
          captureId: "a",
          provider: "google_drive",
          providerFileId: "f1",
          name: "notes.pdf",
          mimeType: null,
          sizeBytes: null,
          webUrl: "https://example.test/f1",
          createdAt: "2026-07-01T10:00:00Z",
        },
      ],
    });
    const next = patchCapturePages(
      pages([withAtt]),
      capture({ id: "a", rawText: "edited", attachments: null }),
      undefined,
    );
    expect(next.pages[0].items?.[0].rawText).toBe("edited");
    expect(next.pages[0].items?.[0].attachments).toHaveLength(1);
  });
});

describe("prependCaptureToPagesData", () => {
  it("adds the capture to the head of the first page", () => {
    const data = pages([capture({ id: "a" })], [capture({ id: "b" })]);
    const next = prependCaptureToPagesData(data, capture({ id: "c" }), {});
    expect(next.pages[0].items?.map((c) => c.id)).toEqual(["c", "a"]);
    expect(next.pages[1].items?.map((c) => c.id)).toEqual(["b"]);
  });

  it("skips variants the capture doesn't match", () => {
    const data = pages([capture({ id: "a", todoAt: "2026-07-01T10:00:00Z" })]);
    const next = prependCaptureToPagesData(data, capture({ id: "c" }), {
      todo: "open",
    });
    expect(next.pages[0].items).toHaveLength(1);
  });
});

describe("removeCaptureFromPagesData", () => {
  it("drops the capture from every page", () => {
    const data = pages([capture({ id: "a" }), capture({ id: "b" })]);
    const next = removeCaptureFromPagesData(data, "a");
    expect(next.pages[0].items?.map((c) => c.id)).toEqual(["b"]);
  });
});
