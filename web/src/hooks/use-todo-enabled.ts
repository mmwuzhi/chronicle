import { useSyncExternalStore } from "react";

// Client-side preference: whether the todo feature (checkbox, tab, progress) is
// shown at all. Purely cosmetic — todo data is kept either way, so flipping the
// switch back loses nothing.
const KEY = "chronicle.todoEnabled";

const listeners = new Set<() => void>();

export function todoEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) !== "false";
  } catch {
    return true;
  }
}

export function setTodoEnabled(enabled: boolean): void {
  try {
    localStorage.setItem(KEY, String(enabled));
  } catch {
    // Storage unavailable (private mode): the toggle just doesn't persist.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  // Cross-tab sync: storage events only fire in other tabs.
  const onStorage = (e: StorageEvent) => {
    if (e.key === KEY) listener();
  };
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", onStorage);
  };
}

export function useTodoEnabled(): boolean {
  return useSyncExternalStore(subscribe, todoEnabled);
}
