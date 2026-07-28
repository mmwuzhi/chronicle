// The #todo system tag, mirroring the API's grammar
// (api/internal/capture/todotag.go): exactly #todo, #todo(done), or
// #todo(done:YYYY-MM-DD) as a standalone token — start-of-text or whitespace
// before, end or a character that cannot extend a tag name after. Group 2 is
// the token, group 3 the (done…) parameter.
export const TODO_TAG_RE =
  /(^|\s)(#todo(\(done(?::(\d{4}-\d{2}-\d{2}))?\))?)(?=[^\p{L}\p{N}_(-]|$)/u;
export const TODO_TAG = "#todo";

// Parse the first #todo token in text, mirroring the API's parseTodoTag
// (api/internal/capture/todotag.go). `present` is whether the standalone tag
// occurs at all; `done` is whether that first tag carries a (done…) parameter.
// The done *date* is intentionally not surfaced here — completion timestamps are
// derived server-side; the web only needs to know present/done to render the
// chip. Later occurrences are inert: the first tag is authoritative.
export function parseTodoTag(text: string): {
  present: boolean;
  done: boolean;
} {
  const m = TODO_TAG_RE.exec(text);
  if (!m) return { present: false, done: false };
  if (m[4] && !isCalendarDate(m[4])) {
    return { present: false, done: false };
  }
  return { present: true, done: Boolean(m[3]) };
}

function isCalendarDate(value: string): boolean {
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return (
    parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day
  );
}

// The trailing #-token being typed at the end of the composer text, used to
// drive the tag suggestion menu ("#", "#t", "#todo"…). Null when the text
// does not end in one.
export function trailingTagToken(value: string): string | null {
  const m = /(^|\s)(#[^\s#]*)$/.exec(value);
  return m ? m[2] : null;
}

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
