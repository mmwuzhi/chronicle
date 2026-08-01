import {
  expireSessionIfCurrent,
  refreshAccessToken,
  SessionChangedDuringRefresh,
} from "@/lib/auth-refresh";

export async function apiFetch(path: string, options: RequestInit = {}) {
  const requestToken = localStorage.getItem("access_token");
  const apiBase = import.meta.env.VITE_API_URL ?? "/api";
  const send = (token: string | null) =>
    fetch(`${apiBase}${path}`, {
      ...options,
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...options.headers,
      },
    });
  const response = await send(requestToken);
  if (response.status !== 401 || !requestToken) return response;
  try {
    return await send(await refreshAccessToken(requestToken));
  } catch (error) {
    if (!(error instanceof SessionChangedDuringRefresh)) {
      expireSessionIfCurrent(requestToken);
    }
    return response;
  }
}
