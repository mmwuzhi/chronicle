import { expect, test, type Page } from "@playwright/test";

async function goto(page: Page, path: string) {
  await page.goto(path, { waitUntil: "domcontentloaded" });
}

function visibleSearchTrigger(page: Page) {
  const mobile = (page.viewportSize()?.width ?? 1280) < 768;
  return mobile
    ? page.getByRole("button", { name: "Search…", exact: true })
    : page.locator("nav button").filter({ hasText: "Search…" });
}

function capture(id: string, rawText: string, createdAt: string) {
  return {
    attachments: null,
    audioDurationSec: null,
    createdAt,
    deletedAt: null,
    doneAt: null,
    id,
    mediaType: "text",
    mediaUrl: null,
    rawText,
    remindAt: null,
    remindHide: true,
    source: "web",
    todoAt: null,
    transcribedAt: null,
    transcript: null,
    transcriptionModel: null,
    transcriptionStatus: "none",
  };
}

// Nav

test("nav: search placeholder is short", async ({ page }) => {
  await goto(page, "/");
  const trigger = visibleSearchTrigger(page);
  await expect(trigger).toHaveAccessibleName(/^Search/);
  await expect(trigger).not.toHaveAccessibleName(/captures/i);
});

test("nav: settings affordance matches viewport", async ({
  page,
  isMobile,
}) => {
  await goto(page, "/");
  const settings = page
    .getByRole("link", { name: /^settings$/i })
    .filter({ visible: true });
  await expect(settings).toHaveCount(1);
  const visibleText = (await settings.textContent())?.trim();
  expect(visibleText).toBe(isMobile ? "" : "Settings");
});

// Captures

test("captures: current capture-first controls are visible", async ({
  page,
}) => {
  await goto(page, "/captures");
  await expect(page.getByText(/dump a thought/i)).toBeVisible();

  const composer = page.getByPlaceholder(/what's on your mind/i);
  await expect(composer).toBeVisible();
  expect(await composer.getAttribute("placeholder")).not.toContain("⌘");
  await composer.fill("#");
  await expect(
    page.getByRole("button", { name: /#todo.*mark as todo/i }),
  ).toBeVisible();
  await composer.press("Tab");
  await expect(composer).toHaveValue("#todo ");
  await composer.fill("");

  await expect(page.getByRole("button", { name: /attach/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^record$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /polish/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^all$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^todo$/i })).toBeVisible();
  await expect(page.getByRole("button", { name: /^routine$/i })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^log$/i })).toHaveCount(0);
});

test("sharing: an existing link is restored in the Capture dialog", async ({
  page,
}) => {
  const captureID = "00000000-0000-4000-8000-000000000101";
  const shareID = "00000000-0000-4000-8000-000000000102";
  const sharedCapture = capture(
    captureID,
    "Persistent share state",
    "2026-06-06T10:00:00Z",
  );
  let revoked = false;
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ items: [sharedCapture], nextCursor: null }),
    }),
  );
  await page.route("**/api/shares**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: revoked
          ? []
          : [
              {
                id: shareID,
                captureId: captureID,
                snapshotRawText: "Original shared snapshot",
                capturedAt: sharedCapture.createdAt,
                createdAt: "2026-06-07T10:00:00Z",
                expiresAt: "2099-06-14T10:00:00Z",
                secret: "persistent-secret",
                url: `https://chronicle.example/s/${shareID}#persistent-secret`,
              },
            ],
        nextCursor: null,
      }),
    }),
  );
  await page.route(`**/api/shares/${shareID}`, (route) => {
    revoked = true;
    return route.fulfill({ status: 204 });
  });

  await goto(page, "/captures");
  await page.getByRole("button", { name: "Open Capture" }).click();
  await page
    .getByRole("dialog", { name: "Capture" })
    .getByRole("button", { name: "Share" })
    .click();

  const shareDialog = page.getByRole("dialog", {
    name: "Share a read-only copy",
  });
  await expect(shareDialog.getByLabel("Share link")).toHaveValue(
    `https://chronicle.example/s/${shareID}#persistent-secret`,
  );
  await expect(shareDialog.getByText("Original shared snapshot")).toBeVisible();
  await expect(shareDialog.getByText(sharedCapture.rawText)).toHaveCount(0);
  await expect(
    shareDialog.getByRole("button", { name: "Revoke" }),
  ).toBeVisible();

  await shareDialog.getByRole("button", { name: "Revoke" }).click();
  await page
    .getByRole("dialog", { name: "Revoke this link?" })
    .getByRole("button", { name: "Revoke" })
    .click();
  await expect(
    shareDialog.getByRole("button", { name: "Create link" }),
  ).toBeVisible();
});

