import { expect, test, type Page } from "@playwright/test";

async function goto(page: Page, path: string) {
  await page.goto(path, { waitUntil: "domcontentloaded" });
}

function visibleSearchTrigger(page: Page) {
  const mobile = (page.viewportSize()?.width ?? 1280) < 768;
  return mobile
    ? page.getByRole("button", { name: "Search…", exact: true })
    : page.locator("nav button").filter({ hasText: "Search…" });
}

function capture(id: string, rawText: string, createdAt: string) {
  return {
    attachments: null,
    audioDurationSec: null,
    createdAt,
    deletedAt: null,
    doneAt: null,
    id,
    mediaType: "text",
    mediaUrl: null,
    rawText,
    remindAt: null,
    remindHide: true,
    source: "web",
    todoAt: null,
    transcribedAt: null,
    transcript: null,
    transcriptionModel: null,
    transcriptionStatus: "none",
  };
}

// Nav

test("nav: search placeholder is short", async ({ page }) => {
  await goto(page, "/");
  const trigger = visibleSearchTrigger(page);
  await expect(trigger).toHaveAccessibleName(/^Search/);
  await expect(trigger).not.toHaveAccessibleName(/captures/i);
});

test("nav: settings affordance matches viewport", async ({
  page,
  isMobile,
}) => {
  await goto(page, "/");
  const settings = page
    .getByRole("link", { name: /^settings$/i })
    .filter({ visible: true });
  await expect(settings).toHaveCount(1);
  const visibleText = (await settings.textContent())?.trim();
  expect(visibleText).toBe(isMobile ? "" : "Settings");
});

// Captures

test("captures: current capture-first controls are visible", async ({
  page,
}) => {
  await goto(page, "/captures");
  await expect(page.getByText(/dump a thought/i)).toBeVisible();

  const composer = page.getByPlaceholder(/what's on your mind/i);
  await expect(composer).toBeVisible();
  expect(await composer.getAttribute("placeholder")).not.toContain("⌘");

  await expect(page.getByRole("button", { name: /attach/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^record$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /polish/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^all$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^todo$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^routine$/i })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^log$/i })).toHaveCount(0);
});

test("captures: recording can be stopped", async ({ page }) => {
  await page.addInitScript(() => {
    const track = { stop() {} };
    const mockStream = { getTracks: () => [track] };
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: async () => mockStream },
    });

    class MockMediaRecorder {
      state = "inactive";
      stream = mockStream;
      ondataavailable: ((event: { data: Blob }) => void) | null = null;
      onstop: (() => void) | null = null;

      start() {
        this.state = "recording";
      }

      stop() {
        this.state = "inactive";
        this.ondataavailable?.({
          data: new Blob(["audio"], { type: "audio/webm" }),
        });
        this.onstop?.();
      }
    }

    (
      window as unknown as { MediaRecorder: typeof MockMediaRecorder }
    ).MediaRecorder = MockMediaRecorder;
  });
  await page.route("**/api/captures/upload", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ id: "mock-audio-capture" }),
    }),
  );

  await goto(page, "/captures");
  await page.getByRole("button", { name: /^record$/i }).click();
  const stopButton = page.getByRole("button", { name: /stop/i });
  await expect(stopButton).toBeVisible();
  await stopButton.click();
  await expect(page.getByRole("button", { name: /^record$/i })).toBeVisible();
});

test("captures: delete action stays in the overflow menu", async ({ page }) => {
  await goto(page, "/captures");
  await expect(page.getByRole("button", { name: /^delete$/i })).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: /more options/i }).first(),
  ).toBeVisible();
});

test("captures: loads the next cursor page", async ({ page }) => {
  await page.route("**/api/captures/page**", async (route) => {
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(
        cursor === "next-page"
          ? {
              items: [
                capture(
                  "00000000-0000-4000-8000-000000000002",
                  "Second cursor page",
                  "2026-06-05T10:00:00Z",
                ),
              ],
              nextCursor: null,
            }
          : {
              items: [
                capture(
                  "00000000-0000-4000-8000-000000000001",
                  "First cursor page",
                  "2026-06-06T10:00:00Z",
                ),
              ],
              nextCursor: "next-page",
            },
      ),
    });
  });

  await goto(page, "/captures");
  await expect(page.getByText("First cursor page")).toBeVisible();
  await page.getByRole("button", { name: /load more/i }).click();
  await expect(page.getByText("Second cursor page")).toBeVisible();
});

test("captures: seeded markdown and precise timestamp render", async ({
  page,
}) => {
  await goto(page, "/captures");
  const seededCard = page
    .locator("li")
    .filter({ hasText: "E2E seeded alpha capture" });
  await expect(seededCard.locator(".ch-prose")).toBeVisible();
  await expect(seededCard.locator("strong")).toHaveText(
    "E2E seeded alpha capture",
  );
  await expect(seededCard.locator("[title]")).toHaveAttribute(
    "title",
    /\w{3} \d{1,2}, \d{4} · \d{1,2}:\d{2}(am|pm)/i,
  );
});

// Search and recall

test("search: capture result opens its context", async ({ page }) => {
  const result = capture(
    "00000000-0000-4000-8000-000000000003",
    "Recall anchor result",
    "2026-06-06T11:00:00Z",
  );
  await page.route("**/api/find**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        degraded: false,
        items: [
          {
            id: result.id,
            content: result.rawText,
            createdAt: result.createdAt,
            lexical: true,
            modality: "raw_text",
            score: 1,
          },
        ],
      }),
    }),
  );
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ items: [], nextCursor: null }),
    }),
  );
  await page.route("**/api/captures/context**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [result],
        anchorIndex: 0,
        hasEarlier: false,
        hasLater: false,
      }),
    }),
  );

  await goto(page, "/captures");
  await visibleSearchTrigger(page).click();
  await page.getByPlaceholder(/^search/i).fill("Recall anchor");
  await page.getByRole("button", { name: /recall anchor result/i }).click();

  await expect(page).toHaveURL(/\/captures\/context\?anchorId=/);
  await expect(page.getByText("Search match")).toBeVisible();
  await expect(page.getByText("Recall anchor result")).toBeVisible();
});

test("search: long result titles truncate with ellipsis", async ({ page }) => {
  const longTitle =
    "E2E searchable capture with a deliberately very long title that must truncate cleanly";
  await page.route("**/api/find**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        degraded: false,
        items: [
          {
            id: "00000000-0000-4000-8000-000000000004",
            content: longTitle,
            createdAt: "2026-06-06T11:00:00Z",
            lexical: true,
            modality: "raw_text",
            score: 1,
          },
        ],
      }),
    }),
  );

  await goto(page, "/");
  await visibleSearchTrigger(page).click();
  await page.getByPlaceholder(/^search/i).fill("searchable");
  const title = page.getByText(longTitle, { exact: true });
  await expect(title).toBeVisible();
  await expect(title).toHaveCSS("overflow", "hidden");
  await expect(title).toHaveCSS("text-overflow", "ellipsis");
});

test("search: escape closes the modal", async ({ page }) => {
  await goto(page, "/");
  await visibleSearchTrigger(page).click();
  const input = page.getByPlaceholder(/^search/i);
  await expect(input).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(input).toHaveCount(0);
});
