export function apiFetch(path: string, options: RequestInit = {}) {
  const token = localStorage.getItem("access_token");
  const apiBase = import.meta.env.VITE_API_URL ?? "/api";
  return fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...options.headers,
    },
  });
}
