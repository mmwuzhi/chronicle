/// <reference types="node" />
// This test runs only under vitest (Node), so it reads the shared fixture from
// disk. The app tsconfig restricts `types` to vite/client, so pull in Node's
// types for just this file — the reference directive is honoured regardless.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { parseTodoTag } from "@/utils/todo";

// The #todo grammar is defined in Go, web, and desktop, and the root CLAUDE.md
// requires all three to change together. All three parity tests consume this
// fixture. The web side asserts present/done only: completion timestamps are
// derived server-side, so the fixture's doneDate field is verified by Go.

type ParityCase = {
  desc: string;
  text: string;
  present: boolean;
  done: boolean;
  doneDate: string;
};

const fixturePath = fileURLToPath(
  new URL("../../../shared/fixtures/todo-tag.json", import.meta.url),
);
const { cases } = JSON.parse(readFileSync(fixturePath, "utf8")) as {
  cases: ParityCase[];
};

describe("todo tag grammar parity (shared fixture)", () => {
  it("loads a non-empty fixture", () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const c of cases) {
    it(c.desc, () => {
      const got = parseTodoTag(c.text);
      expect(got.present).toBe(c.present);
      expect(got.done).toBe(c.done);
    });
  }
});
