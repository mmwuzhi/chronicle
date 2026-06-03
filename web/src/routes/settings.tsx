import {
  createFileRoute,
  useNavigate,
  useSearch,
} from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { z } from "zod";
import { Nav } from "../components/nav";
import { useGetMe } from "../api";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { PasswordModal } from "../components/settings/PasswordModal";
import { PasskeysSection } from "../components/settings/PasskeysSection";
import { LinkedAccountsSection } from "../components/settings/LinkedAccountsSection";
import { MFASection } from "../components/settings/MFASection";
import { DangerSection } from "../components/settings/DangerSection";
import { apiFetch } from "../lib/apiFetch";

export const Route = createFileRoute("/settings")({
  component: Settings,
  validateSearch: z.object({
    oauth_linked: z.string().optional(),
    oauth_error: z.string().optional(),
  }),
});

const LANGS = [
  { code: "en", label: "English" },
  { code: "zh", label: "中文" },
  { code: "ja", label: "日本語" },
] as const;

type Section = "account" | "security";

function capitalize(s: string) { return s.charAt(0).toUpperCase() + s.slice(1); }

function AccountSection() {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const [pwModalOpen, setPwModalOpen] = useState(false);
  const [resendState, setResendState] = useState<"idle" | "loading" | "sent" | "error">("idle");
  const { data: me, isLoading } = useGetMe();

  if (isLoading) return <p className="ch-meta">{tc("loading")}</p>;
  if (!me) return null;

  return (
    <>
      {!me.emailVerified && (
        <div style={{
          borderRadius: "var(--radius-sm)", background: "#fffbeb", border: "1px solid #fcd34d",
          padding: "12px 16px", fontSize: "var(--fs-sm)", color: "#92400e",
          display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, marginBottom: 8,
        }}>
          <span>{t("profile.verifyHint")}</span>
          <button
            disabled={resendState !== "idle"}
            onClick={async () => {
              setResendState("loading");
              try {
                const res = await apiFetch("/auth/resend-verification", { method: "POST" });
                setResendState(res.status === 429 ? "error" : "sent");
              } catch { setResendState("error"); }
              setTimeout(() => setResendState("idle"), 4000);
            }}
            className="ch-btn ch-btn-sm"
            style={{ flexShrink: 0 }}
          >
            {resendState === "loading" ? t("profile.verifySending") :
              resendState === "sent" ? t("profile.verifySent") :
                resendState === "error" ? t("profile.verifyFailed") : t("profile.verifyResend")}
          </button>
        </div>
      )}

      <div className="ch-divide">
        <div className="ch-setrow">
          <div className="lbl"><span>{t("profile.email")}</span></div>
          <span style={{ fontSize: "var(--fs-sm)", color: "var(--text)" }}>{me.email}</span>
        </div>
        <div className="ch-setrow">
          <div className="lbl"><span>{t("password.label")}</span></div>
          <button className="ch-btn ch-btn-sm" onClick={() => setPwModalOpen(true)}>
            {me.hasPassword ? t("password.changePassword") : t("password.setPassword")}
          </button>
        </div>
        <LanguageRow />
      </div>

      <LinkedAccountsSection />

      <PasswordModal open={pwModalOpen} onOpenChange={setPwModalOpen} hasPassword={me.hasPassword} />
    </>
  );
}

function LanguageRow() {
  const { t, i18n } = useTranslation("settings");
  return (
    <div className="ch-setrow">
      <div className="lbl"><span>{t("language.title")}</span></div>
      <select
        value={LANGS.find((l) => i18n.language.startsWith(l.code))?.code ?? "en"}
        onChange={(e) => i18n.changeLanguage(e.target.value)}
        className="ch-input"
        style={{ width: "auto", padding: "6px 10px", fontSize: "var(--fs-sm)" }}
      >
        {LANGS.map((lang) => <option key={lang.code} value={lang.code}>{lang.label}</option>)}
      </select>
    </div>
  );
}

function SecuritySection() {
  const { t } = useTranslation("settings");
  return (
    <>
      <div className="ch-divide">
        <div style={{ padding: "16px 0" }}><PasskeysSection /></div>
        <div style={{ padding: "16px 0" }}><MFASection /></div>
      </div>

      {/* Danger zone inside security */}
      <div style={{ marginTop: 32 }}>
        <div style={{ border: "1px solid #fca5a5", borderRadius: "var(--radius)", padding: "var(--pad)" }}>
          <p style={{ margin: "0 0 12px", fontSize: "var(--fs-xs)", fontWeight: 700, letterSpacing: "0.08em", textTransform: "uppercase", color: "#c2410c" }}>
            {t("danger.title")}
          </p>
          <DangerSection />
        </div>
      </div>
    </>
  );
}

function Settings() {
  const { t } = useTranslation("settings");
  const navigate = useNavigate();
  const search = useSearch({ from: "/settings" });
  const queryClient = useQueryClient();
  const [section, setSection] = useState<Section>("account");
  const [toast, setToast] = useState<string | null>(() => {
    if (search.oauth_linked) return t("account.linkSuccess", { provider: capitalize(search.oauth_linked) });
    if (search.oauth_error) return t("account.linkError");
    return null;
  });

  const { error } = useGetMe();

  useEffect(() => {
    if (search.oauth_linked) {
      queryClient.invalidateQueries({ queryKey: ["/users/me"] });
      window.history.replaceState({}, "", "/settings");
    } else if (search.oauth_error) {
      window.history.replaceState({}, "", "/settings");
    }
  }, [search.oauth_linked, search.oauth_error, queryClient]);

  useEffect(() => {
    if (toast) {
      const timer = setTimeout(() => setToast(null), 4000);
      return () => clearTimeout(timer);
    }
  }, [toast]);

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) { navigate({ to: "/login" }); return null; }
  }

  const tabs: { id: Section; label: string }[] = [
    { id: "account", label: t("account.title") },
    { id: "security", label: t("security.title") },
  ];

  return (
    <>
      <Nav />

      {toast && (
        <div style={{
          position: "fixed", top: 66, left: "50%", transform: "translateX(-50%)", zIndex: 50,
          background: "var(--text)", color: "#fff", fontSize: "var(--fs-sm)",
          padding: "8px 16px", borderRadius: "var(--radius-pill)", boxShadow: "var(--shadow-lg)",
        }}>
          {toast}
        </div>
      )}

      <div style={{ maxWidth: 640, margin: "0 auto", padding: "0 18px 40px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
        </div>

        <div className="ch-tabs">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              className={`ch-tabbtn${section === tab.id ? " active" : ""}`}
              onClick={() => setSection(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>

        <div style={{ marginTop: 20 }}>
          {section === "account" && <AccountSection />}
          {section === "security" && <SecuritySection />}
        </div>
      </div>
    </>
  );
}