test("sharing: a new link uses the selected expiry and copies the canonical URL", async ({
  page,
}) => {
  const captureID = "00000000-0000-4000-8000-000000000104";
  const shareID = "00000000-0000-4000-8000-000000000105";
  const canonicalURL = `https://chronicle.example/s/${shareID}#new-secret`;
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text: string) => {
          document.documentElement.dataset.clipboardText = text;
        },
      },
    });
  });
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [capture(captureID, "New shared text", "2026-06-06T10:00:00Z")],
        nextCursor: null,
      }),
    }),
  );
  await page.route("**/api/shares**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ items: [], nextCursor: null }),
    }),
  );
  await page.route(`**/api/captures/${captureID}/shares`, async (route) => {
    expect(route.request().postDataJSON()).toEqual({
      expiresIn: "30d",
      snapshotRawText: "New shared text",
    });
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        id: shareID,
        captureId: captureID,
        snapshotRawText: "New shared text",
        capturedAt: "2026-06-06T10:00:00Z",
        createdAt: "2026-06-07T10:00:00Z",
        expiresAt: "2099-07-07T10:00:00Z",
        secret: "new-secret",
        url: canonicalURL,
      }),
    });
  });

  await goto(page, "/captures");
  await page.getByRole("button", { name: "Open Capture" }).click();
  await page
    .getByRole("dialog", { name: "Capture" })
    .getByRole("button", { name: "Share" })
    .click();

  const shareDialog = page.getByRole("dialog", {
    name: "Share a read-only copy",
  });
  await shareDialog.getByLabel("Link expires").selectOption("30d");
  await shareDialog.getByRole("button", { name: "Create link" }).click();
  await expect(shareDialog.getByLabel("Share link")).toHaveValue(canonicalURL);
  await shareDialog.getByRole("button", { name: "Copy", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute(
    "data-clipboard-text",
    canonicalURL,
  );
});

test("sharing: the public page is content-first, secret-bound, and copies its text", async ({
  page,
}) => {
  const shareID = "00000000-0000-4000-8000-000000000103";
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text: string) => {
          document.documentElement.dataset.clipboardText = text;
        },
      },
    });
  });
  await page.route(`**/api/public/shares/${shareID}`, (route) => {
    if (route.request().headers().authorization !== "Share persistent-secret") {
      return route.fulfill({
        status: 404,
        contentType: "application/json",
        body: "{}",
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        snapshotRawText: "Public copy content",
        capturedAt: "2026-06-06T10:00:00Z",
        expiresAt: "2099-06-14T10:00:00Z",
      }),
    });
  });

  await goto(page, `/s/${shareID}#persistent-secret`);

  await expect(page.getByText("Public copy content")).toBeVisible();
  await expect(page.getByText("Read-only copy")).toHaveCount(0);
  await expect(page.getByText(/Available until/)).toHaveCount(0);
  const copyText = page.getByRole("button", { name: "Copy", exact: true });
  await expect(copyText).toBeVisible();
  await copyText.click();
  await expect(page.getByRole("button", { name: "Copied" })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute(
    "data-clipboard-text",
    "Public copy content",
  );

  await page.evaluate(() => {
    window.location.hash = "invalid-secret";
  });
  await expect(
    page.getByRole("heading", { name: "Page not found" }),
  ).toBeVisible();
});

