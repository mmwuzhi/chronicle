import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  getListCaptureTokensQueryKey,
  useCreateCaptureToken,
  useListCaptureTokens,
  useRevokeCaptureToken,
} from "../../api";
import { fmtDate } from "../../utils/format";

// Long-lived, create-only capture tokens for headless quick-capture clients
// (the iOS Action Button shortcut). The raw token is shown exactly once at
// creation — mirrors the recovery-code reveal pattern. Listing never returns
// the hash; revocation is server-side and immediate.
export function QuickCaptureTokenSection(): React.JSX.Element {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const { data, isLoading } = useListCaptureTokens();
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListCaptureTokensQueryKey() });

  const create = useCreateCaptureToken({ mutation: { onSuccess: invalidate } });
  const revoke = useRevokeCaptureToken({ mutation: { onSuccess: invalidate } });

  const [name, setName] = useState("");
  const [revealed, setRevealed] = useState<{
    name: string;
    token: string;
  } | null>(null);
  const [copied, setCopied] = useState(false);

  const submit = () => {
    if (!name.trim()) return;
    create.mutate(
      { data: { name: name.trim() } },
      {
        onSuccess: (res) => {
          setRevealed({ name: res.name, token: res.token });
          setCopied(false);
          setName("");
        },
      },
    );
  };

  const copy = async () => {
    if (!revealed) return;
    await navigator.clipboard.writeText(revealed.token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const tokens = data?.tokens ?? [];

  return (
    <section
      className="ch-card"
      style={{ display: "flex", flexDirection: "column", gap: 16 }}
    >
      <div>
        <h2 className="ch-section-title">
          {t("integrations.captureTokens.title")}
        </h2>
        <p className="ch-meta">{t("integrations.captureTokens.description")}</p>
      </div>

      {revealed && (
        <div
          className="ch-card"
          style={{
            display: "flex",
            flexDirection: "column",
            gap: 8,
            background: "var(--bg-subtle, rgba(0,0,0,0.03))",
          }}
        >
          <strong>{t("integrations.captureTokens.revealTitle")}</strong>
          <code
            style={{
              wordBreak: "break-all",
              fontFamily: "var(--font-mono, monospace)",
              fontSize: "var(--fs-sm)",
            }}
          >
            {revealed.token}
          </code>
          <p className="ch-meta">
            {t("integrations.captureTokens.revealHint")}
          </p>
          <p className="ch-meta">{t("integrations.captureTokens.docHint")}</p>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="ch-btn ch-btn-primary ch-btn-sm" onClick={copy}>
              {copied
                ? t("integrations.captureTokens.copied")
                : t("integrations.captureTokens.copy")}
            </button>
            <button
              className="ch-btn ch-btn-ghost ch-btn-sm"
              onClick={() => setRevealed(null)}
            >
              {t("integrations.captureTokens.done")}
            </button>
          </div>
        </div>
      )}

      {isLoading ? (
        <p className="ch-meta">{tc("loading")}</p>
      ) : tokens.length === 0 ? (
        <p className="ch-meta">{t("integrations.captureTokens.empty")}</p>
      ) : (
        <ul
          className="ch-list"
          style={{ display: "flex", flexDirection: "column", gap: 8 }}
        >
          {tokens.map((tok) => (
            <li
              key={tok.id}
              className="ch-row"
              style={{ display: "flex", alignItems: "center", gap: 8 }}
            >
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600 }}>{tok.name}</div>
                <div className="ch-meta">
                  {t("integrations.captureTokens.created", {
                    date: fmtDate(tok.createdAt),
                  })}
                  {" · "}
                  {tok.lastUsedAt
                    ? t("integrations.captureTokens.lastUsed", {
                        date: fmtDate(tok.lastUsedAt),
                      })
                    : t("integrations.captureTokens.neverUsed")}
                </div>
              </div>
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => revoke.mutate({ id: tok.id })}
              >
                {t("integrations.captureTokens.revoke")}
              </button>
            </li>
          ))}
        </ul>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <h3 className="ch-meta">{t("integrations.captureTokens.addTitle")}</h3>
        <input
          className="ch-input"
          placeholder={t("integrations.captureTokens.namePlaceholder")}
          value={name}
          onChange={(e) => setName(e.target.value)}
          maxLength={100}
        />
        <button
          className="ch-btn ch-btn-primary"
          onClick={submit}
          disabled={create.isPending || !name.trim()}
        >
          {t("integrations.captureTokens.generate")}
        </button>
      </div>
    </section>
  );
}
