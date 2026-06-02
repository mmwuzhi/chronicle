import axios, { type AxiosRequestConfig } from "axios";

export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? "/api",
  withCredentials: true,
});

apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem("access_token");
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

let refreshing: Promise<string> | null = null;

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
    try {
      if (!refreshing) {
        refreshing = apiClient
          .post<{ accessToken: string }>("/auth/refresh")
          .then((r) => {
            const token = r.data.accessToken;
            localStorage.setItem("access_token", token);
            return token;
          })
          .finally(() => {
            refreshing = null;
          });
      }
      const token = await refreshing;
      original.headers.Authorization = `Bearer ${token}`;
      return apiClient(original);
    } catch {
      localStorage.removeItem("access_token");
      window.location.href = "/login";
      return Promise.reject(error);
    }
  },
);

export const api = <T>(config: AxiosRequestConfig): Promise<T> =>
  apiClient(config).then((res) => res.data);