test("captures: wide cards form a natural-height ordered masonry", async ({
  page,
  isMobile,
}) => {
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [
          capture(
            "00000000-0000-4000-8000-000000000010",
            "Layout reference one",
            "2026-06-06T10:00:00Z",
          ),
          capture(
            "00000000-0000-4000-8000-000000000014",
            [
              "Layout reference two",
              ...Array.from(
                { length: 14 },
                (_, index) =>
                  `Long layout paragraph ${index + 1} makes this card taller than its neighbor.`,
              ),
            ].join("\n\n"),
            "2026-06-05T10:00:00Z",
          ),
          capture(
            "00000000-0000-4000-8000-000000000015",
            "Layout reference three",
            "2026-06-04T10:00:00Z",
          ),
          capture(
            "00000000-0000-4000-8000-000000000016",
            "Layout reference four",
            "2026-06-03T10:00:00Z",
          ),
        ],
        nextCursor: null,
      }),
    }),
  );

  await goto(page, "/captures");
  const composer = page.getByPlaceholder(/what's on your mind/i);
  const cards = page.locator("li").filter({ hasText: "Layout reference" });
  await expect(cards).toHaveCount(4);
  await expect(cards.nth(1).getByText(/show more/i)).toBeVisible();
  const composerBox = await composer.boundingBox();
  const cardBoxes = await cards.evaluateAll((elements) =>
    elements.map((element) => {
      const box = element.getBoundingClientRect();
      return { x: box.x, y: box.y, width: box.width, height: box.height };
    }),
  );
  expect(composerBox).not.toBeNull();
  expect(composerBox?.y).toBeLessThan(cardBoxes[0]?.y ?? 0);

  if (!isMobile) {
    expect(cardBoxes[0]?.x).toBeLessThan(cardBoxes[1]?.x ?? 0);
    expect(cardBoxes[0]?.y).toBeCloseTo(cardBoxes[1]?.y ?? 0, 0);
    expect(cardBoxes[1]?.height).toBeGreaterThan(cardBoxes[0]?.height ?? 0);
    expect(cardBoxes[2]?.x).toBeCloseTo(cardBoxes[0]?.x ?? 0, 0);
    expect(
      Math.abs(
        (cardBoxes[2]?.y ?? 0) -
          ((cardBoxes[0]?.y ?? 0) + (cardBoxes[0]?.height ?? 0) + 12),
      ),
    ).toBeLessThanOrEqual(1);
    expect(cardBoxes[2]?.y).toBeLessThan(
      (cardBoxes[1]?.y ?? 0) + (cardBoxes[1]?.height ?? 0),
    );
    expect(cardBoxes[3]?.y).toBeGreaterThan(cardBoxes[2]?.y ?? 0);

    await page.setViewportSize({ width: 1024, height: 768 });
    await expect
      .poll(() =>
        cards.evaluateAll(
          (elements) =>
            new Set(
              elements.map((element) =>
                Math.round(element.getBoundingClientRect().x),
              ),
            ).size,
        ),
      )
      .toBe(1);
    const tabletCardBoxes = await cards.evaluateAll((elements) =>
      elements.map((element) => {
        const box = element.getBoundingClientRect();
        return { x: box.x, y: box.y, height: box.height };
      }),
    );
    expect(tabletCardBoxes.map((box) => box.y)).toEqual(
      tabletCardBoxes.map((box) => box.y).toSorted((a, b) => a - b),
    );
    expect(tabletCardBoxes[1]?.height).toBeGreaterThan(
      tabletCardBoxes[0]?.height ?? 0,
    );
  }
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
});

