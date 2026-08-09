import { createFileRoute } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getReviewTodayQueryKey,
  useDeleteCapture,
  useRetryCaptureTranscription,
  useReviewToday,
  useSetCaptureRemind,
  useUpdateCapture,
} from "@/api";
import type { CaptureBody, ReviewTodayParams } from "@/api";
import { CaptureFeed } from "@/components/CaptureFeed";
import { MutationToast } from "@/components/mutation-toast";
import { Nav } from "@/components/nav";
import { useConfirm } from "@/hooks/use-confirm";
import { useMutationToast } from "@/hooks/use-mutation-toast";
import {
  EmptyState,
  Meta,
  PageError,
  PageHeader,
  PageShell,
  PageSubtitle,
  PageTitle,
} from "@/components/ui/page";

export const Route = createFileRoute("/_authenticated/review")({
  component: Review,
});

function Review() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const mutationToast = useMutationToast();

  const reviewParams: ReviewTodayParams = {
    timezoneOffsetMinutes: new Date().getTimezoneOffset(),
  };
  const reviewQuery = useReviewToday(reviewParams);
  const onThisDay = reviewQuery.data?.onThisDay ?? [];
  const rediscover = reviewQuery.data?.rediscover ?? [];
  const all: CaptureBody[] = [...onThisDay, ...rediscover];

  // Review is not a hot path, so every edit just invalidates the whole panel
  // rather than patching cached items in place.
  const invalidate = () =>
    queryClient.invalidateQueries({
      queryKey: getReviewTodayQueryKey(reviewParams),
    });
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
      update.mutateAsync({ id, data: { rawText } }),
    onSaveTranscript: (id: string, transcript: string) =>
      update.mutateAsync({ id, data: { transcript } }),
    onUseTranscript: (capture: CaptureBody, mode: "append" | "replace") => {
      if (!capture.transcript) return;
      const rawText =
        mode === "append" && capture.rawText
          ? `${capture.rawText}\n\n${capture.transcript}`
          : capture.transcript;
      update.mutate({ id: capture.id, data: { rawText } });
    },
    onRetryTranscription: (id: string) => retryTranscription.mutate({ id }),
    onSetRemind: (id: string, at: string | null, hide: boolean) =>
      setRemind.mutate({ id, data: { at: at ?? undefined, hide } }),
    onMutationError: onError,
  };

  if (reviewQuery.error) {
    return <PageError>{t("failedToLoad")}</PageError>;
  }

  const empty = !reviewQuery.isLoading && all.length === 0;

  const sectionHead = (label: string, count: number) => (
    <div className="my-3 flex items-center gap-2.5 first:mt-[26px]">
      <span className="h-[15px] w-px shrink-0 rounded-full bg-accent" />
      <span className="whitespace-nowrap font-app-display text-small font-bold uppercase tracking-[0.08em] text-ink">
        {label}
      </span>
      <span className="rounded-full bg-tint px-[7px] py-0.5 font-code text-[11px] font-semibold text-faint">
        {count}
      </span>
      <span className="h-px flex-1 bg-hairline" />
    </div>
  );

  return (
    <>
      <Nav />
      <PageShell>
        <PageHeader>
          <PageTitle>{t("review.title")}</PageTitle>
          <PageSubtitle>{t("review.subtitle")}</PageSubtitle>
        </PageHeader>

        {reviewQuery.isLoading && <Meta>{tc("loading")}</Meta>}

        {empty && (
          <EmptyState>
            <p>{t("review.empty")}</p>
          </EmptyState>
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
      </PageShell>
      <MutationToast message={mutationToast.message} />
    </>
  );
}
