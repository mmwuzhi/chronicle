import axios, { type AxiosRequestConfig } from "axios";
import {
  expireSessionIfCurrent,
  refreshAccessToken,
  SessionChangedDuringRefresh,
} from "@/lib/auth-refresh";
import { isSameAccessToken } from "@/lib/auth-session";

export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? "/api",
  withCredentials: true,
});

apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem("access_token");
  if (token && !config.headers.Authorization) {
    config.headers = config.headers ?? {};
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

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
      const token = await refreshAccessToken(requestToken);
      original.headers.Authorization = `Bearer ${token}`;
      return apiClient(original);
    } catch (refreshError) {
      if (refreshError instanceof SessionChangedDuringRefresh) {
        return Promise.reject(error);
      }
      expireSessionIfCurrent(requestToken);
      return Promise.reject(error);
    }
  },
);

export const api = <T>(
  config: AxiosRequestConfig,
  options?: AxiosRequestConfig,
): Promise<T> =>
  apiClient({
    ...config,
    ...options,
    headers: {
      ...config.headers,
      ...options?.headers,
    },
  }).then((res) => res.data);
