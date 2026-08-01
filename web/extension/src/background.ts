import {
  formatPageCapture,
  formatSelectionCapture,
  queueAdmissionError,
  readyQueueItems,
  retryDelayMs,
  shouldRetry,
  type QueueItem,
} from "@/core";
import type { ExtensionMessage, ExtensionStatus } from "@/messages";
import { getQueue, getSettings, setQueue, setSettings } from "@/storage";

const pageMenuID = "chronicle-save-page";
const selectionMenuID = "chronicle-save-selection";
let queueLock: Promise<void> = Promise.resolve();
let flushLock: Promise<ExtensionStatus> = Promise.resolve(emptyStatus());
const requestTimeoutMs = 30_000;

ensureFlushAlarm();

chrome.runtime.onInstalled.addListener(() => {
  void chrome.contextMenus.removeAll().then(() => {
    chrome.contextMenus.create({
      id: pageMenuID,
      title: "Save page to Chronicle",
      contexts: ["page"],
    });
    chrome.contextMenus.create({
      id: selectionMenuID,
      title: "Save selection to Chronicle",
      contexts: ["selection"],
    });
  });
  ensureFlushAlarm();
});

chrome.runtime.onStartup.addListener(() => {
  ensureFlushAlarm();
  void flushCurrentQueue();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "chronicle-flush") void flushCurrentQueue();
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab?.url) return;
  const selection =
    info.menuItemId === selectionMenuID ? info.selectionText : undefined;
  void enqueueCapture({
    selection,
    title: tab.title ?? "",
    pageURL: tab.url,
  });
});

chrome.runtime.onMessage.addListener(
  (
    message: ExtensionMessage,
    _sender,
    sendResponse: (response: ExtensionStatus) => void,
  ) => {
    if (message.type === "capture") {
      void enqueueCapture(message.payload).then(sendResponse);
      return true;
    }
    if (message.type === "flush") {
      void flushCurrentQueue().then(sendResponse);
      return true;
    }
    if (message.type === "retryFailed") {
      void retryFailedItems().then(sendResponse);
      return true;
    }
    if (message.type === "removeFailed") {
      void removeQueueItems(true).then(sendResponse);
      return true;
    }
    if (message.type === "clearQueue") {
      void removeQueueItems(false).then(sendResponse);
      return true;
    }
    if (message.type === "updateSettings") {
      void updateSettings(message.payload).then(sendResponse);
      return true;
    }
    void currentStatus().then(sendResponse);
    return true;
  },
);

async function enqueueCapture(payload: {
  selection?: string;
  title: string;
  pageURL: string;
}): Promise<ExtensionStatus> {
  const rawText =
    payload.selection === undefined
      ? formatPageCapture(payload.title, payload.pageURL)
      : formatSelectionCapture(
          payload.selection,
          payload.title,
          payload.pageURL,
        );
  const now = new Date().toISOString();
  const item: QueueItem = {
    id: crypto.randomUUID(),
    rawText,
    createdAt: now,
    attempts: 0,
    nextAttemptAt: now,
    status: "pending",
  };
  let settings: Awaited<ReturnType<typeof getSettings>> = null;
  let admissionError: string | null = null;
  await withQueueLock(async () => {
    settings = await getSettings();
    if (!settings) return;
    const items = await getQueue(settings);
    admissionError = queueAdmissionError(items, rawText);
    if (admissionError) return;
    items.push(item);
    await setQueue(settings, items);
  });
  if (!settings) return emptyStatus();
  if (admissionError) {
    return { ...(await currentStatus()), error: admissionError };
  }
  await flushCurrentQueue();
  return currentStatus();
}

async function updateSettings(
  nextSettings: NonNullable<Awaited<ReturnType<typeof getSettings>>>,
): Promise<ExtensionStatus> {
  let error: string | undefined;
  await withQueueLock(async () => {
    const current = await getSettings();
    if (
      current &&
      (current.apiBaseURL !== nextSettings.apiBaseURL ||
        current.token !== nextSettings.token) &&
      (await getQueue(current)).length > 0
    ) {
      error =
        "Retry or remove the current queue from the popup before changing the server or token.";
      return;
    }
    await setSettings(nextSettings);
  });
  const value = await currentStatus();
  return error ? { ...value, error } : value;
}