test("captures: full content and editing open in a stable detail modal", async ({
  page,
  isMobile,
}) => {
  const longMarkdown = Array.from(
    { length: 14 },
    (_, index) =>
      `Paragraph ${index + 1} keeps enough detail to make this Capture intentionally long.`,
  ).join("\n\n");
  const longTranscript = Array.from(
    { length: 12 },
    (_, index) =>
      `Transcript line ${index + 1} preserves the complete recording.`,
  ).join("\n\n");
  let attackerRequests = 0;
  await page.route("https://attacker.invalid/**", (route) => {
    attackerRequests += 1;
    return route.abort();
  });

  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [
          capture(
            "00000000-0000-4000-8000-000000000011",
            longMarkdown,
            "2026-06-06T10:00:00Z",
          ),
          capture(
            "00000000-0000-4000-8000-000000000012",
            "Short Capture remains fully visible.",
            "2026-06-05T10:00:00Z",
          ),
          {
            ...capture(
              "00000000-0000-4000-8000-000000000013",
              "Audio note",
              "2026-06-04T10:00:00Z",
            ),
            mediaType: "audio",
            transcript: longTranscript,
            transcriptionStatus: "completed",
          },
          {
            ...capture(
              "00000000-0000-4000-8000-000000000017",
              "Link capture",
              "2026-06-03T10:00:00Z",
            ),
            transcript:
              "Link-derived internal text ![tracking](https://attacker.invalid/pixel)",
            transcriptionStatus: "completed",
          },
        ],
        nextCursor: null,
      }),
    }),
  );

  await goto(page, "/captures");
  const longCard = page.locator("li").filter({ hasText: "Paragraph 1" });
  const shortCard = page
    .locator("li")
    .filter({ hasText: "Short Capture remains fully visible." });
  const transcriptCard = page
    .locator("li")
    .filter({ hasText: "Transcript line 1" });
  const linkCard = page.locator("li").filter({ hasText: "Link capture" });

  await expect(longCard.getByText(/show more/i)).toBeVisible();
  await expect(shortCard.getByText(/show more/i)).toHaveCount(0);
  await expect(transcriptCard.getByText(/show more/i)).toBeVisible();
  await expect(longCard.locator(".ch-capture-card-body")).not.toHaveAttribute(
    "role",
  );
  await expect(
    longCard.getByRole("button", { name: "Open Capture" }),
  ).toBeVisible();

  await longCard.getByRole("button", { name: "More options" }).click();
  await expect(page.getByRole("menuitem", { name: /delete/i })).toBeVisible();
  await expect(page.getByRole("dialog", { name: "Capture" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  const cardBoxBefore = await longCard.boundingBox();
  expect(cardBoxBefore).not.toBeNull();
  if (isMobile) {
    await longCard.locator(".ch-capture-card-body").click({
      position: { x: 6, y: 6 },
    });
  } else {
    await longCard.click({
      position: {
        x: 6,
        y: Math.max(6, (cardBoxBefore?.height ?? 12) - 6),
      },
    });
  }

  const dialog = page.getByRole("dialog", { name: "Capture" });
  await expect(dialog).toBeVisible();
  await expect(
    dialog.getByText(
      "Paragraph 14 keeps enough detail to make this Capture intentionally long.",
      { exact: true },
    ),
  ).toBeVisible();
  const dialogBox = await dialog.boundingBox();
  expect(dialogBox).not.toBeNull();
  if (isMobile) {
    expect(dialogBox?.x).toBeCloseTo(0, 0);
    expect(dialogBox?.y).toBeCloseTo(0, 0);
    expect(dialogBox?.width).toBeCloseTo(page.viewportSize()?.width ?? 0, 0);
    expect(dialogBox?.height).toBeCloseTo(page.viewportSize()?.height ?? 0, 0);
  } else {
    expect(dialogBox?.width).toBeLessThanOrEqual(760);
    expect(dialogBox?.x).toBeGreaterThan(0);
  }

  await expect(dialog.locator("header h2")).toHaveClass(/sr-only/);
  const headerMetaBox = await dialog.locator("header .font-code").boundingBox();
  const dismissBox = await dialog
    .getByRole("button", { name: /dismiss/i })
    .boundingBox();
  expect(headerMetaBox).not.toBeNull();
  expect(dismissBox).not.toBeNull();
  expect(
    Math.abs(
      (headerMetaBox?.y ?? 0) +
        (headerMetaBox?.height ?? 0) / 2 -
        ((dismissBox?.y ?? 0) + (dismissBox?.height ?? 0) / 2),
    ),
  ).toBeLessThanOrEqual(2);
  await expect(
    dialog.locator("header").getByRole("button", { name: /^edit$/i }),
  ).toHaveCount(0);
  const detailText = dialog.locator(".ch-capture-detail-text");
  await detailText.evaluate((element) => {
    const textNode = element.querySelector("p")?.firstChild;
    if (!textNode) return;
    const range = document.createRange();
    range.selectNodeContents(textNode);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    (element as HTMLElement).click();
  });
  await expect(dialog.locator("textarea")).toHaveCount(0);
  await page.evaluate(() => window.getSelection()?.removeAllRanges());
  await detailText.click();
  const editor = dialog.locator("textarea");
  await expect(editor).toHaveValue(longMarkdown);
  await expect(longCard.locator("textarea")).toHaveCount(0);
  expect(
    await editor.evaluate((element) => getComputedStyle(element).overflowY),
  ).toBe("hidden");
  expect(
    await editor.evaluate(
      (element) => element.scrollHeight - element.clientHeight,
    ),
  ).toBeLessThanOrEqual(2);
  await dialog.getByRole("button", { name: /^cancel$/i }).click();
  await expect(dialog).toBeVisible();
  await expect(editor).toHaveCount(0);

  await dialog.getByRole("button", { name: /dismiss/i }).click();
  await expect(dialog).toHaveCount(0);
  const cardBoxAfter = await longCard.boundingBox();
  expect(cardBoxAfter?.width).toBeCloseTo(cardBoxBefore?.width ?? 0, 0);
  expect(cardBoxAfter?.height).toBeCloseTo(cardBoxBefore?.height ?? 0, 0);

  const shortCardOpen = shortCard.getByRole("button", {
    name: "Open Capture",
  });
  await shortCardOpen.focus();
  await page.keyboard.press("Enter");
  const shortDialog = page.getByRole("dialog", { name: "Capture" });
  await expect(shortDialog).toBeVisible();
  const shortReadModalBox = await shortDialog.boundingBox();
  const shortDetailText = shortDialog.locator(".ch-capture-detail-text");
  const surface2Background = await page.evaluate(() => {
    const probe = document.createElement("div");
    probe.style.background = "var(--surface-2)";
    document.body.append(probe);
    const background = getComputedStyle(probe).backgroundColor;
    probe.remove();
    return background;
  });
  if (!isMobile) {
    await shortDetailText.hover();
    await expect
      .poll(() =>
        shortDetailText.evaluate(
          (element) => getComputedStyle(element).backgroundColor,
        ),
      )
      .toBe(surface2Background);
  }
  const shortReadSurfaceBox = await shortDetailText.boundingBox();
  const shortReadTextBox = await shortDetailText.locator("p").boundingBox();
  const shortReadStyle = await shortDetailText
    .locator("p")
    .evaluate((element) => ({
      fontSize: getComputedStyle(element).fontSize,
      lineHeight: getComputedStyle(element).lineHeight,
    }));
  await shortDetailText.click();
  const shortEditor = shortDialog.locator("textarea");
  const shortEditModalBox = await shortDialog.boundingBox();
  const shortEditorBox = await shortEditor.boundingBox();
  await expect(
    shortDialog.locator("header").getByRole("button", { name: /^save$/i }),
  ).toBeVisible();
  await expect(
    shortDialog.locator("header").getByRole("button", { name: /^cancel$/i }),
  ).toBeVisible();
  const shortEditorStyle = await shortEditor.evaluate((element) => ({
    backgroundColor: getComputedStyle(element).backgroundColor,
    borderTopWidth: getComputedStyle(element).borderTopWidth,
    fontSize: getComputedStyle(element).fontSize,
    lineHeight: getComputedStyle(element).lineHeight,
    paddingLeft: getComputedStyle(element).paddingLeft,
    paddingRight: getComputedStyle(element).paddingRight,
  }));
  expect(shortEditorBox?.x).toBeCloseTo(shortReadSurfaceBox?.x ?? 0, 0);
  expect(shortEditorBox?.width).toBeCloseTo(shortReadSurfaceBox?.width ?? 0, 0);
  expect(
    (shortEditorBox?.x ?? 0) + Number.parseFloat(shortEditorStyle.paddingLeft),
  ).toBeCloseTo(shortReadTextBox?.x ?? 0, 0);
  expect(
    (shortEditorBox?.width ?? 0) -
      Number.parseFloat(shortEditorStyle.paddingLeft) -
      Number.parseFloat(shortEditorStyle.paddingRight),
  ).toBeCloseTo(shortReadTextBox?.width ?? 0, 0);
  expect(shortEditorStyle.fontSize).toBe(shortReadStyle.fontSize);
  expect(shortEditorStyle.lineHeight).toBe(shortReadStyle.lineHeight);
  expect(shortEditorStyle.borderTopWidth).toBe("0px");
  expect(shortEditorStyle.backgroundColor).toBe(surface2Background);
  expect(
    Math.abs(
      (shortEditModalBox?.height ?? 0) - (shortReadModalBox?.height ?? 0),
    ),
  ).toBeLessThanOrEqual(2);
  await shortEditor.fill("Short Capture remains fully visible. #");
  const todoSuggestion = shortDialog.getByRole("button", {
    name: /#todo.*mark as todo.*tab/i,
  });
  await expect(todoSuggestion).toBeVisible();
  await shortEditor.press("Tab");
  await expect(shortEditor).toHaveValue(
    "Short Capture remains fully visible. #todo ",
  );
  await shortDialog.getByRole("button", { name: /^cancel$/i }).click();
  await shortDialog.getByRole("button", { name: /dismiss/i }).click();

  await transcriptCard.locator(".ch-capture-card-body").click();
  const transcriptDialog = page.getByRole("dialog", { name: "Capture" });
  await expect(
    transcriptDialog.getByText(
      "Transcript line 12 preserves the complete recording.",
      { exact: true },
    ),
  ).toBeVisible();
  await transcriptDialog.locator(".ch-capture-detail-transcript").click();
  await expect(transcriptDialog.locator("textarea")).toHaveValue(
    longTranscript,
  );
  await transcriptDialog.getByRole("button", { name: /dismiss/i }).click();

  await linkCard.getByRole("button", { name: "Open Capture" }).click();
  const linkDialog = page.getByRole("dialog", { name: "Capture" });
  await expect(
    linkDialog.getByText("Link-derived internal text", { exact: false }),
  ).toHaveCount(0);
  await expect(linkDialog.getByText(/transcript/i)).toHaveCount(0);
  await expect(linkDialog.locator('img[src*="attacker.invalid"]')).toHaveCount(
    0,
  );
  expect(attackerRequests).toBe(0);
});

test("captures: closing a changed editor asks before discarding", async ({
  page,
  isMobile,
}) => {
  await goto(page, "/captures");
  const card = page.locator("li").first();
  await card.locator(".ch-capture-card-body").click();

  const detailDialog = page.getByRole("dialog", { name: "Capture" });
  const discardDialog = page.getByRole("dialog", {
    name: "Discard unsaved changes?",
  });
  if (!isMobile) {
    await page.mouse.click(2, 2);
    await expect(detailDialog).toHaveCount(0);
    await expect(discardDialog).toHaveCount(0);
    await card.locator(".ch-capture-card-body").click();
  }
  await detailDialog.locator(".ch-capture-detail-text").click();
  const editor = detailDialog.locator("textarea");
  const original = await editor.inputValue();
  await editor.fill(`${original}\nUnsaved edit`);
  if (isMobile) {
    await detailDialog.getByRole("button", { name: /dismiss/i }).click();
  } else {
    await page.mouse.click(2, 2);
  }

  await expect(discardDialog).toBeVisible();
  await discardDialog.getByRole("button", { name: "Keep editing" }).click();
  await expect(detailDialog).toBeVisible();
  await expect(editor).toHaveValue(`${original}\nUnsaved edit`);

  await detailDialog.getByRole("button", { name: /dismiss/i }).click();
  await discardDialog.getByRole("button", { name: "Discard changes" }).click();
  await expect(detailDialog).toHaveCount(0);
});

test("captures: switching changed editors asks before discarding", async ({
  page,
}) => {
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [
          {
            ...capture(
              "00000000-0000-4000-8000-000000000018",
              "Editable audio Capture",
              "2026-06-06T10:00:00Z",
            ),
            mediaType: "audio",
            transcript: "Editable transcript",
            transcriptionStatus: "completed",
          },
        ],
        nextCursor: null,
      }),
    }),
  );

  await goto(page, "/captures");
  await page.getByRole("button", { name: "Open Capture" }).click();
  const detailDialog = page.getByRole("dialog", { name: "Capture" });
  const discardDialog = page.getByRole("dialog", {
    name: "Discard unsaved changes?",
  });

  await detailDialog.locator(".ch-capture-detail-text").click();
  await detailDialog.locator("textarea").fill("Changed Capture text");
  await detailDialog.locator(".ch-capture-detail-transcript").click();
  await expect(discardDialog).toBeVisible();
  await discardDialog.getByRole("button", { name: "Keep editing" }).click();
  await expect(detailDialog.locator("textarea")).toHaveValue(
    "Changed Capture text",
  );

  await detailDialog.locator(".ch-capture-detail-transcript").click();
  await discardDialog.getByRole("button", { name: "Discard changes" }).click();
  await expect(detailDialog.locator("textarea")).toHaveValue(
    "Editable transcript",
  );
  await detailDialog.locator("textarea").fill("Changed transcript");
  await detailDialog.locator(".ch-capture-detail-text").click();
  await expect(discardDialog).toBeVisible();
  await discardDialog.getByRole("button", { name: "Keep editing" }).click();
  await expect(detailDialog.locator("textarea")).toHaveValue(
    "Changed transcript",
  );
});

