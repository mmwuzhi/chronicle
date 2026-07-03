export type TodoState = "none" | "open" | "done";

// Derived progress over a set of captures (e.g. everything linked to an anchor):
// the "n/m done" figure is always computed at read time, never stored.
export function todoProgress(
  items: { todoAt?: string | null; doneAt?: string | null }[],
): { done: number; total: number } {
  let done = 0;
  let total = 0;
  for (const item of items) {
    if (!item.todoAt) continue;
    total += 1;
    if (item.doneAt) done += 1;
  }
  return { done, total };
}
