import { createFileRoute } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { z } from "zod";
import { Nav } from "@/components/nav";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { AccountSection } from "@/components/settings/AccountSection";
import { PasskeysSection } from "@/components/settings/PasskeysSection";
import { MFASection } from "@/components/settings/MFASection";
import { DangerSection } from "@/components/settings/DangerSection";
import { WebhooksSection } from "@/components/settings/WebhooksSection";
import { QuickCaptureTokenSection } from "@/components/settings/QuickCaptureTokenSection";
import { PageHeader, PageShell, PageTitle } from "@/components/ui/page";
import { sectionTabClassName } from "@/components/ui/tab";
import { RAG_ENABLED } from "@/constants/features";
import { DataPortabilitySection } from "@/components/settings/DataPortabilitySection";
import { SharedCopiesSection } from "@/components/settings/SharedCopiesSection";

export const Route = createFileRoute("/_authenticated/settings")({
  component: Settings,
  validateSearch: z.object({
    oauth_linked: z.string().optional(),
    oauth_error: z.string().optional(),
  }),
});

type Section = "account" | "security" | "integrations" | "data";

function capitalize(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function SecuritySection() {
  const { t } = useTranslation("settings");
  return (
    <>
      <div className="divide-y divide-hairline">
        <div className="py-4">
          <PasskeysSection />
        </div>
        <div className="py-4">
          <MFASection />
        </div>
      </div>

      {/* Danger zone inside security */}
      <div className="mt-8">
        <div className="rounded-card border border-danger/35 p-4">
          <p className="mb-3 text-caption font-bold uppercase tracking-[0.08em] text-danger">
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
  const search = Route.useSearch();
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

  const tabs: { id: Section; label: string }[] = [
    { id: "account", label: t("account.title") },
    { id: "security", label: t("security.title") },
    { id: "integrations", label: t("integrations.title") },
    { id: "data", label: t("data.title") },
  ];

  return (
    <>
      <Nav />

      {toast && (
        <div className="fixed left-1/2 top-[66px] z-50 -translate-x-1/2 rounded-full bg-ink px-4 py-2 text-small text-surface shadow-overlay">
          {toast}
        </div>
      )}

      <PageShell className="max-w-2xl">
        <PageHeader>
          <PageTitle>{t("title")}</PageTitle>
        </PageHeader>

        <div className="mx-0 mb-1 mt-2 flex gap-[22px] border-b border-hairline">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              className={sectionTabClassName(section === tab.id)}
              onClick={() => setSection(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>

        <div className="mt-5">
          {section === "account" && <AccountSection />}
          {section === "security" && <SecuritySection />}
          {section === "integrations" && (
            <div className="flex flex-col gap-5">
              <QuickCaptureTokenSection />
              {RAG_ENABLED && <WebhooksSection />}
            </div>
          )}
          {section === "data" && (
            <div className="flex flex-col gap-5">
              <SharedCopiesSection />
              <DataPortabilitySection />
            </div>
          )}
        </div>
      </PageShell>
    </>
  );
}
