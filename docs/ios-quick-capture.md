# iOS quick capture (Action Button)

Capture straight into Chronicle from your iPhone without installing an app: a
single [Shortcut](https://support.apple.com/guide/shortcuts/welcome/ios) bound
to the **Action Button** (or the Share Sheet) accepts typed text or runs on-device
OCR on an image, then POSTs the resulting text to the API.

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

In the **Shortcuts** app, create a shortcut named `Chronicle Capture`.

### Action 1 — choose capture mode

Add **Choose from Menu** with two options:

- `Type text`
- `OCR image`

### Menu option — Type text

Inside `Type text`, add:

1. **Ask for Input**
   - Input Type: `Text`
   - Prompt: `Capture`
2. **Set Variable**
   - Variable name: `Capture Text`
   - Value: the **Provided Input** from Ask for Input
3. **Set Variable**
   - Variable name: `Capture Source`
   - Value: `ios_shortcut_text`

### Menu option — OCR image

Inside `OCR image`, add:

1. **Select Photos**
   - Select Multiple: off for the simplest flow; on if you want to OCR several
     screenshots at once.
   - Media Type: Images
2. **Extract Text from Image**
   - Image: the selected photo.
   - If your iOS version exposes a language option, choose the narrowest useful
     set, usually Chinese Simplified + English. If no language option is shown,
     iOS will auto-detect; this is usually good enough for screenshots.
3. **Set Variable**
   - Variable name: `Capture Text`
   - Value: the extracted text.
4. **Set Variable**
   - Variable name: `Capture Source`
   - Value: `ios_shortcut_ocr`

If you enable multi-select, put **Extract Text from Image** inside **Repeat with
Each** and combine the text with new lines before setting `Capture Text`.

### Action 2 — skip empty captures

After the menu, add:

1. **If**
   - Condition: `Capture Text` `is` empty
2. Inside the If branch:
   - **Show Alert**: `No text found`
   - **Stop This Shortcut**

This prevents blank OCR results from hitting the API, which would return `422`.

### Action 3 — Get Contents of URL

After the empty check, add **Get Contents of URL** and configure it as follows:

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
| `rawText` | Text | the `Capture Text` variable |
| `mediaType` | Text | `text` |
| `source` | Text | the `Capture Source` variable |

The equivalent request looks like:

```http
POST https://<your-api-host>/captures
Authorization: Bearer chr_cap_79ed…e736
Content-Type: application/json

{
  "rawText": "groceries: oat milk",
  "mediaType": "text",
  "source": "ios_shortcut_text"
}
```

A successful capture returns `200` with the saved capture JSON. `source` is a
free-form label (lowercase letters, digits, `_`, `:`, `-`) so you can tell where
a capture came from later — use `ios_shortcut_ocr`, `ios_shortcut_text`, or
`ios_share_sheet` depending on the entry point.

Optionally add **Show Notification** after the request with `Captured in
Chronicle`.

> Do not send a capture token over plain LAN HTTP. For local phone testing, put
> the API behind an HTTPS tunnel or a local TLS reverse proxy, use that `https://`
> capture URL, and revoke the temporary token immediately after testing.

## 3. Bind it

- **Action Button:** Settings → Action Button → swipe to **Shortcut** → pick
  this shortcut. One press opens the text/OCR menu.
- **Share Sheet:** with *Show in Share Sheet* enabled, the shortcut appears when
  you share text or images from any app. For a dedicated Share Sheet variant,
  replace **Select Photos** with **Shortcut Input** in the OCR branch.
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
| `422 Unprocessable Entity` | `rawText` empty for a `text` capture, or a bad `source` | Make sure `Capture Text` is not empty; keep `source` lowercase |
| OCR misses Chinese characters | Auto language detection picked the wrong script, or the screenshot is too small | If the action exposes language settings, choose Chinese Simplified + English; otherwise crop/zoom the screenshot before OCR |
| Nothing happens on Action Button | Shortcut not bound | Settings → Action Button → Shortcut → select it |
