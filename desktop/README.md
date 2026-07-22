# Chronicle Desktop

Chronicle Desktop is the macOS layer of Chronicle: a native menu bar app with a
Raycast-style quick panel (capture / search / ask), a main window for browsing,
offline-first local search, desktop sticky notes, and reminder notifications.
Text captures save to the Chronicle API with `source=desktop_quick_capture` and
to a local SQLite cache that works without an account.

## Run Locally

```bash
swift run ChronicleDesktop
```

The app starts in the menu bar. Use Sign In from the main window's Ask composer
or Account settings to open the account sheet, then continue with Google,
GitHub, or a Chronicle email and password (MFA login is not implemented yet). It targets
`http://localhost:8080` by default; set `CHRONICLE_API_URL` for another
endpoint.

For a bundled dev run that only restarts the menu bar app when the build output
changed, use `make desktop-reload` / `just desktop-reload` from the repo root.
Reminder notifications require the packaged `.app` (`make desktop-app` or
`desktop-reload`) — a bare `swift run` skips them.

Generic file attachments are stored in the user's Google Drive with the
`drive.file` scope. For local development, set `CHRONICLE_GOOGLE_DRIVE_CLIENT_ID`
to a Google OAuth Desktop client ID before launching the app. Packaged builds
can set the same value in `Info.plist` under `ChronicleGoogleDriveClientID`.

## Controls

- Double Control (configurable in Settings) or menu bar → Quick Capture
- Quick panel modes: Capture ⌘1 · Search ⌘2 · Ask ⌘3; ⌘Return submits
- Esc or clicking elsewhere closes the panel
- Menu bar → Open Chronicle: the main window (browse, search, ask, trash,
  settings)

## Capture rows

Rows in the quick panel and main window keep one always-visible **⋯** affordance
instead of mounting several hover controls in every scrolling row. Its menu
contains **open**, **pin/unpin**, **remove link**, and **delete** when those
actions apply. Double-clicking an editable row edits it in place. A pinned row
shows a quiet accent bar on its left edge instead of a lit icon.

## Detail windows

Every capture can open in its own independent window; several stay open side by
side, and opening a capture that is already on screen just focuses its window.
Entry points: **Open** in a row's overflow, double-clicking a desktop sticky, and
tapping a reminder notification. The detail window shows the capture together
with its linked and related captures.

## Desktop stickies

Pin a capture from a row's ⋯ menu or its detail window: it becomes a floating
always-on-top glass note that stays on the Space where it was created and
restores across launches. Drag the top bar to move; drag the bottom edge to
resize (height only — width is fixed). The ✕ (or Esc) unpins, copy sits in the
header, and a double-click anywhere opens the detail window. Body text renders
inline markdown and supports click-drag selection.

## Reminders

The capture panel's bell attaches a reminder time; "Keep visible" keeps the
capture in browse instead of hiding it until due. Reminders fire as macOS
notifications even when the app is not running (packaged app only), and tapping
one opens that capture's detail window. Sync retry for offline captures lives
in Settings (sent / remaining).

## Search

Search runs in independent layers, merged by capture id (no layer depends on another):

- **Keyword (offline, no login)** — substring match over the local SQLite cache. Always on.
- **On-device semantic (offline, no login)** — opt-in. If a local [Ollama](https://ollama.com) is running with `bge-m3` (`ollama pull bge-m3`), captures and the query are embedded locally and ranked by cosine, so meaning-based search works with no account and no network ("吃面" finds a "拉面" note). It targets `http://127.0.0.1:11434` and falls back to keyword silently when Ollama is absent — offline semantic is the user's own setup, not a requirement.
- **Server semantic** — when signed in, the API's `/find` results merge on top.

The on-device and server channels each use their own embedding model and vector space; they coexist by id-dedup rather than a shared space, so the online service is free to use the best embedding (e.g. Voyage) independent of the local one.

## Offline store

If the API is unavailable or the token is missing, captures are stored locally
and retried later. The same SQLite file doubles as the corpus for offline
browse and search:

```text
~/Library/Application Support/Chronicle/chronicle-local.sqlite3
```

## Tests

```bash
swift test
swift build
bash scripts/e2e.sh
```
