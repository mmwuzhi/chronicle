import { apiClient } from "./axios";

function getTokenExpiry(token: string): number | null {
  try {
    const raw = token.split(".")[1];
    // base64url → standard base64 before atob
    const b64 = raw
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(raw.length + ((4 - (raw.length % 4)) % 4), "=");
    const payload = JSON.parse(atob(b64));
    return typeof payload.exp === "number" ? payload.exp : null;
  } catch {
    return null;
  }
}

export async function initAuth(): Promise<void> {
  const token = localStorage.getItem("access_token");
  const exp = token ? getTokenExpiry(token) : null;
  const isExpired = !exp || Date.now() / 1000 >= exp;

  if (!isExpired) return;

  try {
    const res = await apiClient.post<{ accessToken: string }>("/auth/refresh");
    localStorage.setItem("access_token", res.data.accessToken);
  } catch {
    localStorage.removeItem("access_token");
  }
}
