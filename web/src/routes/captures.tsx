import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useCallback, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  useAddCaptureAttachment,
  useCreateCapture,
  useDeleteCapture,
  useListCapturePageInfinite,
  useRetryCaptureTranscription,
  useSetCaptureRemind,
  useUpdateCapture,
  type CaptureBody,
} from "../api";
import {
  appendAttachmentInPages,
  patchCaptureInPages,
  prependCaptureToPages,
  removeCaptureFromPages,
} from "../utils/capture-cache";
import { CaptureComposer } from "../components/CaptureComposer";
import { CaptureFeed } from "../components/CaptureFeed";
import { MutationToast } from "../components/mutation-toast";
import { Nav } from "../components/nav";
import { useConfirm } from "../components/confirm-dialog";
import { useMutationToast } from "../hooks/use-mutation-toast";
import { useTodoEnabled } from "../hooks/use-todo-enabled";
import type { CloudAttachmentDraft } from "../lib/cloudDrive";

export const Route = createFileRoute("/captures")({ component: Captures });

type Tab = "all" | "todo";

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const { message: mutationMessage, show: showMutationToast } =
    useMutationToast();
  const todosEnabled = useTodoEnabled();
  const [tab, setTab] = useState<Tab>("all");
  // Captures with a future reminder are filtered out of the list until they come
  // due; this opt-in surfaces them so the reminder can be edited or cleared.
  const [showScheduled, setShowScheduled] = useState(false);
  const tabs: Tab[] = todosEnabled ? ["all", "todo"] : ["all"];
  const params = {
    limit: 30,
    // The todo tab lists open todos; completed ones stay in "all" with a
    // done chip.
    ...(tab === "todo" && todosEnabled ? { todo: "open" } : {}),
    ...(showScheduled ? { includeReminded: true } : {}),
  };
  const captureQuery = useListCapturePageInfinite(params, {
    query: {
      initialPageParam: undefined,
      getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
    },
  });
  const captures =
    captureQuery.data?.pages.flatMap((page) => page.items ?? []) ?? [];

  const invalidateCaptures = () =>
    queryClient.invalidateQueries({
      queryKey: getListCapturePageInfiniteQueryKey(),
    });
  // Single-item mutations return the updated CaptureBody, so the cached pages
  // are patched in place instead of invalidated — invalidating an infinite
  // query refetches every loaded page serially. Only the multipart upload path
  // (no typed response) still does a full invalidate.
  const patchCapture = (capture: Parameters<typeof patchCaptureInPages>[1]) =>
    patchCaptureInPages(queryClient, capture);
  const create = useCreateCapture({
    mutation: {
      onSuccess: (capture) => prependCaptureToPages(queryClient, capture),
      onError: () => showMutationToast(tc("errors.mutationFailed")),
    },
  });
  const { mutate: updateCapture } = useUpdateCapture({
    mutation: {
      onSuccess: patchCapture,
      onError: () => showMutationToast(tc("errors.mutationFailed")),
    },
  });
  const { mutate: deleteCapture } = useDeleteCapture({
    mutation: {
      onSuccess: (_data, variables) =>
        removeCaptureFromPages(queryClient, variables.id),
      onError: () => showMutationToast(tc("errors.mutationFailed")),
    },
  });
  const { mutate: retryCaptureTranscription } = useRetryCaptureTranscription({
    mutation: {
      onSuccess: patchCapture,
      onError: () => {
        invalidateCaptures();
        showMutationToast(tc("errors.mutationFailed"));
      },
    },
  });
  const { mutate: setCaptureRemind } = useSetCaptureRemind({
    mutation: {
      onSuccess: patchCapture,
      onError: () => showMutationToast(tc("errors.mutationFailed")),
    },
  });
  const addAttachment = useAddCaptureAttachment({
    mutation: {
      onSuccess: (attachment, variables) =>
        appendAttachmentInPages(queryClient, variables.id, attachment),
      onError: () => showMutationToast(tc("errors.mutationFailed")),
    },
  });

  // Every feed callback is useCallback-stable (mutate/confirm/show are stable
  // references) so the memoized CaptureCard rows actually skip re-rendering —
  // and re-parsing their markdown — when a sibling item changes.
  const onDelete = useCallback(
    async (id: string) => {
      const confirmed = await confirm({
        title: tc("confirm.deleteCapture"),
        description: tc("confirm.cannotUndo"),
        confirmLabel: tc("actions.delete"),
        variant: "danger",
      });
      if (confirmed) deleteCapture({ id });
    },
    [confirm, deleteCapture, tc],
  );
  const onSaveText = useCallback(
    (id: string, rawText: string) => updateCapture({ id, data: { rawText } }),
    [updateCapture],
  );
  const onSaveTranscript = useCallback(
    (id: string, transcript: string) =>
      updateCapture({ id, data: { transcript } }),
    [updateCapture],
  );
  const onUseTranscript = useCallback(
    (capture: CaptureBody, mode: "append" | "replace") => {
      if (!capture.transcript) return;
      const rawText =
        mode === "append" && capture.rawText
          ? `${capture.rawText}\n\n${capture.transcript}`
          : capture.transcript;
      updateCapture({ id: capture.id, data: { rawText } });
    },
    [updateCapture],
  );
  const onRetryTranscription = useCallback(
    (id: string) => retryCaptureTranscription({ id }),
    [retryCaptureTranscription],
  );
  const onSetRemind = useCallback(
    (id: string, at: string | null, hide: boolean) =>
      setCaptureRemind({ id, data: { at: at ?? undefined, hide } }),
    [setCaptureRemind],
  );
  const onMutationError = useCallback(
    () => showMutationToast(tc("errors.mutationFailed")),
    [showMutationToast, tc],
  );

  if (captureQuery.error) {
    if (captureQuery.error.status === 401) {
      void navigate({ to: "/login" });
      return null;
    }
    return <div className="ch-page-error">{t("failedToLoad")}</div>;
  }

  return (
    <>
      <Nav />
      <main className="ch-page-shell">
        <header className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
          <p className="ch-page-subtitle">{t("subtitle")}</p>
        </header>
        <CaptureComposer
          creating={create.isPending}
          onCreate={(rawText, onSuccess) =>
            create.mutate(
              { data: { rawText, mediaType: "text" } },
              { onSuccess },
            )
          }
          onCreateAttachmentCapture={async (rawText) => {
            const capture = await create.mutateAsync({
              data: { rawText, mediaType: "text" },
            });
            return capture.id;
          }}
          onAttachCloudFile={async (
            captureId,
            attachment: CloudAttachmentDraft,
          ) => {
            await addAttachment.mutateAsync({
              id: captureId,
              data: attachment,
            });
          }}
          onUploaded={invalidateCaptures}
        />
        <div className="ch-filter-tabs">
          {tabs.map((id) => (
            <button
              key={id}
              className={`ch-navlink${tab === id ? " active" : ""}`}
              onClick={() => setTab(id)}
            >
              {t(`tabs.${id}`)}
            </button>
          ))}
          <button
            className={`ch-navlink${showScheduled ? " active" : ""}`}
            onClick={() => setShowScheduled((v) => !v)}
            title={t("scheduledHint")}
          >
            {t("showScheduled")}
          </button>
          <Link to="/trash" className="ch-navlink">
            {t("trash.link")}
          </Link>
        </div>
        <CaptureFeed
          captures={captures}
          loading={captureQuery.isLoading}
          hasMore={captureQuery.hasNextPage}
          loadingMore={captureQuery.isFetchingNextPage}
          onLoadMore={() => void captureQuery.fetchNextPage()}
          onDelete={onDelete}
          onSaveText={onSaveText}
          onSaveTranscript={onSaveTranscript}
          onUseTranscript={onUseTranscript}
          onRetryTranscription={onRetryTranscription}
          onSetRemind={onSetRemind}
          onMutationError={onMutationError}
        />
      </main>
      <MutationToast message={mutationMessage} />
    </>
  );
}
