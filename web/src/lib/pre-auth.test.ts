import { startAuthentication, WebAuthnError } from "@simplewebauthn/browser";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  isExpiredMfaTokenError,
  loginWithPasskey,
  PreAuthRequestError,
  verifyMfa,
} from "@/lib/pre-auth";

vi.mock("@simplewebauthn/browser", async (importOriginal) => {
  const original =
    await importOriginal<typeof import("@simplewebauthn/browser")>();
  return { ...original, startAuthentication: vi.fn() };
});

const fetchMock = vi.fn<typeof fetch>();
const startAuthenticationMock = vi.mocked(startAuthentication);

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("pre-auth requests", () => {
  beforeEach(() => {
    fetchMock.mockReset();
    startAuthenticationMock.mockReset();
    vi.stubGlobal("fetch", fetchMock);
  });

  it("verifies MFA without attaching an existing bearer token", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ accessToken: "new-token" }));

    await expect(verifyMfa("mfa-token", "123456")).resolves.toBe("new-token");
    expect(fetchMock).toHaveBeenCalledWith("/api/auth/mfa/verify", {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mfaToken: "mfa-token", code: "123456" }),
    });
  });

  it("preserves an expired MFA response for the shared UI semantics", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ detail: "invalid or expired MFA token" }, 401),
    );

    const error = await verifyMfa("expired-token", "123456").catch(
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(PreAuthRequestError);
    expect(isExpiredMfaTokenError(error)).toBe(true);
  });

  it("runs the passkey ceremony and finishes it through the same boundary", async () => {
    const credential = {
      id: "credential-id",
      rawId: "credential-id",
      response: {
        authenticatorData: "authenticator-data",
        clientDataJSON: "client-data",
        signature: "signature",
      },
      clientExtensionResults: {},
      type: "public-key" as const,
    };
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ options: { challenge: "abc" } }))
      .mockResolvedValueOnce(jsonResponse({ accessToken: "passkey-token" }));
    startAuthenticationMock.mockResolvedValueOnce(credential);

    await expect(loginWithPasskey()).resolves.toBe("passkey-token");
    expect(startAuthenticationMock).toHaveBeenCalledWith({
      optionsJSON: { challenge: "abc" },
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/auth/passkeys/login/begin",
      {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
      },
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/auth/passkeys/login/finish",
      {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ credential }),
      },
    );
  });

  it("silences only an explicitly aborted passkey ceremony", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ options: { challenge: "abc" } }),
    );
    startAuthenticationMock.mockRejectedValueOnce(
      new WebAuthnError({
        message: "The ceremony was cancelled",
        code: "ERROR_CEREMONY_ABORTED",
        cause: new Error("cancelled"),
      }),
    );

    await expect(loginWithPasskey()).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("surfaces other passkey failures", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ options: { challenge: "abc" } }),
    );
    startAuthenticationMock.mockRejectedValueOnce(new Error("unavailable"));

    await expect(loginWithPasskey()).rejects.toThrow("unavailable");
  });
});
