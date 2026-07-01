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
import { useConfirm } from "../components/confirm-dialog";
import { Nav } from "../components/nav";
import { TrashList } from "../components/TrashList";

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
    return <div className="ch-page-error">{t("trash.failedToLoad")}</div>;
  }

  const captures = query.data ?? [];

  return (
    <>
      <Nav />
      <main className="ch-page-shell">
        <header className="ch-page-head">
          <Link to="/captures" className="ch-btn ch-btn-ghost ch-btn-sm">
            ← {t("title")}
          </Link>
          <h1 className="ch-title">{t("trash.title")}</h1>
          <p className="ch-page-subtitle">{t("trash.subtitle")}</p>
          {captures.length > 0 && (
            <button
              className="ch-btn ch-btn-ghost ch-btn-sm ch-btn-danger"
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
            </button>
          )}
        </header>
        {query.isLoading && <p className="ch-meta">{tc("loading")}</p>}
        {!query.isLoading && captures.length === 0 && (
          <p className="ch-meta">{t("trash.empty")}</p>
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
      </main>
    </>
  );
}
