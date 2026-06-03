import { test, expect } from "@playwright/test";

// ── Nav ───────────────────────────────────────────────────────────────────

test("nav: search placeholder is short", async ({ page }) => {
  await page.goto("/");
  const trigger = page.locator(".ch-searchtrigger");
  await expect(trigger).toContainText("Search");
  await expect(trigger).not.toContainText("captures");
});

test("mobile: settings shows gear icon, not text", async ({
  page,
  isMobile,
}) => {
  if (!isMobile) return test.skip();
  await page.goto("/");
  const icon = page.locator(".ch-settings-icon");
  const text = page.locator(".ch-settings-text");
  await expect(icon).toBeVisible();
  await expect(text).not.toBeVisible();
});

test("desktop: settings shows text, not gear icon", async ({
  page,
  isMobile,
}) => {
  if (isMobile) return test.skip();
  await page.goto("/");
  const icon = page.locator(".ch-settings-icon");
  const text = page.locator(".ch-settings-text");
  await expect(icon).not.toBeVisible();
  await expect(text).toBeVisible();
});

// ── Projects ──────────────────────────────────────────────────────────────

test("projects: subtitle is visible", async ({ page }) => {
  await page.goto("/projects");
  await expect(
    page.getByText("Colored buckets that group your tasks."),
  ).toBeVisible();
});

test("projects: create form is inline (single row)", async ({ page }) => {
  await page.goto("/projects");
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
  await page.goto("/projects");
  // Archive button should not be directly visible (it should be inside the ··· menu)
  await expect(
    page.getByRole("button", { name: /^archive$/i }).first(),
  ).not.toBeVisible();
});

// ── Task detail ───────────────────────────────────────────────────────────

async function goToFirstTask(page: Parameters<typeof test>[1]) {
  await page.goto("/tasks");
  const taskLink = page.locator(".ch-row a").first();
  await taskLink.waitFor({ timeout: 5_000 }).catch(() => null);
  const count = await page.locator(".ch-row a").count();
  if (count === 0) {
    test.skip();
    return false;
  }
  await taskLink.click();
  return true;
}

test("task detail: has Start row", async ({ page }) => {
  const ok = await goToFirstTask(page);
  if (!ok) return;
  await expect(page.getByText(/^start$/i).first()).toBeVisible();
});

test("task detail: due date is a styled pill, not a native input", async ({
  page,
}) => {
  const ok = await goToFirstTask(page);
  if (!ok) return;
  // Native date input should be hidden
  await expect(page.locator('input[type="date"]')).toBeHidden();
  // .ch-datebtn should be visible
  await expect(page.locator(".ch-datebtn").first()).toBeVisible();
});

test("task detail: project is a custom dropdown, not a native select", async ({
  page,
}) => {
  const ok = await goToFirstTask(page);
  if (!ok) return;
  // Native select for project should not exist in meta card area
  const selects = page.locator(".ch-divide select");
  await expect(selects).toHaveCount(0);
});

test("task detail: log placeholder mentions ⌘↵", async ({ page }) => {
  const ok = await goToFirstTask(page);
  if (!ok) return;
  const textarea = page.locator(".ch-textarea").first();
  const placeholder = await textarea.getAttribute("placeholder");
  expect(placeholder).toContain("⌘");
});

test("task detail: timer has no Tailwind classes", async ({ page }) => {
  const ok = await goToFirstTask(page);
  if (!ok) return;
  // Find the timer card (contains the clock area)
  const timerCard = page
    .locator(".ch-card")
    .filter({ hasText: /—|h|m/ })
    .first();
  const html = await timerCard.innerHTML();
  expect(html).not.toMatch(
    /class="[^"]*(?:text-gray|bg-white|rounded-lg|flex-col)/,
  );
});

// ── Captures ──────────────────────────────────────────────────────────────

test("captures: subtitle is visible", async ({ page }) => {
  await page.goto("/captures");
  await expect(page.getByText(/dump a thought/i)).toBeVisible();
});

test("captures: composer placeholder is short", async ({ page }) => {
  await page.goto("/captures");
  const ta = page.locator(".ch-textarea").first();
  const ph = await ta.getAttribute("placeholder");
  expect(ph).toMatch(/what's on your mind/i);
  expect(ph).not.toContain("⌘");
});

test("captures: composer buttons have text labels", async ({ page }) => {
  await page.goto("/captures");
  await expect(page.getByRole("button", { name: /attach/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /record/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /polish/i })).toBeVisible();
});

test("captures: filter tabs include routine and log", async ({ page }) => {
  await page.goto("/captures");
  await expect(page.getByRole("button", { name: /^routine$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^log$/i })).toBeVisible();
});

test("captures: no direct Delete button on rows", async ({ page }) => {
  await page.goto("/captures");
  await expect(
    page.getByRole("button", { name: /^delete$/i }).first(),
  ).not.toBeVisible();
});

test("captures: timestamp uses Jun 3 · 8:51am format", async ({ page }) => {
  await page.goto("/captures");
  const meta = page.locator(".ch-meta").first();
  if ((await meta.count()) > 0) {
    const text = await meta.textContent();
    expect(text).toMatch(/·\s*\d/);
    expect(text).toMatch(/am|pm/i);
  }
});
