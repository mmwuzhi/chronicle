import axios, { type AxiosRequestConfig } from "axios";

export const apiClient = axios.create({
  baseURL: "/api",
  withCredentials: true,
});

apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem("access_token");
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

export const api = <T>(config: AxiosRequestConfig): Promise<T> =>
  apiClient(config).then((res) => res.data);
