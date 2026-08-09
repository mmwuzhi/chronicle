import { defineConfig } from "orval";

export default defineConfig({
  chronicle: {
    input: {
      target: process.env.ORVAL_API_URL ?? "http://localhost:8080/openapi.json",
    },
    output: {
      target: "./src/api/index.ts",
      client: "react-query",
      httpClient: "axios",
      override: {
        mutator: {
          path: "./src/lib/axios.ts",
          name: "api",
        },
        operations: {
          "list-capture-page": {
            query: {
              useInfinite: true,
              useInfiniteQueryParam: "cursor",
            },
          },
          "list-capture-shares": {
            query: {
              useInfinite: true,
              useInfiniteQueryParam: "cursor",
            },
          },
        },
      },
    },
  },
});
