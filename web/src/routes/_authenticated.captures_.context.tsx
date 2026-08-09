import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { useGetCaptureContext } from "@/api";
import { CaptureContextTimeline } from "@/components/CaptureContextTimeline";
import { CaptureRelated } from "@/components/CaptureRelated";
import { MutationToast } from "@/components/mutation-toast";
import { Nav } from "@/components/nav";
import { useMutationToast } from "@/hooks/use-mutation-toast";
import { buttonClassName } from "@/components/ui/button";
import {
  Meta,
  PageError,
  PageHeader,
  PageShell,
  PageTitle,
} from "@/components/ui/page";

export const Route = createFileRoute("/_authenticated/captures_/context")({
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
  const { message: mutationMessage, show: showMutationToast } =
    useMutationToast();
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
      <PageShell className="max-w-[860px]">
        <PageHeader className="pb-3 md:pb-3">
          <Link
            to="/captures"
            className={buttonClassName({
              variant: "ghost",
              size: "sm",
              className: "self-start",
            })}
          >
            ← {t("title")}
          </Link>
          <PageTitle>{t("context.title")}</PageTitle>
        </PageHeader>
        {query.isLoading && <Meta>{tc("loading")}</Meta>}
        {query.error && <PageError>{t("context.failedToLoad")}</PageError>}
        {query.data && (
          <CaptureContextTimeline
            items={query.data.items ?? []}
            anchorIndex={query.data.anchorIndex}
            hasEarlier={query.data.hasEarlier}
            hasLater={query.data.hasLater}
          />
        )}
        {anchorId && (
          <CaptureRelated
            anchorId={anchorId}
            onMutationError={() =>
              showMutationToast(tc("errors.mutationFailed"))
            }
          />
        )}
      </PageShell>
      <MutationToast message={mutationMessage} />
    </>
  );
}
