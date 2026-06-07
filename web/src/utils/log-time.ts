export type LogTimeMode = "none" | "duration" | "range";

export interface LogTimeDraft {
  mode: LogTimeMode;
  minutes: string;
  startedAt: string;
  endedAt: string;
}

export interface LogTimePayload {
  inputMode: "duration" | "range";
  durationSec: number;
  startedAt?: string;
  endedAt?: string;
}

export const emptyLogTimeDraft: LogTimeDraft = {
  mode: "none",
  minutes: "",
  startedAt: "",
  endedAt: "",
};

export function logTimeRangeMinutes(value: LogTimeDraft): number | undefined {
  if (!value.startedAt || !value.endedAt) return undefined;
  const milliseconds =
    new Date(value.endedAt).getTime() - new Date(value.startedAt).getTime();
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return undefined;
  return Math.floor(milliseconds / 60_000);
}

function toLocalDateTime(value: string): string {
  const date = new Date(value);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

export function logTimeDraftFromValue(
  value:
    | {
        inputMode: string;
        durationSec: number;
        startedAt: string;
        endedAt: string;
      }
    | null
    | undefined,
): LogTimeDraft {
  if (!value) return { ...emptyLogTimeDraft };
  return {
    mode: value.inputMode === "range" ? "range" : "duration",
    minutes: String(Math.max(1, Math.round(value.durationSec / 60))),
    startedAt: toLocalDateTime(value.startedAt),
    endedAt: toLocalDateTime(value.endedAt),
  };
}

export function logTimePayload(draft: LogTimeDraft): LogTimePayload | null {
  if (draft.mode === "none") return null;
  const minutes = Number.parseInt(draft.minutes, 10);
  if (!Number.isFinite(minutes) || minutes <= 0) return null;
  if (draft.mode === "duration") {
    return { inputMode: "duration", durationSec: minutes * 60 };
  }
  if (!draft.startedAt || !draft.endedAt) return null;
  const maximumMinutes = logTimeRangeMinutes(draft);
  if (maximumMinutes == null || minutes > maximumMinutes) return null;
  return {
    inputMode: "range",
    durationSec: minutes * 60,
    startedAt: new Date(draft.startedAt).toISOString(),
    endedAt: new Date(draft.endedAt).toISOString(),
  };
}
