import { expect, test } from "@playwright/test";

test.use({ storageState: { cookies: [], origins: [] } });

test("private Capture deep links require sign-in before rendering the app", async ({
  page,
}) => {
  const deepLink =
    "/captures/context?anchorId=6f12403e-0e0a-4c57-bed9-bedd253a8a7b";

  await page.goto(deepLink, { waitUntil: "domcontentloaded" });

  await expect(page).toHaveURL(/\/login$/);
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await expect(page.getByRole("navigation")).toHaveCount(0);

  const email = process.env.E2E_EMAIL;
  const password = process.env.E2E_PASSWORD;
  if (!email || !password) throw new Error("E2E credentials are required");

  await page.locator('input[name="email"]').fill(email);
  await page.locator('input[name="password"]').fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();

  await expect(page).toHaveURL(new RegExp(`${deepLink.replace("?", "\\?")}$`));
});

test("invalid public links use the standard page not found screen", async ({
  page,
}) => {
  await page.goto("/s/6f12403e-0e0a-4c57-bed9-bedd253a8a7b#invalid", {
    waitUntil: "domcontentloaded",
  });

  await expect(
    page.getByRole("heading", { name: "Page not found" }),
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "Return home" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Sign in" })).toHaveCount(0);
});
