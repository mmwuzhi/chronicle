import { describe, expect, it } from "vitest";
import { isSameAccessToken } from "@/lib/auth-session";

describe("isSameAccessToken", () => {
  it("rejects a stale request after a newer login", () => {
    expect(isSameAccessToken("new-account-token", "old-account-token")).toBe(
      false,
    );
  });

  it("allows refresh and replay only within the same session", () => {
    expect(isSameAccessToken("same-token", "same-token")).toBe(true);
  });
});
