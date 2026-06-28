# Chronicle Desktop

Chronicle Desktop is the macOS input layer for quick text capture. It runs as a native menu bar app, opens a small capture panel through a global shortcut, and saves text captures to the Chronicle API with `source=desktop_quick_capture`.

## Run Locally

```bash
swift run ChronicleDesktop
```

The app starts in the menu bar. Use Settings to sign in with:

- Chronicle email and password
- Quick Capture shortcut, default `Double Control`

The desktop app stores the returned access token locally. It uses `http://localhost:8080` by default for local development. Set `CHRONICLE_API_URL` when running against another API endpoint. MFA login is not implemented yet.

## Controls

- Menu bar → Quick Capture
- Double Control → Quick Capture
- Return → save the current text
- Esc or focus another window → close Quick Capture
- Menu bar → Retry Queue

If the API is unavailable or the token is missing, captures are stored locally in SQLite and retried later:

```text
~/Library/Application Support/Chronicle/chronicle-local.sqlite3
```

## Search

Search runs in independent layers, merged by capture id (no layer depends on another):

- **Keyword (offline, no login)** — substring match over the local SQLite cache. Always on.
- **On-device semantic (offline, no login)** — opt-in. If a local [Ollama](https://ollama.com) is running with `bge-m3` (`ollama pull bge-m3`), captures and the query are embedded locally and ranked by cosine, so meaning-based search works with no account and no network ("吃面" finds a "拉面" note). It targets `http://127.0.0.1:11434` and falls back to keyword silently when Ollama is absent — offline semantic is the user's own setup, not a requirement.
- **Server semantic** — when signed in, the API's `/find` results merge on top.

The on-device and server channels each use their own embedding model and vector space; they coexist by id-dedup rather than a shared space, so the online service is free to use the best embedding (e.g. Voyage) independent of the local one.

## Tests

```bash
swift test
swift build
bash scripts/e2e.sh
```
