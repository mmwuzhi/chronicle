import { normalizeAPIBaseURL, permissionPattern } from "@/core";
import type { ExtensionStatus } from "@/messages";
import { getSettings } from "@/storage";
import "@/styles.css";

function requiredElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`Missing required element: ${selector}`);
  return element;
}

const form = requiredElement<HTMLFormElement>("#settings-form");
const apiInput = requiredElement<HTMLInputElement>("#api-base-url");
const tokenInput = requiredElement<HTMLInputElement>("#capture-token");
const status = requiredElement<HTMLElement>("#status");

void getSettings().then((settings) => {
  if (!settings) return;
  apiInput.value = settings.apiBaseURL;
  tokenInput.value = settings.token;
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  void save();
});

async function save(): Promise<void> {
  try {
    const apiBaseURL = normalizeAPIBaseURL(apiInput.value);
    const token = tokenInput.value.trim();
    if (!token.startsWith("chr_cap_")) {
      throw new Error("Enter a Chronicle create-only Capture Token.");
    }
    const granted = await chrome.permissions.request({
      origins: [permissionPattern(apiBaseURL)],
    });
    if (!granted)
      throw new Error(
        "Permission to contact this Chronicle server was denied.",
      );
    const result = (await chrome.runtime.sendMessage({
      type: "updateSettings",
      payload: { apiBaseURL, token },
    })) as ExtensionStatus;
    if (result.error) throw new Error(result.error);
    status.textContent = "Saved.";
    status.dataset.kind = "success";
  } catch (error) {
    status.textContent =
      error instanceof Error ? error.message : "Could not save settings.";
    status.dataset.kind = "error";
  }
}
