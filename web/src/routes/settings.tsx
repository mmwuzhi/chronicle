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
import { AccountSection } from "../components/settings/AccountSection";
import { PasskeysSection } from "../components/settings/PasskeysSection";
import { MFASection } from "../components/settings/MFASection";
import { DangerSection } from "../components/settings/DangerSection";
import { WebhooksSection } from "../components/settings/WebhooksSection";
import { QuickCaptureTokenSection } from "../components/settings/QuickCaptureTokenSection";

export const Route = createFileRoute("/settings")({
  component: Settings,
  validateSearch: z.object({
    oauth_linked: z.string().optional(),
    oauth_error: z.string().optional(),
  }),
});

type Section = "account" | "security" | "integrations";

function capitalize(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function SecuritySection() {
  const { t } = useTranslation("settings");
  return (
    <>
      <div className="ch-divide">
        <div style={{ padding: "16px 0" }}>
          <PasskeysSection />
        </div>
        <div style={{ padding: "16px 0" }}>
          <MFASection />
        </div>
      </div>

      {/* Danger zone inside security */}
      <div style={{ marginTop: 32 }}>
        <div
          style={{
            border: "1px solid #fca5a5",
            borderRadius: "var(--radius)",
            padding: "var(--pad)",
          }}
        >
          <p
            style={{
              margin: "0 0 12px",
              fontSize: "var(--fs-xs)",
              fontWeight: 700,
              letterSpacing: "0.08em",
              textTransform: "uppercase",
              color: "#c2410c",
            }}
          >
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
    { id: "integrations", label: t("integrations.title") },
  ];

  return (
    <>
      <Nav />

      {toast && (
        <div
          style={{
            position: "fixed",
            top: 66,
            left: "50%",
            transform: "translateX(-50%)",
            zIndex: 50,
            background: "var(--text)",
            color: "#fff",
            fontSize: "var(--fs-sm)",
            padding: "8px 16px",
            borderRadius: "var(--radius-pill)",
            boxShadow: "var(--shadow-lg)",
          }}
        >
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
          {section === "integrations" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
              <QuickCaptureTokenSection />
              <WebhooksSection />
            </div>
          )}
        </div>
      </div>
    </>
  );
}