async function flushCurrentQueue(): Promise<ExtensionStatus> {
  const next = flushLock.then(
    flushCurrentQueueUnlocked,
    flushCurrentQueueUnlocked,
  );
  flushLock = next.catch(() => emptyStatus());
  return next;
}

async function flushCurrentQueueUnlocked(): Promise<ExtensionStatus> {
  const settings = await getSettings();
  if (!settings) return emptyStatus();
  const ready = await withQueueLock(async () => {
    const items = await getQueue(settings);
    return readyQueueItems(items, new Date()).map((item) => ({ ...item }));
  });
  for (const item of ready) {
    let response: Response | undefined;
    let networkError: string | undefined;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
    try {
      response = await fetch(`${settings.apiBaseURL}/captures`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${settings.token}`,
          "Content-Type": "application/json",
          "Idempotency-Key": item.id,
        },
        body: JSON.stringify({
          rawText: item.rawText,
          mediaType: "text",
          source: "browser_extension",
        }),
        signal: controller.signal,
      });
    } catch (error) {
      networkError =
        error instanceof DOMException && error.name === "AbortError"
          ? "Request timed out"
          : "Network error";
    } finally {
      clearTimeout(timeout);
    }
    await withQueueLock(async () => {
      const items = await getQueue(settings);
      const current = items.find((candidate) => candidate.id === item.id);
      if (!current || current.status !== "pending") return;
      if (response?.ok) {
        const index = items.indexOf(current);
        items.splice(index, 1);
      } else {
        current.attempts += 1;
        if (response && !shouldRetry(response.status)) {
          current.status = "failed";
          current.lastError = `HTTP ${response.status}`;
        } else {
          current.nextAttemptAt = new Date(
            Date.now() + retryDelayMs(current.attempts),
          ).toISOString();
          current.lastError = response
            ? `HTTP ${response.status}`
            : networkError;
        }
      }
      await setQueue(settings, items);
      await updateBadge(items);
    });
  }
  return currentStatus();
}

async function retryFailedItems(): Promise<ExtensionStatus> {
  const settings = await getSettings();
  if (!settings) return emptyStatus();
  await withQueueLock(async () => {
    const items = await getQueue(settings);
    const now = new Date().toISOString();
    for (const item of items) {
      if (item.status !== "failed") continue;
      item.status = "pending";
      item.nextAttemptAt = now;
      delete item.lastError;
    }
    await setQueue(settings, items);
  });
  return flushCurrentQueue();
}

async function removeQueueItems(failedOnly: boolean): Promise<ExtensionStatus> {
  const next = flushLock.then(
    () => removeQueueItemsUnlocked(failedOnly),
    () => removeQueueItemsUnlocked(failedOnly),
  );
  flushLock = next.catch(() => emptyStatus());
  return next;
}

async function removeQueueItemsUnlocked(
  failedOnly: boolean,
): Promise<ExtensionStatus> {
  const settings = await getSettings();
  if (!settings) return emptyStatus();
  await withQueueLock(async () => {
    const items = await getQueue(settings);
    const kept = failedOnly
      ? items.filter((item) => item.status !== "failed")
      : [];
    await setQueue(settings, kept);
    await updateBadge(kept);
  });
  return currentStatus();
}

function ensureFlushAlarm(): void {
  chrome.alarms.create("chronicle-flush", { periodInMinutes: 1 });
}

async function currentStatus(): Promise<ExtensionStatus> {
  const settings = await getSettings();
  if (!settings) return emptyStatus();
  const items = await getQueue(settings);
  await updateBadge(items);
  return {
    configured: true,
    pending: items.filter((item) => item.status === "pending").length,
    failed: items.filter((item) => item.status === "failed").length,
    items,
  };
}

function emptyStatus(): ExtensionStatus {
  return { configured: false, pending: 0, failed: 0, items: [] };
}

async function updateBadge(items: QueueItem[]): Promise<void> {
  const failed = items.filter((item) => item.status === "failed").length;
  const pending = items.filter((item) => item.status === "pending").length;
  await chrome.action.setBadgeBackgroundColor({
    color: failed > 0 ? "#b42318" : "#7066d9",
  });
  await chrome.action.setBadgeText({
    text: failed > 0 ? "!" : pending > 0 ? String(pending) : "",
  });
}

async function withQueueLock<T>(task: () => Promise<T>): Promise<T> {
  const next = queueLock.then(task, task);
  queueLock = next.then(
    () => undefined,
    () => undefined,
  );
  return next;
}
