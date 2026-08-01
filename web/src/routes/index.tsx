import { createFileRoute, Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useGetMe, useListCapturePage } from "@/api";
import type { CaptureBody } from "@/api";

import { Nav } from "@/components/nav";
import { captureText } from "@/utils/capture";
import { timeAgo } from "@/utils/format";
import { buttonClassName } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  EmptyState,
  Meta,
  PageHeader,
  PageShell,
  PageTitle,
} from "@/components/ui/page";

export const Route = createFileRoute("/")({ component: Index });

function Dashboard() {
  const { t, i18n } = useTranslation("dashboard");

  const { data: me } = useGetMe();
  const { data: capturePage } = useListCapturePage(
    { limit: 8 },
    { query: { enabled: !!me } },
  );
  const recentCaptures = capturePage?.items ?? [];

  const now = new Date();
  const dayName = now
    .toLocaleDateString(undefined, { weekday: "long" })
    .toUpperCase();
  const monthDay = now
    .toLocaleDateString(undefined, { month: "short", day: "numeric" })
    .toUpperCase();
  const dateEyebrow = `${dayName} · ${monthDay}`;

  const hour = now.getHours();
  const greetingKey =
    hour < 12 ? "goodMorning" : hour < 17 ? "goodAfternoon" : "goodEvening";
  const name = me?.email?.split("@")[0] ?? "";

  return (
    <>
      <Nav />
      <PageShell className="pb-0">
        <PageHeader>
          <p className="text-caption font-semibold uppercase tracking-[0.13em] text-faint">
            {dateEyebrow}
          </p>
          <PageTitle>
            {t(greetingKey)} {name}
          </PageTitle>
        </PageHeader>

        <div className="mb-3 mt-[26px] flex items-center gap-2.5">
          <span className="h-[15px] w-px shrink-0 rounded-full bg-accent" />
          <span className="whitespace-nowrap font-app-display text-small font-bold uppercase tracking-[0.08em] text-ink">
            {t("recentCaptures")}
          </span>
          <span className="rounded-full bg-tint px-[7px] py-0.5 font-code text-[11px] font-semibold text-faint">
            {recentCaptures.length}
          </span>
          <span className="h-px flex-1 bg-hairline" />
          <Link
            to="/captures"
            className="whitespace-nowrap text-caption font-semibold text-muted no-underline hover:text-accent-strong"
          >
            {t("viewAll")} →
          </Link>
        </div>
        {recentCaptures.length === 0 ? (
          <EmptyState>
            <p>{t("noCaptures")}</p>
          </EmptyState>
        ) : (
          <div className="flex flex-col gap-3">
            {recentCaptures.map((c: CaptureBody) => (
              <Card
                asChild
                key={c.id}
                className="hover:border-strong hover:shadow-overlay"
              >
                <Link
                  to="/captures"
                  className="flex cursor-pointer flex-col gap-2 p-4 no-underline transition-[border-color,box-shadow]"
                >
                  <p className="m-0 line-clamp-2 overflow-hidden text-small leading-[1.55] text-ink">
                    {captureText(c) || "—"}
                  </p>
                  <div className="flex items-center gap-2">
                    {c.createdAt && (
                      <Meta className="ml-auto">
                        {timeAgo(c.createdAt, i18n.language)}
                      </Meta>
                    )}
                  </div>
                </Link>
              </Card>
            ))}
          </div>
        )}
      </PageShell>
    </>
  );
}

function Landing() {
  const { t } = useTranslation();
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-4 px-4">
      <div className="grid size-12 place-items-center rounded-card bg-accent text-2xl font-extrabold text-surface">
        C
      </div>
      <PageTitle>{t("brand")}</PageTitle>
      <p className="text-small text-muted">{t("tagline")}</p>
      <div className="mt-2 flex gap-2.5">
        <Link to="/login" className={buttonClassName({ variant: "primary" })}>
          {t("signIn")}
        </Link>
        <Link to="/register" className={buttonClassName()}>
          {t("createAccount")}
        </Link>
      </div>
    </main>
  );
}

function Index() {
  const { data: me, isLoading } = useGetMe();
  if (isLoading) return null;
  if (!me) return <Landing />;
  return <Dashboard />;
}
