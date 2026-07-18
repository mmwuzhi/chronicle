/// <reference types="node" />
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const localeFiles = [
  "zh/common.json",
  "zh/captures.json",
  "zh/dashboard.json",
  "zh/settings.json",
  "ja/common.json",
  "ja/captures.json",
  "ja/dashboard.json",
  "ja/settings.json",
];

describe("Capture terminology", () => {
  for (const relativePath of localeFiles) {
    it(`${relativePath} keeps the product noun untranslated`, () => {
      const file = fileURLToPath(new URL(relativePath, import.meta.url));
      const copy = readFileSync(file, "utf8");

      expect(copy).not.toMatch(/捕获|キャプチャ/);
    });
  }
});
