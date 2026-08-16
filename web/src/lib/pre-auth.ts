import {
  startAuthentication,
  WebAuthnError,
  type PublicKeyCredentialRequestOptionsJSON,
} from "@simplewebauthn/browser";

export class PreAuthRequestError extends Error {
  readonly status: number;
  readonly detail: string | null;

  constructor(status: number, detail: string | null) {
    super(detail ?? `Pre-auth request failed with status ${status}`);
    this.name = "PreAuthRequestError";
    this.status = status;
    this.detail = detail;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isPasskeyOptions(
  value: unknown,
): value is PublicKeyCredentialRequestOptionsJSON {
  return isRecord(value) && typeof value.challenge === "string";
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function preAuthPost(
  path: string,
  body?: unknown,
  signal?: AbortSignal,
): Promise<unknown> {
  const apiBase = import.meta.env.VITE_API_URL ?? "/api";
  const response = await fetch(`${apiBase}${path}`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    signal,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const payload = await readJson(response);
  if (!response.ok) {
    const detail =
      isRecord(payload) && typeof payload.detail === "string"
        ? payload.detail
        : null;
    throw new PreAuthRequestError(response.status, detail);
  }
  return payload;
}

function readAccessToken(payload: unknown): string {
  if (!isRecord(payload) || typeof payload.accessToken !== "string") {
    throw new Error("Pre-auth response did not include an access token");
  }
  return payload.accessToken;
}

export async function verifyMfa(
  mfaToken: string,
  code: string,
  signal?: AbortSignal,
): Promise<string> {
  return readAccessToken(
    await preAuthPost("/auth/mfa/verify", { mfaToken, code }, signal),
  );
}

export function isExpiredMfaTokenError(error: unknown): boolean {
  return (
    error instanceof PreAuthRequestError &&
    error.status === 401 &&
    error.detail?.includes("expired") === true
  );
}

export async function loginWithPasskey(): Promise<string | null> {
  const beginPayload = await preAuthPost("/auth/passkeys/login/begin");
  if (!isRecord(beginPayload) || !isPasskeyOptions(beginPayload.options)) {
    throw new Error("Passkey login response did not include valid options");
  }

  let credential;
  try {
    credential = await startAuthentication({
      optionsJSON: beginPayload.options,
    });
  } catch (error) {
    if (
      error instanceof WebAuthnError &&
      (error.code === "ERROR_CEREMONY_ABORTED" ||
        (error.code === "ERROR_PASSTHROUGH_SEE_CAUSE_PROPERTY" &&
          isRecord(error.cause) &&
          error.cause.name === "NotAllowedError"))
    ) {
      return null;
    }
    throw error;
  }

  return readAccessToken(
    await preAuthPost("/auth/passkeys/login/finish", { credential }),
  );
}
