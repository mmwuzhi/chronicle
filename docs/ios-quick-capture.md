# iOS quick capture

Capture into Chronicle from the iPhone Action Button, Share Sheet, Back Tap,
Home Screen, or Siri without installing an app. One Shortcut accepts shared
text, URLs, and images; when launched without input it offers typed text,
dictation, or on-device OCR.

The Shortcut uses a long-lived, revocable **capture token** that can only create
Captures. It cannot read, edit, or delete anything.

Chronicle intentionally documents the auditable action recipe instead of
shipping an opaque signed `.shortcut` binary. Apple-signed exports cannot be
inspected in CI, so a stale or miswired workflow could otherwise ship without
review.

## 1. Create a capture token

1. Open Chronicle on the web and go to **Settings → Integrations**.
2. Under **Quick capture tokens**, enter a recognizable name such as
   `iPhone Shortcut`, then tap **Generate**.
3. Copy the token. It starts with `chr_cap_` and is shown only once.

## 2. Configure the Shortcut input

Create a shortcut named `Chronicle Capture`, open its details, and enable
**Show in Share Sheet**.

Configure the input action at the top:

- Receive only **Text**, **URLs**, and **Images** from the Share Sheet.
- If there is no input: **Continue**.

The Continue setting matters: Share Sheet launches carry `Shortcut Input`,
while Action Button, Back Tap, Home Screen, and Siri launches continue into the
manual capture menu.

## 3. Normalize the input

Add this control flow:

1. **If** `Shortcut Input` has any value:
   1. **Get Type of** `Shortcut Input`.
   2. **If** the type contains `public.image`:
      1. **Extract Text from Image** using `Shortcut Input`.
      2. **Set Variable** `Capture Text` to the extracted text.
   3. **Otherwise**:
      1. **Get Text from Input** using `Shortcut Input`.
      2. **Set Variable** `Capture Text` to that result.
   4. **Set Variable** `Capture Source` to `ios_share_sheet`.
2. **Otherwise**, add **Choose from Menu** with these entries:
   - `Type text`
     1. **Ask for Input**, type `Text`, prompt `Capture`.
     2. Set `Capture Text` to the provided input.
     3. Set `Capture Source` to `ios_shortcut_text`.
   - `Dictate`
     1. **Dictate Text**.
     2. Set `Capture Text` to the dictated text.
     3. Set `Capture Source` to `ios_shortcut_voice`.
   - `OCR image`
     1. **Select Photos**, images only, one photo.
     2. **Extract Text from Image** using the selected photo.
     3. Set `Capture Text` to the extracted text.
     4. Set `Capture Source` to `ios_shortcut_ocr`.

After the branches, add:

1. **If** `Capture Text` does not have any value.
2. **Stop and Output** `No text found`.

For multi-image OCR, enable multiple selection, put **Extract Text from Image**
inside **Repeat with Each**, then combine `Repeat Results` with new lines.

## 4. Create an operation ID

`POST /captures` accepts an `Idempotency-Key` UUID. Shortcuts does not provide
a portable UUID action on every supported OS version, so generate a UUID-shaped
identifier locally:

1. **Current Date**.
2. **Random Number** between `1` and `1000000000`.
3. **Text** containing the Current Date and Random Number variables.
4. **Generate Hash**:
   - Type: `SHA256`
   - Input: the Text result
5. **Replace Text**:
   - Find:
     `^(.{8})(.{4})(.{4})(.{4})(.{12}).*$`
   - Replace with:
     `$1-$2-$3-$4-$5`
   - Input: the SHA256 hash
   - Regular Expression: on
6. Set `Operation ID` to the Replace Text result.

Generate the ID once per Shortcut run and reuse the same value if that run
contains an explicit retry. It does not deduplicate two separate Shortcut
launches; rerunning the Shortcut intentionally creates another Capture.

## 5. Send the Capture

Add **Get Contents of URL**:

| Field | Value |
|---|---|
| URL | `https://<your-api-host>/captures` |
| Method | `POST` |
| Header | `Authorization` = `Bearer chr_cap_…` |
| Header | `Content-Type` = `application/json` |
| Header | `Idempotency-Key` = the `Operation ID` variable |
| Request Body | `JSON` |

JSON fields:

| Key | Type | Value |
|---|---|---|
| `rawText` | Text | `Capture Text` |
| `mediaType` | Text | `text` |
| `source` | Text | `Capture Source` |

Equivalent request:

```http
POST https://<your-api-host>/captures
Authorization: Bearer chr_cap_79ed…e736
Content-Type: application/json
Idempotency-Key: a8463d6d-13cd-94c2-657f-89e2d9e8cc76

{
  "rawText": "groceries: oat milk",
  "mediaType": "text",
  "source": "ios_shortcut_text"
}
```

Store the **Get Contents of URL** result as `Response`, then:

1. **Get Dictionary Value** for key `id` from `Response`.
2. **If** that value has any value, **Show Notification**
   `Captured in Chronicle`.
3. **Otherwise**, **Stop and Output** `Capture failed: Response`.

Checking for the returned Capture ID matters because Shortcuts may expose an
HTTP error response as output instead of stopping the workflow automatically.
A network failure still stops before the success notification.

Do not send a capture token over plain LAN HTTP. For phone-to-local testing,
use an HTTPS tunnel or local TLS reverse proxy and revoke the temporary token
afterward.

## 6. Bind and verify

- **Action Button:** Settings → Action Button → Shortcut → `Chronicle Capture`.
- **Share Sheet:** share text, a URL, or an image and select
  `Chronicle Capture`.
- **Back Tap / Home Screen / Siri:** bind or invoke the same Shortcut.

Before relying on it, verify every path:

| Path | Expected result |
|---|---|
| Action Button → Type text | One Capture with source `ios_shortcut_text` |
| Action Button → Dictate | One Capture with source `ios_shortcut_voice` |
| Action Button → OCR image | One Capture with source `ios_shortcut_ocr` |
| Share text or URL | One Capture with source `ios_share_sheet` |
| Share image | OCR text saved with source `ios_share_sheet` |
| Empty input or empty OCR | `No text found`; no Capture created |
| Revoked or malformed token | Request fails; no success notification |
| Offline API | Request fails; no success notification |

## Security and lifecycle

- Capture tokens are create-only. Read, edit, delete, attachment, and account
  routes reject them.
- Chronicle stores only a SHA-256 hash of the token.
- Revoke a token from **Settings → Integrations**. Revocation takes effect on
  the next request.
- The token list shows last use so stale devices can be retired.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Token is missing, malformed, or revoked | Check the `Bearer ` prefix or generate a new token |
| `409 Conflict` | The same operation ID was reused with different content | Generate the ID once after input normalization and do not reuse it for another Capture |
| `422 Unprocessable Entity` | Empty text, invalid source, or malformed operation ID | Check `Capture Text`, source spelling, and the Replace Text expression |
| Share Sheet path opens the manual menu | Shortcut Input types or Share Sheet surface are not enabled | Recheck the input action in Shortcut details |
| OCR misses characters | Image is too small or language detection failed | Crop or enlarge the image and restrict OCR languages when the action exposes that option |
