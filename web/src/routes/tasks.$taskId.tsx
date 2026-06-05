import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState, useRef } from "react";
import { apiClient } from "../lib/axios";
import { useQueryClient } from "@tanstack/react-query";
import { useConfirm } from "../components/confirm-dialog";
import {
  useGetTask,
  useUpdateTask,
  useListLogEntries,
  useCreateLogEntry,
  useUpdateLogEntry,
  useDeleteLogEntry,
  useListProjects,
  getListTasksQueryKey,
  getGetTaskQueryKey,
  getListLogEntriesQueryKey,
} from "../api";
import type { LogEntryBody, TaskBody } from "../api";
import { Nav } from "../components/nav";
import { Timer } from "../components/Timer";
import { ProjectDropdown } from "../components/ProjectDropdown";
import { Composer } from "../components/Composer";
import { Markdown } from "../components/Markdown";
import { STATUS_CYCLE } from "../constants/status";
import { timeAgo } from "../utils/format";
import { useTranslation } from "react-i18next";

const CalendarIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    style={{ flexShrink: 0 }}
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5"
    />
  </svg>
);

export const Route = createFileRoute("/tasks/$taskId")({
  component: TaskDetail,
});

const ST_CLASS: Record<string, string> = {
  todo: "st-todo",
  in_progress: "st-in_progress",
  done: "st-done",
  archived: "st-archived",
};

