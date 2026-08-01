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
