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

If the API is unavailable or the token is missing, captures are stored in:

```text
~/Library/Application Support/Chronicle/quick-capture-queue.json
```

## Tests

```bash
swift test
```
