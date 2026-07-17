import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  getListTrashedCapturesQueryKey,
  useEmptyTrash,
  useListTrashedCaptures,
  usePermanentlyDeleteCapture,
  useRestoreCapture,
} from "../api";
import { useConfirm } from "../hooks/use-confirm";
import { Nav } from "../components/nav";
import { TrashList } from "../components/TrashList";
import { Button, buttonClassName } from "../components/ui/button";
import {
  Meta,
  PageError,
  PageHeader,
  PageShell,
  PageSubtitle,
  PageTitle,
} from "../components/ui/page";

export const Route = createFileRoute("/trash")({ component: Trash });

function Trash() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [restoringId, setRestoringId] = useState<string | null>(null);

  const invalidateTrash = () =>
    void queryClient.invalidateQueries({
      queryKey: getListTrashedCapturesQueryKey(),
    });
  const invalidateLive = () =>
    void queryClient.invalidateQueries({
      queryKey: getListCapturePageInfiniteQueryKey(),
    });

  const query = useListTrashedCaptures();
  const restore = useRestoreCapture({
    mutation: {
      onSuccess: () => {
        invalidateTrash();
        invalidateLive();
      },
      onSettled: () => setRestoringId(null),
    },
  });
  // Permanent delete / empty trash are the trash-only hard-delete escape hatch:
  // irreversible, so both go through a danger confirm first.
  const permanentDelete = usePermanentlyDeleteCapture({
    mutation: { onSuccess: invalidateTrash },
  });
  const emptyTrash = useEmptyTrash({
    mutation: {
      onSuccess: () => {
        invalidateTrash();
        invalidateLive();
      },
    },
  });

  if (query.error) {
    if (query.error.status === 401) {
      void navigate({ to: "/login" });
      return null;
    }
    return <PageError>{t("trash.failedToLoad")}</PageError>;
  }

  const captures = query.data ?? [];

  return (
    <>
      <Nav />
      <PageShell>
        <PageHeader>
          <Link
            to="/captures"
            className={buttonClassName({ variant: "ghost", size: "sm" })}
          >
            ← {t("title")}
          </Link>
          <PageTitle>{t("trash.title")}</PageTitle>
          <PageSubtitle>{t("trash.subtitle")}</PageSubtitle>
          {captures.length > 0 && (
            <Button
              variant="ghost"
              size="sm"
              className="self-start text-danger hover:bg-danger-weak hover:text-danger-strong"
              onClick={async () => {
                const ok = await confirm({
                  title: t("trash.emptyAll"),
                  description: t("trash.emptyConfirm"),
                  confirmLabel: t("trash.emptyAll"),
                  variant: "danger",
                });
                if (ok) emptyTrash.mutate();
              }}
            >
              {t("trash.emptyAll")}
            </Button>
          )}
        </PageHeader>
        {query.isLoading && <Meta>{tc("loading")}</Meta>}
        {!query.isLoading && captures.length === 0 && (
          <Meta>{t("trash.empty")}</Meta>
        )}
        {captures.length > 0 && (
          <TrashList
            captures={captures}
            restoringId={restoringId}
            onRestore={(id) => {
              setRestoringId(id);
              restore.mutate({ id });
            }}
            onPermanentDelete={async (id) => {
              const ok = await confirm({
                title: t("trash.deletePermanently"),
                description: t("trash.deletePermanentlyConfirm"),
                confirmLabel: t("trash.deletePermanently"),
                variant: "danger",
              });
              if (ok) permanentDelete.mutate({ id });
            }}
          />
        )}
      </PageShell>
    </>
  );
}