test("captures: failed detail save retains the draft for retry", async ({
  page,
}) => {
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [
          capture(
            "00000000-0000-4000-8000-000000000019",
            "Save failure Capture",
            "2026-06-06T10:00:00Z",
          ),
        ],
        nextCursor: null,
      }),
    }),
  );
  await page.route("**/api/captures/**", (route) => {
    if (route.request().method() !== "PATCH") return route.fallback();
    return route.fulfill({
      status: 503,
      contentType: "application/json",
      body: JSON.stringify({ detail: "Unavailable" }),
    });
  });

  await goto(page, "/captures");
  await page.getByRole("button", { name: "Open Capture" }).click();
  const detailDialog = page.getByRole("dialog", { name: "Capture" });
  await detailDialog.locator(".ch-capture-detail-text").click();
  const editor = detailDialog.locator("textarea");
  await editor.fill("Draft that must survive");
  await detailDialog.getByRole("button", { name: /^save$/i }).click();

  await expect(editor).toHaveValue("Draft that must survive");
  await expect(
    detailDialog.getByRole("button", { name: /^save$/i }),
  ).toBeEnabled();
});

test("captures: recording can be stopped", async ({ page }) => {
  await page.addInitScript(() => {
    const track = { stop() {} };
    const mockStream = { getTracks: () => [track] };
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia: async () => mockStream },
    });

    class MockMediaRecorder {
      state = "inactive";
      stream = mockStream;
      ondataavailable: ((event: { data: Blob }) => void) | null = null;
      onstop: (() => void) | null = null;

      start() {
        this.state = "recording";
      }

      stop() {
        this.state = "inactive";
        this.ondataavailable?.({
          data: new Blob(["audio"], { type: "audio/webm" }),
        });
        this.onstop?.();
      }
    }

    (
      window as unknown as { MediaRecorder: typeof MockMediaRecorder }
    ).MediaRecorder = MockMediaRecorder;
  });
  await page.route("**/api/captures/upload", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ id: "mock-audio-capture" }),
    }),
  );

  await goto(page, "/captures");
  await page.getByRole("button", { name: /^record$/i }).click();
  const stopButton = page.getByRole("button", { name: /stop/i });
  await expect(stopButton).toBeVisible();
  await stopButton.click();
  await expect(page.getByRole("button", { name: /^record$/i })).toBeVisible();
});

