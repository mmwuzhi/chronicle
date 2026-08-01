import { type ExtensionSettings, type QueueItem, queueScopeKey } from "@/core";

const settingsKey = "settings";

export async function getSettings(): Promise<ExtensionSettings | null> {
  const result = await chrome.storage.local.get(settingsKey);
  const value = result[settingsKey];
  const candidate =
    typeof value === "object" && value !== null
      ? (value as Record<string, unknown>)
      : null;
  if (
    candidate === null ||
    typeof candidate.apiBaseURL !== "string" ||
    typeof candidate.token !== "string"
  ) {
    return null;
  }
  return {
    apiBaseURL: candidate.apiBaseURL,
    token: candidate.token,
  };
}

export async function setSettings(settings: ExtensionSettings): Promise<void> {
  await chrome.storage.local.set({ [settingsKey]: settings });
}

export async function getQueue(
  settings: ExtensionSettings,
): Promise<QueueItem[]> {
  const key = await queueScopeKey(settings);
  const result = await chrome.storage.local.get(key);
  return Array.isArray(result[key]) ? (result[key] as QueueItem[]) : [];
}

export async function setQueue(
  settings: ExtensionSettings,
  items: QueueItem[],
): Promise<void> {
  const key = await queueScopeKey(settings);
  await chrome.storage.local.set({ [key]: items });
}
