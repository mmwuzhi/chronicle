import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getReviewTodayQueryKey,
  useDeleteCapture,
  useRetryCaptureTranscription,
  useReviewToday,
  useSetCaptureRemind,
  useUpdateCapture,
} from "../api";
import type { CaptureBody } from "../api";
import { CaptureFeed } from "../components/CaptureFeed";
import { MutationToast } from "../components/mutation-toast";
import { Nav } from "../components/nav";
import { useConfirm } from "../components/confirm-dialog";
import { useMutationToast } from "../hooks/use-mutation-toast";

export const Route = createFileRoute("/review")({ component: Review });

function Review() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const mutationToast = useMutationToast();

  const reviewQuery = useReviewToday();
  const onThisDay = reviewQuery.data?.onThisDay ?? [];
  const rediscover = reviewQuery.data?.rediscover ?? [];
  const all: CaptureBody[] = [...onThisDay, ...rediscover];

  // Review is not a hot path, so every edit just invalidates the whole panel
  // rather than patching cached items in place.
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getReviewTodayQueryKey() });
  const onError = () => mutationToast.show(tc("errors.mutationFailed"));

  const update = useUpdateCapture({
    mutation: { onSuccess: invalidate, onError },
  });
  const remove = useDeleteCapture({
    mutation: { onSuccess: invalidate, onError },
  });
  const setRemind = useSetCaptureRemind({
    mutation: { onSuccess: invalidate, onError },
  });
  const retryTranscription = useRetryCaptureTranscription({
    mutation: { onSuccess: invalidate, onError },
  });

  const cardActions = {
    onDelete: async (id: string) => {
      const ok = await confirm({
        title: tc("confirm.deleteCapture"),
        description: tc("confirm.cannotUndo"),
        confirmLabel: tc("actions.delete"),
        variant: "danger" as const,
      });
      if (ok) remove.mutate({ id });
    },
    onSaveText: (id: string, rawText: string) =>
      update.mutate({ id, data: { rawText } }),
    onSaveTranscript: (id: string, transcript: string) =>
      update.mutate({ id, data: { transcript } }),
    onUseTranscript: (id: string, mode: "append" | "replace") => {
      const c = all.find((x) => x.id === id);
      if (!c?.transcript) return;
      const rawText =
        mode === "append" && c.rawText
          ? `${c.rawText}\n\n${c.transcript}`
          : c.transcript;
      update.mutate({ id, data: { rawText } });
    },
    onRetryTranscription: (id: string) => retryTranscription.mutate({ id }),
    onSetRemind: (id: string, at: string | null, hide: boolean) =>
      setRemind.mutate({ id, data: { at: at ?? undefined, hide } }),
    onMutationError: onError,
  };

  if (reviewQuery.error) {
    if (reviewQuery.error.status === 401) {
      void navigate({ to: "/login" });
      return null;
    }
    return <div className="ch-page-error">{t("failedToLoad")}</div>;
  }

  const empty = !reviewQuery.isLoading && all.length === 0;

  const sectionHead = (label: string, count: number) => (
    <div className="ch-section">
      <span className="bar" />
      <span className="ch-sectlabel">{label}</span>
      <span className="ch-sectcount">{count}</span>
      <span className="rule" />
    </div>
  );

  return (
    <>
      <Nav />
      <main className="ch-page-shell">
        <header className="ch-page-head">
          <h1 className="ch-title">{t("review.title")}</h1>
          <p className="ch-page-subtitle">{t("review.subtitle")}</p>
        </header>

        {reviewQuery.isLoading && <p className="ch-meta">{tc("loading")}</p>}

        {empty && (
          <div className="ch-empty">
            <p>{t("review.empty")}</p>
          </div>
        )}

        {onThisDay.length > 0 && (
          <section>
            {sectionHead(t("review.onThisDay"), onThisDay.length)}
            <CaptureFeed
              captures={onThisDay}
              loading={false}
              hasMore={false}
              loadingMore={false}
              onLoadMore={() => {}}
              {...cardActions}
            />
          </section>
        )}

        {rediscover.length > 0 && (
          <section>
            {sectionHead(t("review.rediscover"), rediscover.length)}
            <CaptureFeed
              captures={rediscover}
              loading={false}
              hasMore={false}
              loadingMore={false}
              onLoadMore={() => {}}
              {...cardActions}
            />
          </section>
        )}
      </main>
      <MutationToast message={mutationToast.message} />
    </>
  );
}
