import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  useCreateCapture,
  useCreateCaptureWithAttachment,
  useDeleteCapture,
  useListCapturePageInfinite,
  useRetryCaptureTranscription,
  useSetCaptureRemind,
  useUpdateCapture,
  type CaptureBody,
} from "@/api";
import {
  patchCaptureInPages,
  prependCaptureToPages,
  removeCaptureFromPages,
} from "@/utils/capture-cache";
import { CaptureComposer } from "@/components/CaptureComposer";
import { CapturesLayout } from "@/components/CapturesLayout";
import {
  CaptureFilterBar,
  type CaptureTab,
} from "@/components/CaptureFilterBar";
import { CaptureFeed } from "@/components/CaptureFeed";
import { MutationToast } from "@/components/mutation-toast";
import { Nav } from "@/components/nav";
import { useConfirm } from "@/hooks/use-confirm";
import { useMutationToast } from "@/hooks/use-mutation-toast";
import { useTodoEnabled } from "@/hooks/use-todo-enabled";
import type { CloudAttachmentDraft } from "@/lib/cloudDrive";
import {
  PageError,
  PageHeader,
  PageSubtitle,
  PageTitle,
} from "@/components/ui/page";

export const Route = createFileRoute("/captures")({ component: Captures });

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const { message: mutationMessage, show: showMutationToast } =
    useMutationToast();
  const todosEnabled = useTodoEnabled();
  const [tab, setTab] = useState<CaptureTab>("all");
  // Captures with a future reminder are filtered out of the list until they come
  // due; this opt-in surfaces them so the reminder can be edited or cleared.
  const [showScheduled, setShowScheduled] = useState(false);
  const tabs: CaptureTab[] = todosEnabled ? ["all", "todo"] : ["all"];
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
  const { mutate: updateCapture, mutateAsync: updateCaptureAsync } =
    useUpdateCapture({
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
  const createWithAttachment = useCreateCaptureWithAttachment({
    mutation: {
      onSuccess: (capture) => prependCaptureToPages(queryClient, capture),
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
    (id: string, rawText: string) =>
      updateCaptureAsync({ id, data: { rawText } }),
    [updateCaptureAsync],
  );
  const onSaveTranscript = useCallback(
    (id: string, transcript: string) =>
      updateCaptureAsync({ id, data: { transcript } }),
    [updateCaptureAsync],
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
    return <PageError>{t("failedToLoad")}</PageError>;
  }

  return (
    <>
      <Nav />
      <CapturesLayout
        header={
          <PageHeader>
            <PageTitle>{t("title")}</PageTitle>
            <PageSubtitle>{t("subtitle")}</PageSubtitle>
          </PageHeader>
        }
        composer={
          <CaptureComposer
            creating={create.isPending}
            onCreate={(rawText, onSuccess) =>
              create.mutate(
                { data: { rawText, mediaType: "text" } },
                { onSuccess },
              )
            }
            onCreateWithAttachment={async (
              operationId,
              rawText,
              attachment: CloudAttachmentDraft,
            ) => {
              await createWithAttachment.mutateAsync({
                data: {
                  operationId,
                  rawText,
                  source: "web",
                  attachment,
                },
              });
            }}
            onUploaded={invalidateCaptures}
          />
        }
        content={
          <>
            <CaptureFilterBar
              tabs={tabs}
              activeTab={tab}
              showScheduled={showScheduled}
              onTabChange={setTab}
              onToggleScheduled={() => setShowScheduled((value) => !value)}
            />
            <CaptureFeed
              captures={captures}
              loading={captureQuery.isLoading}
              hasMore={captureQuery.hasNextPage}
              loadingMore={captureQuery.isFetchingNextPage}
              masonry
              onLoadMore={() => void captureQuery.fetchNextPage()}
              onDelete={onDelete}
              onSaveText={onSaveText}
              onSaveTranscript={onSaveTranscript}
              onUseTranscript={onUseTranscript}
              onRetryTranscription={onRetryTranscription}
              onSetRemind={onSetRemind}
              onMutationError={onMutationError}
            />
          </>
        }
      />
      <MutationToast message={mutationMessage} />
    </>
  );
}
