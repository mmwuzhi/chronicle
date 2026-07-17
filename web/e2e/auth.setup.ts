import { test as setup, type Page } from "@playwright/test";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const authFile = path.join(__dirname, ".auth.json");
const apiBase = process.env.E2E_API_URL ?? "http://localhost:8080";

async function seedData(page: Page) {
  const token = await page.evaluate(() => localStorage.getItem("access_token"));
  if (!token) throw new Error("No access token found after login");

  const headers = {
    Authorization: `Bearer ${token}`,
  };

  let cursor: string | null = null;
  let seededCaptureExists: boolean;
  do {
    const params = new URLSearchParams({
      limit: "100",
      includeReminded: "true",
    });
    if (cursor) params.set("cursor", cursor);
    const capturesRes = await page.request.get(
      `${apiBase}/captures/page?${params}`,
      { headers },
    );
    if (!capturesRes.ok()) {
      throw new Error(`Failed to list captures: ${capturesRes.status()}`);
    }
    const capturePage = (await capturesRes.json()) as {
      items: { rawText: string | null }[] | null;
      nextCursor: string | null;
    };
    seededCaptureExists = (capturePage.items ?? []).some((capture) =>
      capture.rawText?.includes("E2E seeded alpha capture"),
    );
    cursor = capturePage.nextCursor;
  } while (!seededCaptureExists && cursor);

  if (!seededCaptureExists) {
    const captureRes = await page.request.post(`${apiBase}/captures`, {
      headers,
      data: {
        rawText:
          "**E2E seeded alpha capture** with searchable markdown content. #todo",
        mediaType: "text",
      },
    });
    if (!captureRes.ok()) {
      throw new Error(`Failed to create capture: ${captureRes.status()}`);
    }
  }
}

setup("authenticate", async ({ page }) => {
  const email = process.env.E2E_EMAIL;
  const password = process.env.E2E_PASSWORD;
  if (!email || !password) {
    throw new Error("E2E_EMAIL and E2E_PASSWORD must be set in environment");
  }

  const loginProbe = await page.request.post(`${apiBase}/auth/login`, {
    data: { email, password },
  });
  if (!loginProbe.ok()) {
    const registerResponse = await page.request.post(
      `${apiBase}/auth/register`,
      {
        data: { email, password },
      },
    );
    if (!registerResponse.ok()) {
      throw new Error(
        `E2E account login failed and registration returned ${registerResponse.status()}`,
      );
    }
  }

  await page.goto("/login", { waitUntil: "domcontentloaded" });
  await page.fill('input[name="email"]', email);
  await page.fill('input[name="password"]', password);
  await page.click('button[type="submit"]');
  await page.waitForURL((url) => url.pathname !== "/login", {
    timeout: 10_000,
  });
  await seedData(page);

  await page.context().storageState({ path: authFile });
});
