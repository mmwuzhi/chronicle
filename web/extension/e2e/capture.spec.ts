import { createServer, type Server } from "node:http";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
  chromium,
  expect,
  request,
  test,
  type APIRequestContext,
  type BrowserContext,
} from "@playwright/test";

let context: BrowserContext;
let api: APIRequestContext;
let server: Server;
let origin: string;
let extensionID: string;
let accessToken: string;
let captureTokenID: string;

test.beforeAll(async () => {
  server = createServer((request, response) => {
    if (request.method === "GET" && request.url === "/") {
      response.writeHead(200, { "Content-Type": "text/html" });
      response.end(
        "<title>Extension test page</title><main>Selected Chronicle text</main>",
      );
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise<void>((resolveListen) => {
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("test server did not expose a TCP port");
  }
  origin = `http://127.0.0.1:${address.port}`;

  const apiBaseURL = process.env.E2E_API_URL ?? "http://localhost:8080";
  const email = process.env.E2E_EMAIL;
  const password = process.env.E2E_PASSWORD;
  if (!email || !password) {
    throw new Error("E2E_EMAIL and E2E_PASSWORD must be set");
  }
  api = await request.newContext({ baseURL: apiBaseURL });
  const login = await api.post("/auth/login", { data: { email, password } });
  if (!login.ok()) {
    throw new Error(`extension E2E login failed: ${login.status()}`);
  }
  accessToken = ((await login.json()) as { accessToken: string }).accessToken;
  const tokenResponse = await api.post("/auth/tokens", {
    headers: { Authorization: `Bearer ${accessToken}` },
    data: { name: `Extension E2E ${Date.now()}` },
  });
  if (!tokenResponse.ok()) {
    throw new Error(`capture token creation failed: ${tokenResponse.status()}`);
  }
  const tokenBody = (await tokenResponse.json()) as {
    id: string;
    token: string;
  };
  captureTokenID = tokenBody.id;

  const userDataDir = await mkdtemp(resolve(tmpdir(), "chronicle-extension-"));
  const extensionPath = resolve(import.meta.dirname, "../dist");
  context = await chromium.launchPersistentContext(userDataDir, {
    // Chromium does not load Manifest V3 extensions in Playwright's headless
    // shell. CI runs this headed browser under xvfb.
    headless: false,
    args: [
      `--disable-extensions-except=${extensionPath}`,
      `--load-extension=${extensionPath}`,
    ],
  });
  let worker = context.serviceWorkers()[0];
  if (!worker) worker = await context.waitForEvent("serviceworker");
  extensionID = new URL(worker.url()).host;
  await worker.evaluate(
    async ({ apiBaseURL, token }) => {
      await chrome.storage.local.set({
        settings: { apiBaseURL, token },
      });
    },
    { apiBaseURL, token: tokenBody.token },
  );
});

test.afterAll(async () => {
  if (context) await context.close();
  if (api && captureTokenID) {
    await api.delete(`/auth/tokens/${captureTokenID}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
  }
  if (api) await api.dispose();
  await new Promise<void>((resolveClose, reject) => {
    server.close((error) => (error ? reject(error) : resolveClose()));
  });
});

test("page and selection actions enqueue exactly one Capture each", async () => {
  const source = await context.newPage();
  await source.goto(origin);
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionID}/popup.html`);

  await source.bringToFront();
  await popup.locator("#save-page").evaluate((button: HTMLButtonElement) => {
    button.click();
  });
  const pageText = `[Extension test page](${origin}/)`;
  await expect.poll(() => countCaptures(pageText)).toBe(1);

  await source.locator("main").selectText();
  await source.bringToFront();
  await popup
    .locator("#save-selection")
    .evaluate((button: HTMLButtonElement) => {
      button.click();
    });
  const selectionText = `Selected Chronicle text\n\n${pageText}`;
  await expect.poll(() => countCaptures(selectionText)).toBe(1);
  await expect.poll(() => countCaptures(pageText)).toBe(1);
});

async function countCaptures(rawText: string): Promise<number> {
  const response = await api.get(
    "/captures/page?limit=100&includeReminded=true",
    {
      headers: { Authorization: `Bearer ${accessToken}` },
    },
  );
  if (!response.ok()) {
    throw new Error(`capture list failed: ${response.status()}`);
  }
  const body = (await response.json()) as {
    items: Array<{ rawText: string | null; source: string }> | null;
  };
  return (body.items ?? []).filter(
    (capture) =>
      capture.rawText === rawText && capture.source === "browser_extension",
  ).length;
}
