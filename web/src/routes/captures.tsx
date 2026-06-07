import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCapturePageInfiniteQueryKey,
  getListTasksQueryKey,
  useCreateCapture,
  useCreateLogEntry,
  useCreateTask,
  useDeleteCapture,
  useListCapturePageInfinite,
  useListProjects,
  useRetryCaptureTranscription,
  useUpdateCapture,
} from "../api";
import { CaptureComposer } from "../components/CaptureComposer";
import { CaptureFeed } from "../components/CaptureFeed";
import { MutationToast } from "../components/mutation-toast";
import { Nav } from "../components/nav";
import { PromoteCaptureDialog } from "../components/PromoteCaptureDialog";
import { useConfirm } from "../components/confirm-dialog";
import { useMutationToast } from "../hooks/use-mutation-toast";

export const Route = createFileRoute("/captures")({ component: Captures });

type Tab = "all" | "unclassified" | "idea" | "task" | "routine" | "log";
const TABS: Tab[] = ["all", "unclassified", "idea", "task", "routine", "log"];

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const mutationToast = useMutationToast();
  const [tab, setTab] = useState<Tab>("all");
  const [pendingPromote, setPendingPromote] = useState<{
    rawText: string;
    captureId: string;
  } | null>(null);
  const [promoteProjectId, setPromoteProjectId] = useState("");
  const params = {
    limit: 30,
    ...(tab === "all" ? {} : { classifiedAs: tab }),
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
  const createTask = useCreateTask({
    mutation: {
      onSuccess: () =>
        queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() }),
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const createLogEntry = useCreateLogEntry({
    mutation: {
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter(
    (project) => !project.archived,
  );

  if (captureQuery.error) {
    if (captureQuery.error.status === 401) {
      void navigate({ to: "/login" });
      return null;
    }
    return <div className="ch-page-error">{t("failedToLoad")}</div>;
  }

  const confirmPromote = () => {
    if (!pendingPromote) return;
    const [firstLine, ...rest] = pendingPromote.rawText.split("\n");
    createTask.mutate(
      {
        data: {
          title: firstLine.trim(),
          type: "task",
          ...(promoteProjectId ? { projectId: promoteProjectId } : {}),
        },
      },
      {
        onSuccess: (task) => {
          const body = rest.join("\n").trim();
          if (body) {
            createLogEntry.mutate({ data: { taskId: task.id, body } });
          }
          remove.mutate({ id: pendingPromote.captureId });
          setPendingPromote(null);
        },
      },
    );
  };

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
              {
                data: {
                  rawText,
                  mediaType: "text",
                  classifiedAs: "unclassified",
                },
              },
              { onSuccess },
            )
          }
          onUploaded={invalidateCaptures}
        />
        <div className="ch-filter-tabs">
          {TABS.map((id) => (
            <button
              key={id}
              className={`ch-navlink${tab === id ? " active" : ""}`}
              onClick={() => setTab(id)}
            >
              {t(`tabs.${id}`)}
            </button>
          ))}
        </div>
        <CaptureFeed
          captures={captures}
          loading={captureQuery.isLoading}
          hasMore={captureQuery.hasNextPage}
          loadingMore={captureQuery.isFetchingNextPage}
          onLoadMore={() => void captureQuery.fetchNextPage()}
          onReclassify={(id, classifiedAs) =>
            update.mutate({ id, data: { classifiedAs } })
          }
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
          onPromoteToTask={(rawText, captureId) => {
            setPendingPromote({ rawText, captureId });
            setPromoteProjectId("");
          }}
        />
      </main>
      {pendingPromote && (
        <PromoteCaptureDialog
          rawText={pendingPromote.rawText}
          projects={activeProjects}
          projectId={promoteProjectId}
          pending={createTask.isPending}
          onProjectChange={setPromoteProjectId}
          onCancel={() => setPendingPromote(null)}
          onConfirm={confirmPromote}
        />
      )}
      <MutationToast message={mutationToast.message} />
    </>
  );
}