test("captures: delete action stays in the overflow menu", async ({ page }) => {
  await goto(page, "/captures");
  await expect(page.getByRole("button", { name: /^delete$/i })).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: /more options/i }).first(),
  ).toBeVisible();
});

test("captures: loads the next cursor page", async ({ page }) => {
  await page.route("**/api/captures/page**", async (route) => {
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(
        cursor === "next-page"
          ? {
              items: [
                capture(
                  "00000000-0000-4000-8000-000000000002",
                  "Second cursor page",
                  "2026-06-05T10:00:00Z",
                ),
              ],
              nextCursor: null,
            }
          : {
              items: [
                capture(
                  "00000000-0000-4000-8000-000000000001",
                  "First cursor page",
                  "2026-06-06T10:00:00Z",
                ),
              ],
              nextCursor: "next-page",
            },
      ),
    });
  });

  await goto(page, "/captures");
  await expect(page.getByText("First cursor page")).toBeVisible();
  await page.getByRole("button", { name: /load more/i }).click();
  await expect(page.getByText("Second cursor page")).toBeVisible();
});

test("captures: seeded markdown and precise timestamp render", async ({
  page,
}) => {
  await goto(page, "/captures");
  const seededCard = page
    .locator("li")
    .filter({ hasText: "E2E seeded alpha capture" });
  await expect(seededCard.locator(".ch-prose")).toBeVisible();
  await expect(seededCard.locator("strong")).toHaveText(
    "E2E seeded alpha capture",
  );
  await expect(seededCard.locator("[title]")).toHaveAttribute(
    "title",
    /\w{3} \d{1,2}, \d{4} · \d{1,2}:\d{2}(am|pm)/i,
  );
});

