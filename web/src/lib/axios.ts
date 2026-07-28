import axios, { type AxiosRequestConfig } from "axios";
import { isSameAccessToken } from "@/lib/auth-session";

export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? "/api",
  withCredentials: true,
});

apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem("access_token");
  if (token) {
    config.headers = config.headers ?? {};
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

class SessionChangedDuringRefresh extends Error {}

let refreshing: { token: string; promise: Promise<string> } | null = null;

apiClient.interceptors.response.use(
  (res) => res,
  async (error) => {
    const original = error.config;
    if (
      error.response?.status !== 401 ||
      original._retry ||
      original.url?.includes("/auth/refresh") ||
      !original.headers?.Authorization
    ) {
      return Promise.reject(error);
    }
    original._retry = true;
    const requestToken = String(original.headers.Authorization).replace(
      /^Bearer\s+/,
      "",
    );
    // This 401 belongs to an older session. Never refresh or replay its request
    // with credentials that a newer login placed in shared localStorage.
    if (
      !isSameAccessToken(localStorage.getItem("access_token"), requestToken)
    ) {
      return Promise.reject(error);
    }
    try {
      if (!refreshing || refreshing.token !== requestToken) {
        const startedWith = localStorage.getItem("access_token");
        const promise = apiClient
          .post<{ accessToken: string }>("/auth/refresh")
          .then((r) => {
            const token = r.data.accessToken;
            if (
              !isSameAccessToken(
                localStorage.getItem("access_token"),
                startedWith,
              )
            ) {
              throw new SessionChangedDuringRefresh();
            }
            localStorage.setItem("access_token", token);
            return token;
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
      original.headers.Authorization = `Bearer ${token}`;
      return apiClient(original);
    } catch (refreshError) {
      if (refreshError instanceof SessionChangedDuringRefresh) {
        return Promise.reject(error);
      }
      if (
        isSameAccessToken(localStorage.getItem("access_token"), requestToken)
      ) {
        localStorage.removeItem("access_token");
        window.location.href = "/login";
      }
      return Promise.reject(error);
    }
  },
);

export const api = <T>(config: AxiosRequestConfig): Promise<T> =>
  apiClient(config).then((res) => res.data);
