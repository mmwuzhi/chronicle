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

type Section = "account" | "security" | "danger";

function capitalize(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function AccountSection() {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const [pwModalOpen, setPwModalOpen] = useState(false);
  const [resendState, setResendState] = useState<
    "idle" | "loading" | "sent" | "error"
  >("idle");
  const { data: me, isLoading } = useGetMe();

  if (isLoading) {
    return <div className="text-gray-400 text-sm">{tc("loading")}</div>;
  }

  if (!me) return null;

  return (
    <>
      <h2 className="text-lg font-semibold">{t("account.title")}</h2>

      {!me.emailVerified && (
        <div className="rounded-md bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-700 flex items-center justify-between gap-3">
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
            className="text-xs px-2.5 py-1 rounded-md border border-amber-400 bg-amber-100 hover:bg-amber-200 transition-colors disabled:opacity-50 whitespace-nowrap flex-shrink-0"
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

      <div className="divide-y divide-gray-100">
        <div className="flex items-center justify-between py-4">
          <span className="text-sm text-gray-500">{t("profile.email")}</span>
          <span className="text-sm">{me.email}</span>
        </div>
        <div className="flex items-center justify-between py-4">
          <span className="text-sm text-gray-500">{t("password.label")}</span>
          <button
            onClick={() => setPwModalOpen(true)}
            className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
          >
            {me.hasPassword
              ? t("password.changePassword")
              : t("password.setPassword")}
          </button>
        </div>
        <LanguageRow />
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
    <div className="flex items-center justify-between py-4">
      <span className="text-sm text-gray-500">{t("language.title")}</span>
      <select
        value={
          LANGS.find((l) => i18n.language.startsWith(l.code))?.code ?? "en"
        }
        onChange={(e) => i18n.changeLanguage(e.target.value)}
        className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
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

function SecuritySection() {
  const { t } = useTranslation("settings");

  return (
    <>
      <h2 className="text-lg font-semibold">{t("security.title")}</h2>

      <div className="divide-y divide-gray-100">
        <div className="py-4">
          <PasskeysSection />
        </div>

        <div className="py-4">
          <MFASection />
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
    if (search.oauth_linked)
      return t("account.linkSuccess", {
        provider: capitalize(search.oauth_linked),
      });
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
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
  }

  const tabs: { id: Section; label: string }[] = [
    { id: "account", label: t("account.title") },
    { id: "security", label: t("security.title") },
    { id: "danger", label: t("danger.title") },
  ];

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />

      {toast && (
        <div className="fixed top-16 left-1/2 -translate-x-1/2 z-50 bg-gray-900 text-white text-sm px-4 py-2 rounded-lg shadow-lg">
          {toast}
        </div>
      )}

      <div className="max-w-4xl mx-auto px-4 md:px-8 py-8 md:py-12 flex flex-col gap-6 md:flex-row md:gap-12">
        <nav className="flex flex-row flex-wrap gap-1 md:flex-col md:w-44 md:shrink-0">
          <h1 className="w-full text-xl font-semibold mb-2">{t("title")}</h1>
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setSection(tab.id)}
              className={`text-left text-sm px-3 py-2 rounded-md transition-colors ${
                section === tab.id
                  ? "bg-gray-200/70 font-medium text-gray-900"
                  : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>

        <div className="flex-1 flex flex-col gap-4 min-w-0">
          {section === "account" && <AccountSection />}
          {section === "security" && <SecuritySection />}
          {section === "danger" && <DangerSection />}
        </div>
      </div>
    </div>
  );
}
