// The #todo system tag, mirroring the API's grammar
// (api/internal/capture/todotag.go): exactly #todo, #todo(done), or
// #todo(done:YYYY-MM-DD) as a standalone token — start-of-text or whitespace
// before, end or a character that cannot extend a tag name after. Group 2 is
// the token, group 3 the (done…) parameter.
export const TODO_TAG_RE =
  /(^|\s)(#todo(\(done(?::\d{4}-\d{2}-\d{2})?\))?)(?=[^\p{L}\p{N}_(-]|$)/u;

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
