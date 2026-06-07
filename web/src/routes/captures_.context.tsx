import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { useGetCaptureContext } from "../api";
import { CaptureContextTimeline } from "../components/CaptureContextTimeline";
import { Nav } from "../components/nav";

export const Route = createFileRoute("/captures_/context")({
  validateSearch: (search: Record<string, unknown>) => ({
    anchorId: typeof search.anchorId === "string" ? search.anchorId : "",
  }),
  component: CaptureContext,
});

function CaptureContext() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const { anchorId } = Route.useSearch();
  const navigate = useNavigate();
  const query = useGetCaptureContext(
    { anchorId, before: 20, after: 20 },
    { query: { enabled: anchorId.length > 0 } },
  );

  useEffect(() => {
    if (!anchorId) void navigate({ to: "/captures", replace: true });
  }, [anchorId, navigate]);

  return (
    <>
      <Nav />
      <main className="ch-page-shell ch-context-page">
        <header className="ch-page-head">
          <Link to="/captures" className="ch-btn ch-btn-ghost ch-btn-sm">
            ← {t("title")}
          </Link>
          <h1 className="ch-title">{t("context.title")}</h1>
          <p className="ch-page-subtitle">{t("context.subtitle")}</p>
        </header>
        {query.isLoading && <p className="ch-meta">{tc("loading")}</p>}
        {query.error && (
          <div className="ch-page-error">{t("context.failedToLoad")}</div>
        )}
        {query.data && (
          <CaptureContextTimeline
            items={query.data.items ?? []}
            anchorIndex={query.data.anchorIndex}
            hasEarlier={query.data.hasEarlier}
            hasLater={query.data.hasLater}
          />
        )}
      </main>
    </>
  );
}