function TaskDetail() {
  const { t, i18n } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const { taskId } = Route.useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [body, setBody] = useState("");
  const [polishError, setPolishError] = useState(false);
  const [titleEditing, setTitleEditing] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const startDateInputRef = useRef<HTMLInputElement>(null);
  const dueDateInputRef = useRef<HTMLInputElement>(null);
  const [editingEntryId, setEditingEntryId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");

  const {
    data: task,
    error: taskError,
    isLoading: taskLoading,
  } = useGetTask(taskId);
  const { data: entries, isLoading: entriesLoading } = useListLogEntries({
    taskId,
  });
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter((p) => !p.archived);

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
            old == null
              ? old
              : old.map((t) => (t.id === id ? { ...t, ...optimistic } : t)),
        );
        return { previousTask, previousLists };
      },
      onError: (_err, { id }, context) => {
        queryClient.setQueryData(getGetTaskQueryKey(id), context?.previousTask);
        context?.previousLists.forEach(([key, val]) =>
          queryClient.setQueryData(key, val),
        );
      },
      onSettled: invalidateTasks,
    },
  });

  const invalidateEntries = () =>
    queryClient.invalidateQueries({
      queryKey: getListLogEntriesQueryKey({ taskId }),
    });

  const createEntry = useCreateLogEntry();
  const updateEntry = useUpdateLogEntry();
  const deleteEntry = useDeleteLogEntry();

  if (taskError) {
    const status = (taskError as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return (
      <div style={{ padding: 32, color: "#c2410c" }}>
        {t("detail.failedToLoad")}
      </div>
    );
  }

  const handleCycleStatus = () => {
    if (!task) return;
    const next = STATUS_CYCLE[task.status] ?? "todo";
    update.mutate({ id: task.id, data: { status: next } });
  };

  const handlePolish = async (value: string) => {
    const trimmed = value.trim();
    setPolishError(false);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", {
        text: trimmed,
      });
      return res.data.polished;
    } catch {
      setPolishError(true);
      setTimeout(() => setPolishError(false), 3000);
      throw new Error("polish failed");
    }
  };

  const handleAddEntry = (value = body) => {
    const trimmed = value.trim();
    if (!trimmed) return;
    createEntry.mutate(
      { data: { body: trimmed, taskId } },
      {
        onSuccess: () => {
          invalidateEntries();
          setBody("");
        },
      },
    );
  };

  const handleSaveTitle = () => {
    const trimmed = titleDraft.trim();
    if (!trimmed || !task || trimmed === task.title) {
      setTitleEditing(false);
      return;
    }
    update.mutate(
      { id: taskId, data: { title: trimmed } },
      { onSuccess: () => setTitleEditing(false) },
    );
  };

  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file || !task) return;
    e.target.value = "";
    setUploadError(false);
    setUploading(true);
    try {
      const fd = new FormData();
      fd.append("file", file, file.name);
      const res = await apiClient.post<{ mediaUrl: string; mediaType: string }>(
        "/captures/upload",
        fd,
      );
      await apiClient.patch(`/tasks/${taskId}`, {
        mediaUrl: res.data.mediaUrl,
        mediaType: res.data.mediaType,
      });
      invalidateTasks();
    } catch {
      setUploadError(true);
      setTimeout(() => setUploadError(false), 3000);
    } finally {
      setUploading(false);
    }
  };

  const displayDate = (value?: string | null) =>
    value
      ? new Date(value).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        })
      : "—";

  const isoFromDateInput = (value: string) =>
    new Date(`${value}T00:00:00`).toISOString();

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px 40px" }}>
        {/* Back */}
        <div style={{ paddingTop: 20, paddingBottom: 14 }}>
          <Link
            to="/tasks"
            className="ch-btn ch-btn-ghost ch-btn-sm"
            style={{ textDecoration: "none", marginLeft: -8 }}
          >
            ← {t("title")}
          </Link>
        </div>

        {taskLoading ? (
          <p className="ch-meta">{tc("loading")}</p>
        ) : task ? (
          <>
            {/* Title + status */}
            <div
              style={{
                display: "flex",
                alignItems: "flex-start",
                gap: 14,
                marginBottom: 18,
              }}
            >
              <div style={{ flex: 1, minWidth: 0 }}>
                {titleEditing ? (
                  <div
                    style={{ display: "flex", flexDirection: "column", gap: 8 }}
                  >
                    <input
                      autoFocus
                      value={titleDraft}
                      onChange={(e) => setTitleDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") handleSaveTitle();
                        if (e.key === "Escape") setTitleEditing(false);
                      }}
                      className="ch-input ch-title"
                      style={{ fontSize: "var(--fs-title)" }}
                    />
                    <div style={{ display: "flex", gap: 8 }}>
                      <button
                        className="ch-btn ch-btn-primary ch-btn-sm"
                        onClick={handleSaveTitle}
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
                    className="ch-title"
                    onClick={() => {
                      setTitleDraft(task.title);
                      setTitleEditing(true);
                    }}
                    style={{
                      cursor: "text",
                      opacity: task.status === "done" ? 0.5 : 1,
                    }}
                    title={t("detail.clickToEdit")}
                  >
                    {task.title}
                  </h1>
                )}
              </div>
              <button
                className={`ch-pill ch-status ${ST_CLASS[task.status] ?? "st-todo"}`}
                onClick={handleCycleStatus}
                style={{ marginTop: 4, flexShrink: 0 }}
              >
                {tc(`status.${task.status}`)}
              </button>
            </div>

            {/* Meta card */}
            <div
              className="ch-card ch-divide"
              style={{ padding: "0 var(--pad)", marginBottom: 8 }}
            >
              {/* Project */}
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "12px 0",
                }}
              >
                <span
                  style={{
                    width: 78,
                    fontSize: "var(--fs-sm)",
                    color: "var(--text-muted)",
                    flexShrink: 0,
                  }}
                >
                  {t("filterProject")}
                </span>
                <ProjectDropdown
                  value={task.projectId ?? null}
                  projects={activeProjects}
                  onChange={(id) =>
                    update.mutate({
                      id: taskId,
                      data: { projectId: id ?? undefined },
                    })
                  }
                />
              </div>
              {/* Start date */}
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "12px 0",
                }}
              >
                <span
                  style={{
                    width: 78,
                    fontSize: "var(--fs-sm)",
                    color: "var(--text-muted)",
                    flexShrink: 0,
                  }}
                >
                  {t("startDate")}
                </span>
                <button
                  className={`ch-datebtn${task.startAt ? "" : " empty"}`}
                  onClick={() => startDateInputRef.current?.click()}
                >
                  <CalendarIcon />
                  {displayDate(task.startAt)}
                </button>
                {task.startAt && (
                  <button
                    className="ch-btn ch-btn-ghost ch-btn-sm"
                    onClick={() =>
                      update.mutate({
                        id: taskId,
                        data: { clearStartAt: true },
                      })
                    }
                  >
                    {tc("actions.clear")}
                  </button>
                )}
                <input
                  ref={startDateInputRef}
                  type="date"
                  style={{ display: "none" }}
                  value={task.startAt ? task.startAt.slice(0, 10) : ""}
                  onChange={(e) => {
                    const val = e.target.value;
                    if (!val) return;
                    update.mutate({
                      id: taskId,
                      data: { startAt: isoFromDateInput(val) },
                    });
                  }}
                />
              </div>
              {/* Due date */}
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "12px 0",
                }}
              >
                <span
                  style={{
                    width: 78,
                    fontSize: "var(--fs-sm)",
                    color: "var(--text-muted)",
                    flexShrink: 0,
                  }}
                >
                  {t("dueDate")}
                </span>
                <button
                  className={`ch-datebtn${task.dueAt ? "" : " empty"}`}
                  onClick={() => dueDateInputRef.current?.click()}
                >
                  <CalendarIcon />
                  {displayDate(task.dueAt)}
                </button>
                {task.dueAt && (
                  <button
                    className="ch-btn ch-btn-ghost ch-btn-sm"
                    onClick={() =>
                      update.mutate({
                        id: taskId,
                        data: { clearDueAt: true },
                      })
                    }
                  >
                    {tc("actions.clear")}
                  </button>
                )}
                <input
                  ref={dueDateInputRef}
                  type="date"
                  style={{ display: "none" }}
                  value={task.dueAt ? task.dueAt.slice(0, 10) : ""}
                  onChange={(e) => {
                    const val = e.target.value;
                    if (!val) return;
                    update.mutate({
                      id: taskId,
                      data: { dueAt: isoFromDateInput(val) },
                    });
                  }}
                />
              </div>
              {/* Files */}
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "12px 0",
                }}
              >
                <span
                  style={{
                    width: 78,
                    fontSize: "var(--fs-sm)",
                    color: "var(--text-muted)",
                    flexShrink: 0,
                  }}
                >
                  {t("detail.uploadAttachment") ?? "Files"}
                </span>
                <button
                  className="ch-btn ch-btn-sm"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={uploading}
                >
                  {uploading ? "…" : "📎"}{" "}
                  {t("detail.uploadAttachment") ?? "Attach"}
                </button>
                {uploadError && (
                  <span style={{ fontSize: "var(--fs-xs)", color: "#c2410c" }}>
                    {t("detail.uploadFailed")}
                  </span>
                )}
                {task.mediaUrl && task.mediaType === "image" && (
                  <a
                    href={task.mediaUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <img
                      src={task.mediaUrl}
                      alt="attachment"
                      style={{
                        maxHeight: 40,
                        borderRadius: "var(--radius-sm)",
                        border: "1px solid var(--border)",
                      }}
                    />
                  </a>
                )}
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="image/*,audio/*"
                  style={{ display: "none" }}
                  onChange={handleFileUpload}
                />
              </div>
            </div>

            {/* Time section */}
            <div className="ch-section">
              <span className="bar" />
              <span className="ch-sectlabel">{t("time.title") ?? "Time"}</span>
              <span className="rule" />
            </div>
            <div className="ch-card" style={{ padding: "var(--pad)" }}>
              <Timer taskId={taskId} />
            </div>

            {/* Log section */}
            <div className="ch-section">
              <span className="bar" />
              <span className="ch-sectlabel">{t("log.title")}</span>
              <span className="ch-sectcount">{(entries ?? []).length}</span>
              <span className="rule" />
            </div>

            {/* Log composer */}
            <Composer
              value={body}
              onChange={setBody}
              onSubmit={handleAddEntry}
              placeholder={t("log.placeholder")}
              submitLabel={t("log.addNote")}
              submitDisabled={createEntry.isPending}
              onPolish={handlePolish}
              error={polishError ? tc("errors.polishFailed") : null}
              minRows={2}
            />

            {/* Log entries */}
            {entriesLoading ? (
              <p className="ch-meta">{tc("loading")}</p>
            ) : (
              <div className="ch-list">
                {(entries ?? []).length === 0 ? (
                  <div className="ch-empty">
                    <p>{t("log.noNotes")}</p>
                  </div>
                ) : (
                  (entries ?? []).map((e: LogEntryBody) => (
                    <div key={e.id} className="ch-row">
                      {editingEntryId === e.id ? (
                        <>
                          <textarea
                            autoFocus
                            value={editDraft}
                            onChange={(ev) => setEditDraft(ev.target.value)}
                            onKeyDown={(ev) => {
                              if (ev.key === "Escape") setEditingEntryId(null);
                            }}
                            rows={3}
                            className="ch-textarea"
                            style={{ marginBottom: 10 }}
                          />
                          <div
                            style={{
                              display: "flex",
                              gap: 8,
                              justifyContent: "flex-end",
                            }}
                          >
                            <button
                              className="ch-btn ch-btn-primary ch-btn-sm"
                              onClick={() => {
                                const trimmed = editDraft.trim();
                                if (!trimmed) return;
                                updateEntry.mutate(
                                  { id: e.id, data: { body: trimmed } },
                                  {
                                    onSuccess: () => {
                                      invalidateEntries();
                                      setEditingEntryId(null);
                                    },
                                  },
                                );
                              }}
                              disabled={updateEntry.isPending}
                            >
                              {tc("actions.save")}
                            </button>
                            <button
                              className="ch-btn ch-btn-sm"
                              onClick={() => setEditingEntryId(null)}
                            >
                              {tc("actions.cancel")}
                            </button>
                          </div>
                        </>
                      ) : (
                        <>
                          <div
                            style={{ cursor: "text", marginBottom: 10 }}
                            onClick={() => {
                              setEditingEntryId(e.id);
                              setEditDraft(e.body);
                            }}
                          >
                            <Markdown>{e.body}</Markdown>
                          </div>
                          <div
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: 10,
                            }}
                          >
                            <span className="ch-meta">
                              {timeAgo(e.createdAt, i18n.language)}
                            </span>
                            <div style={{ flex: 1 }} />
                            <button
                              className="ch-btn ch-btn-ghost ch-btn-sm"
                              onClick={() => {
                                setEditingEntryId(e.id);
                                setEditDraft(e.body);
                              }}
                            >
                              {tc("actions.edit") ?? "Edit"}
                            </button>
                            <button
                              className="ch-btn ch-btn-danger ch-btn-sm"
                              onClick={async () => {
                                const ok = await confirm({
                                  title: tc("confirm.deleteLogEntry"),
                                  description: tc("confirm.cannotUndo"),
                                  confirmLabel: tc("actions.delete"),
                                  variant: "danger",
                                });
                                if (ok)
                                  deleteEntry.mutate(
                                    { id: e.id },
                                    { onSuccess: invalidateEntries },
                                  );
                              }}
                            >
                              {tc("actions.delete")}
                            </button>
                          </div>
                        </>
                      )}
                    </div>
                  ))
                )}
              </div>
            )}
          </>
        ) : null}
      </div>
    </>
  );
}
