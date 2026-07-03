import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  getListCaptureAttachmentsQueryKey,
  useAddCaptureAttachment,
  useCreateCapture,
  useDeleteCapture,
  useListCapturePageInfinite,
  useRetryCaptureTranscription,
  useSetCaptureRemind,
  useSetCaptureTodo,
  useUpdateCapture,
} from "../api";
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
  const mutationToast = useMutationToast();
  const todosEnabled = useTodoEnabled();
  const [tab, setTab] = useState<Tab>("all");
  // Captures with a future reminder are filtered out of the list until they come
  // due; this opt-in surfaces them so the reminder can be edited or cleared.
  const [showScheduled, setShowScheduled] = useState(false);
  const tabs: Tab[] = todosEnabled ? ["all", "todo"] : ["all"];
  const params = {
    limit: 30,
    // The todo tab lists open todos; completed ones stay in "all" with a
    // checked box.
    ...(tab === "todo" && todosEnabled ? { todo: "open" } : {}),
    ...(showScheduled ? { includeReminded: true } : {}),
  };
  const captureQuery = useListCapturePageInfinite(params, {
    query: {
      initialPageParam: undefined,
      getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
      refetchInterval: (query) => {
        const data = query.state.data;
        const hasPending = data?.pages.some((page) =>
          (page.items ?? []).some((capture) =>
            ["pending", "processing"].includes(capture.transcriptionStatus),
          ),
        );
        return hasPending ? 3000 : false;
      },
    },
  });
  const captures =
    captureQuery.data?.pages.flatMap((page) => page.items ?? []) ?? [];

  const invalidateCaptures = () =>
    queryClient.invalidateQueries({
      queryKey: getListCapturePageInfiniteQueryKey(),
    });
  const create = useCreateCapture({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const update = useUpdateCapture({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const remove = useDeleteCapture({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const retryTranscription = useRetryCaptureTranscription({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => {
        invalidateCaptures();
        mutationToast.show(tc("errors.mutationFailed"));
      },
    },
  });
  const setRemind = useSetCaptureRemind({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const setTodo = useSetCaptureTodo({
    mutation: {
      onSuccess: invalidateCaptures,
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const addAttachment = useAddCaptureAttachment({
    mutation: {
      onSuccess: (_attachment, variables) => {
        queryClient.invalidateQueries({
          queryKey: getListCaptureAttachmentsQueryKey(variables.id),
        });
      },
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
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
          onSetTodo={(id, state) => setTodo.mutate({ id, data: { state } })}
          onDelete={async (id) => {
            const confirmed = await confirm({
              title: tc("confirm.deleteCapture"),
              description: tc("confirm.cannotUndo"),
              confirmLabel: tc("actions.delete"),
              variant: "danger",
            });
            if (confirmed) remove.mutate({ id });
          }}
          onSaveText={(id, rawText) => update.mutate({ id, data: { rawText } })}
          onSaveTranscript={(id, transcript) =>
            update.mutate({ id, data: { transcript } })
          }
          onUseTranscript={(id, mode) => {
            const capture = captures.find((item) => item.id === id);
            if (!capture?.transcript) return;
            const rawText =
              mode === "append" && capture.rawText
                ? `${capture.rawText}\n\n${capture.transcript}`
                : capture.transcript;
            update.mutate({ id, data: { rawText } });
          }}
          onRetryTranscription={(id) => retryTranscription.mutate({ id })}
          onSetRemind={(id, at, hide) =>
            setRemind.mutate({ id, data: { at: at ?? undefined, hide } })
          }
          onMutationError={() =>
            mutationToast.show(tc("errors.mutationFailed"))
          }
        />
      </main>
      <MutationToast message={mutationToast.message} />
    </>
  );
}
