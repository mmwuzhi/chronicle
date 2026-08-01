import { isSameAccessToken } from "@/lib/auth-session";

export class SessionChangedDuringRefresh extends Error {}

let refreshing: { token: string; promise: Promise<string> } | null = null;

export async function refreshAccessToken(
  requestToken: string,
): Promise<string> {
  if (!isSameAccessToken(localStorage.getItem("access_token"), requestToken)) {
    throw new SessionChangedDuringRefresh();
  }
  if (!refreshing || refreshing.token !== requestToken) {
    const startedWith = localStorage.getItem("access_token");
    const apiBase = import.meta.env.VITE_API_URL ?? "/api";
    const promise = fetch(`${apiBase}/auth/refresh`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
    })
      .then(async (response) => {
        if (!response.ok) throw new Error("access token refresh failed");
        return (await response.json()) as { accessToken: string };
      })
      .then(({ accessToken }) => {
        if (
          !isSameAccessToken(localStorage.getItem("access_token"), startedWith)
        ) {
          throw new SessionChangedDuringRefresh();
        }
        localStorage.setItem("access_token", accessToken);
        return accessToken;
      })
      .finally(() => {
        if (refreshing?.promise === promise) refreshing = null;
      });
    refreshing = { token: requestToken, promise };
  }
  const token = await refreshing.promise;
  if (!isSameAccessToken(localStorage.getItem("access_token"), token)) {
    throw new SessionChangedDuringRefresh();
  }
  return token;
}

export function expireSessionIfCurrent(requestToken: string): void {
  if (!isSameAccessToken(localStorage.getItem("access_token"), requestToken)) {
    return;
  }
  localStorage.removeItem("access_token");
  window.location.href = "/login";
}
