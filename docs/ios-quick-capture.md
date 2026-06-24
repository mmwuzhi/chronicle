# iOS quick capture (Action Button)

Capture straight into Chronicle from your iPhone without installing an app: a
single [Shortcut](https://support.apple.com/guide/shortcuts/welcome/ios) bound
to the **Action Button** (or the Share Sheet) dictates or accepts text and POSTs
it to the API.

It authenticates with a **capture token** — a long-lived, revocable credential
that can *only* create captures. It cannot read, edit, or delete anything, so
even if the token leaks the blast radius is limited to appending captures to
your account. Revoke it any time from Settings.

## 1. Create a capture token

1. Open Chronicle on the web and go to **Settings → Integrations**.
2. Under **Quick capture tokens**, enter a name you'll recognize later (e.g.
   `iPhone Action Button`) and tap **Generate**.
3. Copy the token that appears. It starts with `chr_cap_` and is shown **only
   once** — if you lose it, revoke it and generate a new one.

## 2. Build the Shortcut

In the **Shortcuts** app, create a new shortcut with two actions:

### Action 1 — get the text

Pick whichever input you want:

- **Dictate Text** — speak the capture (best for the Action Button).
- **Ask for Input** (Text) — type it.
- **Shortcut Input** — if you'll run it from the Share Sheet, enable *Show in
  Share Sheet* and accept Text so shared text flows straight through.

### Action 2 — Get Contents of URL

Configure it as follows:

| Field | Value |
|---|---|
| URL | `https://<your-api-host>/captures` |
| Method | `POST` |
| Headers | `Authorization` = `Bearer chr_cap_…` (your token) |
| | `Content-Type` = `application/json` |
| Request Body | **JSON** |

JSON body fields:

| Key | Type | Value |
|---|---|---|
| `rawText` | Text | the variable from Action 1 (Dictated Text / Provided Input) |
| `mediaType` | Text | `text` |
| `source` | Text | `ios_action_button` |

The equivalent request looks like:

```http
POST https://<your-api-host>/captures
Authorization: Bearer chr_cap_79ed…e736
Content-Type: application/json

{
  "rawText": "groceries: oat milk",
  "mediaType": "text",
  "source": "ios_action_button"
}
```

A successful capture returns `200` with the saved capture JSON. `source` is a
free-form label (lowercase letters, digits, `_`, `:`, `-`) so you can tell where
a capture came from later — use `ios_share_sheet` for a Share Sheet variant, for
example.

> For local development, point the URL at `http://<your-mac-ip>:8080/captures`
> while `make api` is running and your phone is on the same network.

## 3. Bind it

- **Action Button:** Settings → Action Button → swipe to **Shortcut** → pick
  this shortcut. One press dictates and captures.
- **Share Sheet:** with *Show in Share Sheet* enabled, the shortcut appears when
  you share text from any app.
- **Back Tap / Home Screen / Siri** also work — say the shortcut's name.

## Security & lifecycle

- The token is **create-only**. `GET`, `PATCH`, and `DELETE` on captures (and
  every account route) reject it with `401`.
- It is stored only as a SHA-256 hash; the raw value lives only on your device.
- **Revoke** instantly from Settings → Integrations. The next request with a
  revoked token gets `401`.
- The token list shows when each token was **last used**, so you can spot and
  retire stale ones.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Token wrong, revoked, or missing `Bearer ` prefix | Re-check the header; generate a fresh token if needed |
| `422 Unprocessable Entity` | `rawText` empty for a `text` capture, or a bad `source` | Make sure Action 1 produced text; keep `source` lowercase |
| Nothing happens on Action Button | Shortcut not bound | Settings → Action Button → Shortcut → select it |
