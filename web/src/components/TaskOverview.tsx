import { useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import type { ProjectBody, TaskBody } from "../api";
import {
  getGetTaskQueryKey,
  getListTasksQueryKey,
  useUpdateTask,
} from "../api";
import { STATUS_CYCLE } from "../constants/status";
import { useMutationToast } from "../hooks/use-mutation-toast";
import { apiClient } from "../lib/axios";
import { MutationToast } from "./mutation-toast";
import { ProjectDropdown } from "./ProjectDropdown";
import { TaskDateField } from "./TaskDateField";

const STATUS_CLASS: Record<string, string> = {
  todo: "st-todo",
  in_progress: "st-in_progress",
  done: "st-done",
  archived: "st-archived",
};

export function TaskOverview({
  task,
  projects,
}: {
  task: TaskBody;
  projects: ProjectBody[];
}): React.JSX.Element {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const mutationToast = useMutationToast();
  const [titleEditing, setTitleEditing] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const taskId = task.id;

  const invalidateTasks = () => {
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });
    queryClient.invalidateQueries({ queryKey: getGetTaskQueryKey(taskId) });
  };
  const update = useUpdateTask({
    mutation: {
      onMutate: async ({ id, data }) => {
        await queryClient.cancelQueries({ queryKey: getGetTaskQueryKey(id) });
        await queryClient.cancelQueries({ queryKey: getListTasksQueryKey() });
        const previousTask = queryClient.getQueryData<TaskBody>(
          getGetTaskQueryKey(id),
        );
        const previousLists = queryClient.getQueriesData<TaskBody[]>({
          queryKey: getListTasksQueryKey(),
        });
        const optimistic = { ...data } as Partial<TaskBody>;
        if ("clearStartAt" in data) optimistic.startAt = null;
        if ("clearDueAt" in data) optimistic.dueAt = null;
        queryClient.setQueryData<TaskBody>(getGetTaskQueryKey(id), (old) =>
          old ? { ...old, ...optimistic } : old,
        );
        queryClient.setQueriesData<TaskBody[]>(
          { queryKey: getListTasksQueryKey() },
          (old) =>
            old?.map((item) =>
              item.id === id ? { ...item, ...optimistic } : item,
            ),
        );
        return { previousTask, previousLists };
      },
      onError: (_error, { id }, context) => {
        queryClient.setQueryData(getGetTaskQueryKey(id), context?.previousTask);
        context?.previousLists.forEach(([key, value]) =>
          queryClient.setQueryData(key, value),
        );
        mutationToast.show(tc("errors.mutationFailed"));
      },
      onSettled: invalidateTasks,
    },
  });

  const saveTitle = () => {
    const title = titleDraft.trim();
    if (!title || title === task.title) {
      setTitleEditing(false);
      return;
    }
    update.mutate(
      { id: taskId, data: { title } },
      { onSuccess: () => setTitleEditing(false) },
    );
  };

  const uploadAttachment = async (
    event: React.ChangeEvent<HTMLInputElement>,
  ) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    setUploadError(false);
    setUploading(true);
    try {
      const form = new FormData();
      form.append("file", file, file.name);
      const response = await apiClient.post<{
        mediaUrl: string;
        mediaType: string;
      }>("/captures/upload", form);
      update.mutate({
        id: taskId,
        data: {
          mediaUrl: response.data.mediaUrl,
          mediaType: response.data.mediaType,
        },
      });
    } catch {
      setUploadError(true);
      window.setTimeout(() => setUploadError(false), 3000);
    } finally {
      setUploading(false);
    }
  };

  const isoFromDateInput = (value: string) => `${value}T00:00:00.000Z`;

  return (
    <>
      <div className="ch-task-title-row">
        <div className="ch-task-title-main">
          {titleEditing ? (
            <div className="ch-field-stack">
              <input
                autoFocus
                value={titleDraft}
                onChange={(event) => setTitleDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") saveTitle();
                  if (event.key === "Escape") setTitleEditing(false);
                }}
                className="ch-input ch-title"
              />
              <div className="ch-inline-actions">
                <button
                  className="ch-btn ch-btn-primary ch-btn-sm"
                  onClick={saveTitle}
                  disabled={update.isPending}
                >
                  {tc("actions.save")}
                </button>
                <button
                  className="ch-btn ch-btn-sm"
                  onClick={() => setTitleEditing(false)}
                >
                  {tc("actions.cancel")}
                </button>
              </div>
            </div>
          ) : (
            <h1
              className="ch-title ch-editable-title"
              data-done={task.status === "done"}
              onClick={() => {
                setTitleDraft(task.title);
                setTitleEditing(true);
              }}
              title={t("detail.clickToEdit")}
            >
              {task.title}
            </h1>
          )}
        </div>
        <button
          className={`ch-pill ch-status ${STATUS_CLASS[task.status] ?? "st-todo"}`}
          onClick={() =>
            update.mutate({
              id: taskId,
              data: { status: STATUS_CYCLE[task.status] ?? "todo" },
            })
          }
        >
          {tc(`status.${task.status}`)}
        </button>
      </div>

      <div className="ch-card ch-divide ch-task-meta-card">
        <div className="ch-task-meta-row">
          <span className="ch-task-meta-label">{t("filterProject")}</span>
          <ProjectDropdown
            value={task.projectId ?? null}
            projects={projects}
            onChange={(projectId) =>
              update.mutate({
                id: taskId,
                data: { projectId: projectId ?? undefined },
              })
            }
          />
        </div>
        <div className="ch-task-meta-row">
          <span className="ch-task-meta-label">{t("startDate")}</span>
          <TaskDateField
            label={t("startDate")}
            value={task.startAt}
            emptyLabel={t("setDate")}
            saveLabel={tc("actions.save")}
            cancelLabel={tc("actions.cancel")}
            clearLabel={tc("actions.clear")}
            onSave={(value) =>
              update.mutate({
                id: taskId,
                data: { startAt: isoFromDateInput(value) },
              })
            }
            onClear={() =>
              update.mutate({ id: taskId, data: { clearStartAt: true } })
            }
          />
        </div>
        <div className="ch-task-meta-row">
          <span className="ch-task-meta-label">{t("dueDate")}</span>
          <TaskDateField
            label={t("dueDate")}
            value={task.dueAt}
            emptyLabel={t("setDate")}
            saveLabel={tc("actions.save")}
            cancelLabel={tc("actions.cancel")}
            clearLabel={tc("actions.clear")}
            onSave={(value) =>
              update.mutate({
                id: taskId,
                data: { dueAt: isoFromDateInput(value) },
              })
            }
            onClear={() =>
              update.mutate({ id: taskId, data: { clearDueAt: true } })
            }
          />
        </div>
        <div className="ch-task-meta-row">
          <span className="ch-task-meta-label">
            {t("detail.uploadAttachment")}
          </span>
          <button
            className="ch-btn ch-btn-sm"
            onClick={() => fileInputRef.current?.click()}
            disabled={uploading}
          >
            {uploading ? "…" : t("detail.uploadAttachment")}
          </button>
          {uploadError && (
            <span className="ch-inline-error">{t("detail.uploadFailed")}</span>
          )}
          {task.mediaUrl && task.mediaType === "image" && (
            <a href={task.mediaUrl} target="_blank" rel="noopener noreferrer">
              <img
                src={task.mediaUrl}
                alt=""
                className="ch-task-attachment-preview"
              />
            </a>
          )}
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*,audio/*"
            className="ch-hidden-input"
            onChange={(event) => void uploadAttachment(event)}
          />
        </div>
      </div>
      <MutationToast message={mutationToast.message} />
    </>
  );
}