// Search and recall

test("search: capture result opens its context", async ({ page }) => {
  const result = capture(
    "00000000-0000-4000-8000-000000000003",
    "Recall anchor result",
    "2026-06-06T11:00:00Z",
  );
  await page.route("**/api/find**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        degraded: false,
        items: [
          {
            id: result.id,
            content: result.rawText,
            createdAt: result.createdAt,
            lexical: true,
            modality: "raw_text",
            score: 1,
          },
        ],
      }),
    }),
  );
  await page.route("**/api/captures/page**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ items: [], nextCursor: null }),
    }),
  );
  await page.route("**/api/captures/context**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        items: [result],
        anchorIndex: 0,
        hasEarlier: false,
        hasLater: false,
      }),
    }),
  );

  await goto(page, "/captures");
  await visibleSearchTrigger(page).click();
  await page.getByPlaceholder(/^search/i).fill("Recall anchor");
  await page.getByRole("button", { name: /recall anchor result/i }).click();

  await expect(page).toHaveURL(/\/captures\/context\?anchorId=/);
  await expect(page.getByText("This Capture")).toBeVisible();
  await expect(page.getByText("Recall anchor result")).toBeVisible();
});

test("search: long result titles truncate with ellipsis", async ({ page }) => {
  const longTitle =
    "E2E searchable capture with a deliberately very long title that must truncate cleanly";
  await page.route("**/api/find**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        degraded: false,
        items: [
          {
            id: "00000000-0000-4000-8000-000000000004",
            content: longTitle,
            createdAt: "2026-06-06T11:00:00Z",
            lexical: true,
            modality: "raw_text",
            score: 1,
          },
        ],
      }),
    }),
  );

  await goto(page, "/");
  await visibleSearchTrigger(page).click();
  await page.getByPlaceholder(/^search/i).fill("searchable");
  const title = page.getByText(longTitle, { exact: true });
  await expect(title).toBeVisible();
  await expect(title).toHaveCSS("overflow", "hidden");
  await expect(title).toHaveCSS("text-overflow", "ellipsis");
});

test("search: escape closes the modal", async ({ page }) => {
  await goto(page, "/");
  await visibleSearchTrigger(page).click();
  const input = page.getByPlaceholder(/^search/i);
  await expect(input).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(input).toHaveCount(0);
});
