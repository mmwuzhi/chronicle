import { test, expect } from "@playwright/test";

async function goto(page: Parameters<typeof test>[1], path: string) {
  await page.goto(path, { waitUntil: "domcontentloaded" });
}

// ── Nav ───────────────────────────────────────────────────────────────────

test("nav: search placeholder is short", async ({ page }) => {
  await goto(page, "/");
  const trigger = page.locator(".ch-searchtrigger");
  await expect(trigger).toContainText("Search");
  await expect(trigger).not.toContainText("captures");
});

test("nav: settings affordance matches viewport", async ({
  page,
  isMobile,
}) => {
  await goto(page, "/");
  const icon = page.locator(".ch-settings-icon");
  const text = page.locator(".ch-settings-text");
  if (isMobile) {
    await expect(icon).toBeVisible();
    await expect(text).not.toBeVisible();
  } else {
    await expect(icon).not.toBeVisible();
    await expect(text).toBeVisible();
  }
});

// ── Projects ──────────────────────────────────────────────────────────────

test("projects: subtitle is visible", async ({ page }) => {
  await goto(page, "/projects");
  await expect(
    page.getByText("Colored buckets that group your tasks."),
  ).toBeVisible();
});

test("projects: create form is inline (single row)", async ({ page }) => {
  await goto(page, "/projects");
  const nameInput = page.getByPlaceholder(/new project name/i);
  const addButton = page.getByRole("button", { name: /add project/i });
  await expect(nameInput).toBeVisible();
  await expect(addButton).toBeVisible();
  // Both should be in the same flex row (input bounding box Y ≈ button bounding box Y)
  const inputBox = await nameInput.boundingBox();
  const buttonBox = await addButton.boundingBox();
  if (inputBox && buttonBox) {
    expect(Math.abs(inputBox.y - buttonBox.y)).toBeLessThan(20);
  }
});

test("projects: no direct Archive button on project rows", async ({ page }) => {
  await goto(page, "/projects");
  // Archive button should not be directly visible (it should be inside the ··· menu)
  await expect(
    page.getByRole("button", { name: /^archive$/i }).first(),
  ).not.toBeVisible();
});

// ── Task detail ───────────────────────────────────────────────────────────

async function goToFirstTask(page: Parameters<typeof test>[1]) {
  await goto(page, "/tasks");
  const taskLink = page.getByRole("link", {
    name: /E2E seeded alpha task/i,
  });
  await expect(taskLink).toBeVisible();
  const logsResponse = waitForLogEntries(page);
  await taskLink.click();
  expect((await logsResponse).status()).toBe(200);
}

function waitForLogEntries(page: Parameters<typeof test>[1]) {
  return page.waitForResponse(
    (response) =>
      response.url().includes("/log-entries") &&
      response.request().method() === "GET",
  );
}

test("task detail: has Start row", async ({ page }) => {
  await goToFirstTask(page);
  await expect(page.getByText(/^start$/i).first()).toBeVisible();
});

test("task detail: due date is a styled pill, not a native input", async ({
  page,
}) => {
  await goToFirstTask(page);
  await expect(page.locator('input[type="date"]')).toBeHidden();
  await expect(page.locator(".ch-datebtn").first()).toBeVisible();
});

test("task detail: start and due date use the same editable dialog", async ({
  page,
}) => {
  await goToFirstTask(page);
  const dateButtons = page.locator(".ch-datebtn");
  await expect(dateButtons).toHaveCount(2);
  for (let index = 0; index < 2; index += 1) {
    await dateButtons.nth(index).click();
    await expect(
      page.locator(".ch-date-dialog input[type=date]"),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: /^clear$/i })).toBeVisible();
    await page.getByRole("button", { name: /^cancel$/i }).click();
  }
});

