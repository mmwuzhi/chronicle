import type { ExtensionMessage, ExtensionStatus } from "@/messages";
import "@/styles.css";

function requiredElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`Missing required element: ${selector}`);
  return element;
}

const pageButton = requiredElement<HTMLButtonElement>("#save-page");
const selectionButton = requiredElement<HTMLButtonElement>("#save-selection");
const settingsButton = requiredElement<HTMLButtonElement>("#open-settings");
const status = requiredElement<HTMLElement>("#status");
const queueActions = requiredElement<HTMLElement>("#queue-actions");
const retryFailedButton = requiredElement<HTMLButtonElement>("#retry-failed");
const removeFailedButton = requiredElement<HTMLButtonElement>("#remove-failed");
const clearQueueButton = requiredElement<HTMLButtonElement>("#clear-queue");

settingsButton.addEventListener("click", () => {
  void chrome.runtime.openOptionsPage();
});
pageButton.addEventListener("click", () => void save(false));
selectionButton.addEventListener("click", () => void save(true));
retryFailedButton.addEventListener(
  "click",
  () => void runQueueAction("retryFailed"),
);
removeFailedButton.addEventListener(
  "click",
  () => void runQueueAction("removeFailed"),
);
clearQueueButton.addEventListener("click", () => {
  if (
    window.confirm(
      "Stop retrying and clear the local queue? A request already in progress may have reached Chronicle.",
    )
  ) {
    void runQueueAction("clearQueue");
  }
});
void refreshStatus();

async function runQueueAction(
  type: "retryFailed" | "removeFailed" | "clearQueue",
): Promise<void> {
  renderStatus(await sendMessage({ type }), false);
}

async function save(includeSelection: boolean): Promise<void> {
  try {
    const [tab] = await chrome.tabs.query({
      active: true,
      currentWindow: true,
    });
    if (!tab?.id || !tab.url) {
      throw new Error("This page cannot be captured.");
    }
    let selection: string | undefined;
    if (includeSelection) {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => window.getSelection()?.toString() ?? "",
      });
      selection = results[0]?.result ?? "";
      if (!selection.trim()) {
        throw new Error("Select some text on the page first.");
      }
    }
    const response = await sendMessage({
      type: "capture",
      payload: {
        selection,
        title: tab.title ?? "",
        pageURL: tab.url,
      },
    });
    renderStatus(response, true);
  } catch (error) {
    status.textContent =
      error instanceof Error ? error.message : "This page cannot be captured.";
    status.dataset.kind = "error";
  }
}

async function refreshStatus(): Promise<void> {
  renderStatus(await sendMessage({ type: "status" }), false);
}

function sendMessage(message: ExtensionMessage): Promise<ExtensionStatus> {
  return chrome.runtime.sendMessage(message) as Promise<ExtensionStatus>;
}

function renderStatus(value: ExtensionStatus, justSaved: boolean): void {
  queueActions.hidden = value.pending === 0 && value.failed === 0;
  retryFailedButton.hidden = value.failed === 0;
  removeFailedButton.hidden = value.failed === 0;
  if (value.error) {
    status.textContent = value.error;
    status.dataset.kind = "error";
    return;
  }
  if (!value.configured) {
    status.textContent =
      "Configure your Chronicle server and Capture Token first.";
    status.dataset.kind = "error";
    return;
  }
  if (value.failed > 0) {
    status.textContent = `${value.failed} capture${value.failed === 1 ? "" : "s"} need attention.`;
    status.dataset.kind = "error";
    return;
  }
  if (value.pending > 0) {
    status.textContent = `${value.pending} capture${value.pending === 1 ? "" : "s"} queued for retry.`;
    status.dataset.kind = "pending";
    return;
  }
  status.textContent = justSaved ? "Saved to Chronicle." : "Ready.";
  status.dataset.kind = "success";
}
