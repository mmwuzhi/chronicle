import { test as setup } from "@playwright/test";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const authFile = path.join(__dirname, ".auth.json");
const apiBase = process.env.E2E_API_URL ?? "http://localhost:8080";

async function seedData(page: Parameters<Parameters<typeof setup>[1]>[0]) {
  const token = await page.evaluate(() => localStorage.getItem("access_token"));
  if (!token) throw new Error("No access token found after login");

  const headers = {
    Authorization: `Bearer ${token}`,
  };

  const tasksRes = await page.request.get(`${apiBase}/tasks`, { headers });
  if (!tasksRes.ok()) {
    throw new Error(`Failed to list tasks: ${tasksRes.status()}`);
  }
  const tasks = (await tasksRes.json()) as { id: string; title: string }[];
  let task = tasks.find((item) => item.title.includes("E2E seeded alpha task"));
  if (!task) {
    const startAt = new Date("2026-06-03T08:30:00.000Z").toISOString();
    const dueAt = new Date("2026-06-06T08:30:00.000Z").toISOString();
    const taskRes = await page.request.post(`${apiBase}/tasks`, {
      headers,
      data: {
        title: "E2E seeded alpha task with a very long searchable title",
        type: "task",
        startAt,
        dueAt,
      },
    });
    if (!taskRes.ok()) {
      throw new Error(`Failed to create task: ${taskRes.status()}`);
    }
    task = (await taskRes.json()) as { id: string; title: string };
  }

  const entriesRes = await page.request.get(
    `${apiBase}/log-entries?taskId=${task.id}`,
    { headers },
  );
  const entries = entriesRes.ok()
    ? ((await entriesRes.json()) as { body: string }[])
    : [];
  if (!entries.some((entry) => entry.body.includes("E2E seeded alpha note"))) {
    const logRes = await page.request.post(`${apiBase}/log-entries`, {
      headers,
      data: {
        taskId: task.id,
        body: "E2E seeded alpha note for task detail coverage.",
      },
    });
    if (!logRes.ok()) {
      throw new Error(`Failed to create log entry: ${logRes.status()}`);
    }
  }

  const timeRes = await page.request.get(
    `${apiBase}/time-blocks?taskId=${task.id}`,
    { headers },
  );
  const blocks = timeRes.ok()
    ? ((await timeRes.json()) as { durationSec: number | null }[])
    : [];
  if (!blocks.some((block) => block.durationSec === 2700)) {
    const blockRes = await page.request.post(`${apiBase}/time-blocks`, {
      headers,
      data: {
        taskId: task.id,
        startedAt: "2026-06-03T08:30:00.000Z",
        endedAt: "2026-06-03T09:15:00.000Z",
        durationSec: 2700,
      },
    });
    if (!blockRes.ok()) {
      throw new Error(`Failed to create time block: ${blockRes.status()}`);
    }
  }

  const capturesRes = await page.request.get(`${apiBase}/captures`, {
    headers,
  });
  if (!capturesRes.ok()) {
    throw new Error(`Failed to list captures: ${capturesRes.status()}`);
  }
  const captures = (await capturesRes.json()) as {
    rawText: string | null;
  }[];
  if (
    !captures.some((capture) =>
      capture.rawText?.includes("E2E seeded alpha capture"),
    )
  ) {
    const captureRes = await page.request.post(`${apiBase}/captures`, {
      headers,
      data: {
        rawText:
          "**E2E seeded alpha capture** with searchable markdown content.",
        mediaType: "text",
        classifiedAs: "unclassified",
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

  await page.goto("/login");
  await page.fill('input[name="email"]', email);
  await page.fill('input[name="password"]', password);
  await page.click('button[type="submit"]');
  await page.waitForURL((url) => url.pathname !== "/login", {
    timeout: 10_000,
  });
  await seedData(page);

  await page.context().storageState({ path: authFile });
});
