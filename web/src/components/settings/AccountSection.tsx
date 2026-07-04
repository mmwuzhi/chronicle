import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useGetMe } from "../../api";
import { setTodoEnabled, useTodoEnabled } from "../../hooks/use-todo-enabled";
import { apiFetch } from "../../lib/apiFetch";
import { PasswordModal } from "./PasswordModal";
import { LinkedAccountsSection } from "./LinkedAccountsSection";

const LANGS = [
  { code: "en", label: "English" },
  { code: "zh", label: "中文" },
  { code: "ja", label: "日本語" },
] as const;

export function AccountSection() {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const [pwModalOpen, setPwModalOpen] = useState(false);
  const [resendState, setResendState] = useState<
    "idle" | "loading" | "sent" | "error"
  >("idle");
  const { data: me, isLoading } = useGetMe();

  if (isLoading) return <p className="ch-meta">{tc("loading")}</p>;
  if (!me) return null;

  return (
    <>
      {!me.emailVerified && (
        <div
          style={{
            borderRadius: "var(--radius-sm)",
            background: "#fffbeb",
            border: "1px solid #fcd34d",
            padding: "12px 16px",
            fontSize: "var(--fs-sm)",
            color: "#92400e",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 12,
            marginBottom: 8,
          }}
        >
          <span>{t("profile.verifyHint")}</span>
          <button
            disabled={resendState !== "idle"}
            onClick={async () => {
              setResendState("loading");
              try {
                const res = await apiFetch("/auth/resend-verification", {
                  method: "POST",
                });
                setResendState(res.status === 429 ? "error" : "sent");
              } catch {
                setResendState("error");
              }
              setTimeout(() => setResendState("idle"), 4000);
            }}
            className="ch-btn ch-btn-sm"
            style={{ flexShrink: 0 }}
          >
            {resendState === "loading"
              ? t("profile.verifySending")
              : resendState === "sent"
                ? t("profile.verifySent")
                : resendState === "error"
                  ? t("profile.verifyFailed")
                  : t("profile.verifyResend")}
          </button>
        </div>
      )}

      <div className="ch-divide">
        <div className="ch-setrow">
          <div className="lbl">
            <span>{t("profile.email")}</span>
          </div>
          <span style={{ fontSize: "var(--fs-sm)", color: "var(--text)" }}>
            {me.email}
          </span>
        </div>
        <div className="ch-setrow">
          <div className="lbl">
            <span>{t("password.label")}</span>
          </div>
          <button
            className="ch-btn ch-btn-sm"
            onClick={() => setPwModalOpen(true)}
          >
            {me.hasPassword
              ? t("password.changePassword")
              : t("password.setPassword")}
          </button>
        </div>
        <LanguageRow />
        <TodoFeatureRow />
      </div>

      <LinkedAccountsSection />

      <PasswordModal
        open={pwModalOpen}
        onOpenChange={setPwModalOpen}
        hasPassword={me.hasPassword}
      />
    </>
  );
}

function LanguageRow() {
  const { t, i18n } = useTranslation("settings");
  return (
    <div className="ch-setrow">
      <div className="lbl">
        <span>{t("language.title")}</span>
      </div>
      <select
        value={
          LANGS.find((l) => i18n.language.startsWith(l.code))?.code ?? "en"
        }
        onChange={(e) => i18n.changeLanguage(e.target.value)}
        className="ch-input"
        style={{ width: "auto", padding: "6px 10px", fontSize: "var(--fs-sm)" }}
      >
        {LANGS.map((lang) => (
          <option key={lang.code} value={lang.code}>
            {lang.label}
          </option>
        ))}
      </select>
    </div>
  );
}

function TodoFeatureRow() {
  const { t } = useTranslation("settings");
  const enabled = useTodoEnabled();
  return (
    <div className="ch-setrow">
      <div className="lbl">
        <span>{t("todoFeature.title")}</span>
        <span className="ch-meta">{t("todoFeature.hint")}</span>
      </div>
      <input
        type="checkbox"
        checked={enabled}
        onChange={(e) => setTodoEnabled(e.target.checked)}
        style={{ width: 16, height: 16, cursor: "pointer" }}
      />
    </div>
  );
}
