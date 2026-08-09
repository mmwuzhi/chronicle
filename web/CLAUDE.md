# Chronicle Web workspace

`web/` is one pnpm workspace with two browser runtimes:

- `src/`: the Vite React/TanStack application; read `src/CLAUDE.md`
- `extension/`: the Manifest V3 quick-capture extension; read
  `extension/CLAUDE.md`

Do not apply React application, i18n, TanStack, or orval assumptions to the
extension. Do not apply Chrome service-worker, permission, or durable-outbox
assumptions to the React application.

The root `pnpm-lock.yaml` covers both packages. The live scripts are in
`package.json` and `extension/package.json`; root `Justfile` recipes include
Web development plus extension test, package, and E2E entry points.

`dist/`, `extension/dist/`, extension ZIPs, `node_modules/`, and
`src/routeTree.gen.ts` are generated artifacts, not architecture sources.
