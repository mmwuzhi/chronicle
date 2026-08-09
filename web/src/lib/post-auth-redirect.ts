const postAuthRedirectKey = "chronicle_post_auth_redirect";

export function normalizeInternalRedirect(value: string): string | null {
  if (!value.startsWith("/") || value.startsWith("//")) return null;

  try {
    const internalOrigin = "https://chronicle.local";
    const parsed = new URL(value, internalOrigin);
    if (parsed.origin !== internalOrigin) return null;
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return null;
  }
}

export function rememberPostAuthRedirect(value: string): void {
  const redirect = normalizeInternalRedirect(value);
  if (!redirect) return;
  try {
    sessionStorage.setItem(postAuthRedirectKey, redirect);
  } catch {
    // A disabled sessionStorage must not prevent sign-in.
  }
}

export function takePostAuthRedirect(): string {
  let stored: string | null = null;
  try {
    stored = sessionStorage.getItem(postAuthRedirectKey);
    sessionStorage.removeItem(postAuthRedirectKey);
  } catch {
    // Fall back to the dashboard when sessionStorage is unavailable.
  }
  return (stored && normalizeInternalRedirect(stored)) || "/";
}

export function completeSignIn(accessToken: string): void {
  localStorage.setItem("access_token", accessToken);
  window.location.replace(takePostAuthRedirect());
}

export function redirectToSignIn(): void {
  const current = `${window.location.pathname}${window.location.search}${window.location.hash}`;
  if (window.location.pathname !== "/login") {
    rememberPostAuthRedirect(current);
  }
  window.location.replace("/login");
}
