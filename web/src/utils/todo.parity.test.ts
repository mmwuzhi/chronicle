/// <reference types="node" />
// This test runs only under vitest (Node), so it reads the shared fixture from
// disk. The app tsconfig restricts `types` to vite/client, so pull in Node's
// types for just this file — the reference directive is honoured regardless.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { parseTodoTag } from "./todo";

// The #todo grammar is defined twice — TODO_TAG_RE here and todoTagRe in
// api/internal/capture/todotag.go — and the root CLAUDE.md requires them to
// change together. This drives the web regex against the shared golden fixture;
// api/internal/capture/todotag_parity_test.go drives the Go parser against the
// same file. The web side asserts present/done only: the web regex deliberately
// does not capture the done date (completion timestamps are derived server-side),
// so the fixture's doneDate field is verified on the Go side.

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