test("task detail: date-only value survives save and reload", async ({
  page,
}) => {
  await goToFirstTask(page);
  const startButton = page.locator(".ch-datebtn").first();
  await startButton.click();
  await page.locator(".ch-date-dialog input[type=date]").fill("2026-06-10");
  const saveResponse = page.waitForResponse(
    (response) =>
      response.url().includes("/tasks/") &&
      response.request().method() === "PATCH",
  );
  await page.getByRole("button", { name: /^save$/i }).click();
  expect((await saveResponse).status()).toBe(200);
  await expect(startButton).toContainText("Jun 10");
  const logsResponse = waitForLogEntries(page);
  await page.reload();
  expect((await logsResponse).status()).toBe(200);
  await expect(page.locator(".ch-datebtn").first()).toContainText("Jun 10");
});

test("task detail: project is a custom dropdown, not a native select", async ({
  page,
}) => {
  await goToFirstTask(page);
  const selects = page.locator(".ch-divide select");
  await expect(selects).toHaveCount(0);
});

test("task detail: log placeholder mentions ⌘↵", async ({ page }) => {
  await goToFirstTask(page);
  const textarea = page.locator(".ch-textarea").first();
  const placeholder = await textarea.getAttribute("placeholder");
  expect(placeholder).toContain("⌘");
});

test("task detail: time is integrated into the log composer", async ({
  page,
}) => {
  await goToFirstTask(page);
  await expect(page.getByRole("button", { name: /^duration$/i })).toBeVisible();
  await expect(
    page.getByRole("button", { name: /^time range$/i }),
  ).toBeVisible();
  await expect(page.getByText(/^time$/i)).toHaveCount(0);
});

// ── Captures ──────────────────────────────────────────────────────────────

test("captures: subtitle is visible", async ({ page }) => {
  await goto(page, "/captures");
  await expect(page.getByText(/dump a thought/i)).toBeVisible();
});

test("captures: composer placeholder is short", async ({ page }) => {
  await goto(page, "/captures");
  const ta = page.locator(".ch-textarea").first();
  const ph = await ta.getAttribute("placeholder");
  expect(ph).toMatch(/what's on your mind/i);
  expect(ph).not.toContain("⌘");
});

test("captures: composer buttons have text labels", async ({ page }) => {
  await goto(page, "/captures");
  await expect(page.getByRole("button", { name: /attach/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /record/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /polish/i })).toBeVisible();
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

test("captures: filter tabs include routine and log", async ({ page }) => {
  await goto(page, "/captures");
  await expect(page.getByRole("button", { name: /^routine$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^log$/i })).toBeVisible();
});

test("captures: no direct Delete button on rows", async ({ page }) => {
  await goto(page, "/captures");
  await expect(
    page.getByRole("button", { name: /^delete$/i }).first(),
  ).not.toBeVisible();
});

test("captures: loads the next cursor page", async ({ page }) => {
  const capture = (id: string, rawText: string, createdAt: string) => ({
    id,
    rawText,
    mediaUrl: null,
    mediaType: "text",
    classifiedAs: "unclassified",
    taskId: null,
    source: "web",
    transcript: null,
    transcriptionStatus: "none",
    transcriptionModel: null,
    transcribedAt: null,
    audioDurationSec: null,
    createdAt,
  });
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

test("search: capture result opens its context", async ({ page }) => {
  const capture = {
    id: "00000000-0000-4000-8000-000000000003",
    rawText: "Recall anchor result",
    mediaUrl: null,
    mediaType: "text",
    classifiedAs: "idea",
    taskId: null,
    source: "web",
    transcript: null,
    transcriptionStatus: "none",
    transcriptionModel: null,
    transcribedAt: null,
    audioDurationSec: null,
    createdAt: "2026-06-06T11:00:00Z",
  };
  await page.route("**/api/search**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        captures: [
          {
            ...capture,
            matchedField: "rawText",
            preview: capture.rawText,
          },
        ],
        tasks: [],
        logEntries: [],
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
        items: [capture],
        anchorIndex: 0,
        hasEarlier: false,
        hasLater: false,
      }),
    }),
  );

  await goto(page, "/captures");
  await page
    .locator(".ch-searchtrigger, .ch-search-mobile")
    .filter({ visible: true })
    .first()
    .click();
  await page.locator(".ch-searchbar input").fill("Recall anchor");
  await page.getByRole("button", { name: /recall anchor result/i }).click();
  await page.getByRole("button", { name: /open in context/i }).click();

  await expect(page).toHaveURL(/\/captures\/context\?anchorId=/);
  await expect(page.getByText("Search match")).toBeVisible();
  await expect(page.getByText("Recall anchor result")).toBeVisible();
});

