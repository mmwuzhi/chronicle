import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tanstackRouter from "@tanstack/router-plugin/vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [
    tanstackRouter({ target: "react", autoCodeSplitting: true }),
    react(),
    tailwindcss(),
  ],
  server: {
    proxy: {
      "/api": {
        target: process.env.VITE_PROXY_TARGET ?? "http://localhost:8080",
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
});
