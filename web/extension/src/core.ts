export interface ExtensionSettings {
  apiBaseURL: string;
  token: string;
}

export type QueueStatus = "pending" | "failed";

export interface QueueItem {
  id: string;
  rawText: string;
  createdAt: string;
  attempts: number;
  nextAttemptAt: string;
  status: QueueStatus;
  lastError?: string;
}

export const maxCaptureBytes = 100 * 1024;
export const maxQueueItems = 50;

export function queueAdmissionError(
  items: QueueItem[],
  rawText: string,
): string | null {
  if (new TextEncoder().encode(rawText).byteLength > maxCaptureBytes) {
    return "This selection is too large. Capture a smaller selection.";
  }
  if (items.length >= maxQueueItems) {
    return "The offline queue is full. Reconnect or remove failed captures first.";
  }
  return null;
}

export function normalizeAPIBaseURL(value: string): string {
  const parsed = new URL(value.trim());
  const localhost =
    parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  if (
    parsed.protocol !== "https:" &&
    !(parsed.protocol === "http:" && localhost)
  ) {
    throw new Error("Use HTTPS, or HTTP on localhost for development.");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error(
      "The API URL cannot include credentials, a query, or a fragment.",
    );
  }
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  return parsed.toString().replace(/\/$/, "");
}

export function permissionPattern(apiBaseURL: string): string {
  const parsed = new URL(apiBaseURL);
  return `${parsed.protocol}//${parsed.host}/*`;
}

function escapeMarkdownLabel(value: string): string {
  return value
    .replaceAll("\\", "\\\\")
    .replaceAll("[", "\\[")
    .replaceAll("]", "\\]");
}

function escapeMarkdownURL(value: string): string {
  return value
    .replaceAll("\\", "%5C")
    .replaceAll("(", "%28")
    .replaceAll(")", "%29");
}

export function formatPageCapture(title: string, pageURL: string): string {
  const trimmedTitle = title.trim();
  if (!trimmedTitle) return pageURL;
  return `[${escapeMarkdownLabel(trimmedTitle)}](${escapeMarkdownURL(pageURL)})`;
}

export function formatSelectionCapture(
  selection: string,
  title: string,
  pageURL: string,
): string {
  const trimmed = selection.trim();
  const source = formatPageCapture(title, pageURL);
  return trimmed ? `${trimmed}\n\n${source}` : source;
}

export function shouldRetry(status?: number): boolean {
  return status === undefined || status === 429 || status >= 500;
}

export function retryDelayMs(attempts: number): number {
  const baseDelay = 5_000;
  const maximumDelay = 5 * 60_000;
  return Math.min(maximumDelay, baseDelay * 2 ** Math.max(0, attempts - 1));
}

export function readyQueueItems(items: QueueItem[], now: Date): QueueItem[] {
  return items.filter(
    (item) =>
      item.status === "pending" &&
      new Date(item.nextAttemptAt).getTime() <= now.getTime(),
  );
}

export async function tokenFingerprint(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return Array.from(new Uint8Array(digest).slice(0, 12), (value) =>
    value.toString(16).padStart(2, "0"),
  ).join("");
}

export async function queueScopeKey(
  settings: ExtensionSettings,
): Promise<string> {
  const fingerprint = await tokenFingerprint(settings.token);
  return `queue:${settings.apiBaseURL}:${fingerprint}`;
}