test("captures: timestamp uses Jun 3 · 8:51am format", async ({ page }) => {
  await goto(page, "/captures");
  const meta = page.locator(".ch-meta").first();
  if ((await meta.count()) > 0) {
    const text = await meta.textContent();
    expect(text).toMatch(/·\s*\d/);
    expect(text).toMatch(/am|pm/i);
  }
});

// ── Markdown rendering ────────────────────────────────────────────────────

test("markdown: capture display uses ch-prose renderer", async ({ page }) => {
  await goto(page, "/captures");
  await page.locator(".ch-row").first().waitFor({ timeout: 5_000 });
  await expect(page.locator(".ch-prose").first()).toBeVisible();
});

// ── Input behavior ────────────────────────────────────────────────────────

test("log time: minutes rejects non-digits and respects range maximum", async ({
  page,
}) => {
  await goToFirstTask(page);
  const editor = page.locator(".ch-log-time-editor").first();
  const rangeButton = editor.getByRole("button", { name: /^time range$/i });
  await rangeButton.click();
  await expect(rangeButton).toHaveClass(/active/);
  const input = editor.locator('input[inputmode="numeric"]');
  await expect(input).toHaveJSProperty("type", "text");
  await input.fill("12abc");
  await expect(input).toHaveValue("12");
  const dateInputs = editor.locator('input[type="datetime-local"]');
  await dateInputs.nth(0).fill("2026-06-06T09:00");
  await dateInputs.nth(1).fill("2026-06-06T09:30");
  await input.fill("90");
  await expect(input).toHaveValue("30");
});

test("log time: can save a time-only duration entry", async ({ page }) => {
  await goToFirstTask(page);
  const editor = page.locator(".ch-log-time-editor").first();
  const durationButton = editor.getByRole("button", { name: /^duration$/i });
  await durationButton.click();
  await expect(durationButton).toHaveClass(/active/);
  const input = editor.locator('input[inputmode="numeric"]');
  await input.fill("7");
  const matchingChips = page
    .locator(".ch-time-chip.ch-log-time-chip")
    .filter({ hasText: "7m" });
  const beforeCount = await matchingChips.count();
  const saveResponse = page.waitForResponse(
    (response) =>
      response.url().includes("/log-entries") &&
      response.request().method() === "POST",
  );
  await page.getByRole("button", { name: /^add note$/i }).click();
  expect((await saveResponse).status()).toBe(200);
  await expect(matchingChips).toHaveCount(beforeCount + 1);
});

// ── Search modal ──────────────────────────────────────────────────────────

test("search: only one close affordance (no X icon)", async ({ page }) => {
  await goto(page, "/");
  await page
    .locator(".ch-searchtrigger, .ch-search-mobile")
    .filter({ visible: true })
    .first()
    .click();
  await expect(page.getByRole("button", { name: /^close$/i })).toHaveCount(0);
});

test("search: long result titles truncate with ellipsis", async ({ page }) => {
  await goto(page, "/");
  await page
    .locator(".ch-searchtrigger, .ch-search-mobile")
    .filter({ visible: true })
    .first()
    .click();
  await page.locator(".ch-searchbar input").fill("a");
  await page.waitForTimeout(500);
  const titles = page.locator(".ch-sresult .s-title");
  await expect(titles.first()).toBeVisible();
  const first = titles.first();
  const overflowProp = await first.evaluate(
    (el) => getComputedStyle(el).overflow,
  );
  expect(overflowProp).toBe("hidden");
  const displayProp = await first.evaluate(
    (el) => getComputedStyle(el).display,
  );
  expect(displayProp).toBe("block");
});
