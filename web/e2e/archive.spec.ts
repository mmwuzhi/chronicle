import { expect, test } from "@playwright/test";

test("settings exports and merge-imports a complete archive", async ({
  page,
  isMobile,
}) => {
  test.skip(isMobile, "one real archive round-trip is sufficient");

  await page.goto("/settings", { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: "Data", exact: true }).click();
  await expect(page.getByText("Data & portability")).toBeVisible();

  const downloadPromise = page.waitForEvent("download");
  await page
    .getByRole("button", { name: "Download archive", exact: true })
    .click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toMatch(/^chronicle-.*\.zip$/);
  const archivePath = await download.path();
  expect(archivePath).not.toBeNull();

  await page
    .getByLabel("Import archive", { exact: true })
    .setInputFiles(archivePath!);
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("button").filter({ hasText: "Import archive" }).click();

  await expect(page.getByText("Import complete")).toBeVisible({
    timeout: 30_000,
  });
  await expect(
    page.getByText(/Created 0, skipped [1-9]\d*, conflict copies 0, media 0,/),
  ).toBeVisible();
});

test("settings imports Markdown content and can move the batch to Trash", async ({
  page,
  isMobile,
}) => {
  test.skip(isMobile, "one desktop content-import flow is sufficient");

  await page.goto("/settings", { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: "Data", exact: true }).click();
  const markdownFile = {
    name: "京都-e2e-import.md",
    mimeType: "text/markdown",
    buffer: Buffer.from(`---
title: E2E imported memory
tags: [portable]
---
Remember the vermilion bridge.`),
  };
  await page.getByLabel("Import Markdown & text").setInputFiles(markdownFile);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Import files" }).click();

  await expect(page.getByText("Content import complete")).toBeVisible({
    timeout: 30_000,
  });
  await expect(page.getByText(/Created 1, skipped 0, links 0/)).toBeVisible();

  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Move this import to Trash" }).click();
  await expect(
    page.getByRole("button", { name: "Moved to Trash" }),
  ).toBeDisabled();

  await page.getByLabel("Import Markdown & text").setInputFiles(markdownFile);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Import files" }).click();
  await expect(page.getByText(/Created 1, skipped 0, links 0/)).toBeVisible();
});
