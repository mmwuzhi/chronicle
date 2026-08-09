import { beforeEach, describe, expect, it } from "vitest";
import {
  normalizeInternalRedirect,
  rememberPostAuthRedirect,
  takePostAuthRedirect,
} from "@/lib/post-auth-redirect";

class MemoryStorage {
  private values = new Map<string, string>();

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

Object.defineProperty(globalThis, "sessionStorage", {
  value: new MemoryStorage(),
  configurable: true,
});

describe("post-auth redirect", () => {
  beforeEach(() => sessionStorage.clear());

  it("preserves an internal deep link", () => {
    rememberPostAuthRedirect(
      "/captures/context?anchorId=6f12403e-0e0a-4c57-bed9-bedd253a8a7b",
    );
    expect(takePostAuthRedirect()).toBe(
      "/captures/context?anchorId=6f12403e-0e0a-4c57-bed9-bedd253a8a7b",
    );
  });

  it("consumes the redirect only once", () => {
    rememberPostAuthRedirect("/settings");
    expect(takePostAuthRedirect()).toBe("/settings");
    expect(takePostAuthRedirect()).toBe("/");
  });

  it("rejects external and protocol-relative redirects", () => {
    expect(normalizeInternalRedirect("https://evil.example/steal")).toBeNull();
    expect(normalizeInternalRedirect("//evil.example/steal")).toBeNull();
    expect(normalizeInternalRedirect("/\\evil.example/steal")).toBeNull();
  });
});
