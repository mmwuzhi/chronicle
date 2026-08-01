import type { ExtensionSettings, QueueItem } from "@/core";

export type ExtensionMessage =
  | {
      type: "capture";
      payload: { selection?: string; title: string; pageURL: string };
    }
  | { type: "status" }
  | { type: "flush" }
  | { type: "retryFailed" }
  | { type: "removeFailed" }
  | { type: "clearQueue" }
  | { type: "updateSettings"; payload: ExtensionSettings };

export interface ExtensionStatus {
  configured: boolean;
  pending: number;
  failed: number;
  items: QueueItem[];
  error?: string;
}

export interface SettingsState {
  settings?: ExtensionSettings;
}
