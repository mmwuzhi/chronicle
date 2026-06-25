import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  getListTrashedCapturesQueryKey,
  useListTrashedCaptures,
  useRestoreCapture,
} from "../api";
import { Nav } from "../components/nav";
import { TrashList } from "../components/TrashList";

export const Route = createFileRoute("/trash")({ component: Trash });

function Trash() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [restoringId, setRestoringId] = useState<string | null>(null);

  const query = useListTrashedCaptures();
  const restore = useRestoreCapture({
    mutation: {
      onSuccess: () => {
        void queryClient.invalidateQueries({
          queryKey: getListTrashedCapturesQueryKey(),
        });
        void queryClient.invalidateQueries({
          queryKey: getListCapturePageInfiniteQueryKey(),
        });
      },
      onSettled: () => setRestoringId(null),
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
          />
        )}
      </main>
    </>
  );
}
