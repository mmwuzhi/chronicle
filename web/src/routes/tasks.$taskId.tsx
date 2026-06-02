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
import { STATUS_CYCLE, STATUS_COLORS } from "../constants/status";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/tasks/$taskId")({
  component: TaskDetail,
});

function TaskDetail() {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const { taskId } = Route.useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [body, setBody] = useState("");
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);
  const [titleEditing, setTitleEditing] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [polishingTitle, setPolishingTitle] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
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
  const currentProject = task?.projectId
    ? activeProjects.find((p) => p.id === task.projectId)
    : null;

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
        queryClient.setQueryData<TaskBody>(getGetTaskQueryKey(id), (old) =>
          old ? { ...old, ...data } : old,
        );
        queryClient.setQueriesData<TaskBody[]>(
          { queryKey: getListTasksQueryKey() },
          (old) =>
            old == null
              ? old
              : old.map((t) => (t.id === id ? { ...t, ...data } : t)),
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
    return <div className="p-8 text-red-500">{t("detail.failedToLoad")}</div>;
  }

  const handleCycleStatus = () => {
    if (!task) return;
    const next = STATUS_CYCLE[task.status] ?? "todo";
    update.mutate({ id: task.id, data: { status: next } });
  };

  const handlePolish = async () => {
    const trimmed = body.trim();
    if (!trimmed) return;
    setPolishError(false);
    setPolishing(true);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", {
        text: trimmed,
      });
      setBody(res.data.polished);
    } catch {
      setPolishError(true);
      setTimeout(() => setPolishError(false), 3000);
    } finally {
      setPolishing(false);
    }
  };

  const handleAddEntry = () => {
    const trimmed = body.trim();
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

  const handleStartTitleEdit = () => {
    setTitleDraft(task?.title ?? "");
    setTitleEditing(true);
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

  const handlePolishTitle = async () => {
    const trimmed = titleDraft.trim();
    if (!trimmed) return;
    setPolishingTitle(true);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", {
        text: trimmed,
      });
      setTitleDraft(res.data.polished);
    } catch {
      // silently ignore, title stays as-is
    } finally {
      setPolishingTitle(false);
    }
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

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <div className="flex items-center gap-2 text-sm text-gray-400">
          <Link to="/tasks" className="hover:text-gray-600 transition-colors">
            {t("title")}
          </Link>
          <span>/</span>
          <span className="text-gray-600">{t("detail.breadcrumb")}</span>
        </div>

        {taskLoading ? (
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        ) : task ? (
          <>
            <div className="flex items-start gap-3">
              {titleEditing ? (
                <div className="flex-1 flex flex-col gap-2">
                  <div className="flex items-center gap-2">
                    <input
                      autoFocus
                      value={titleDraft}
                      onChange={(e) => setTitleDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") handleSaveTitle();
                        if (e.key === "Escape") setTitleEditing(false);
                      }}
                      className="flex-1 text-2xl font-semibold border-b-2 border-gray-900 focus:outline-none bg-transparent"
                    />
                    <button
                      onClick={handlePolishTitle}
                      disabled={polishingTitle || !titleDraft.trim()}
                      className="text-sm border border-gray-300 rounded-md px-2 py-1 hover:bg-gray-50 transition-colors disabled:opacity-50"
                      title={tc("actions.polish")}
                    >
                      {polishingTitle ? "…" : "✨"}
                    </button>
                  </div>
                  <div className="flex gap-2">
                    <button
                      onClick={handleSaveTitle}
                      disabled={update.isPending}
                      className="text-sm bg-gray-900 text-white rounded-md px-3 py-1 hover:bg-gray-700 transition-colors disabled:opacity-50"
                    >
                      {tc("actions.save")}
                    </button>
                    <button
                      onClick={() => setTitleEditing(false)}
                      className="text-sm border border-gray-300 rounded-md px-3 py-1 hover:bg-gray-50 transition-colors"
                    >
                      {tc("actions.cancel")}
                    </button>
                  </div>
                </div>
              ) : (
                <h1
                  onClick={handleStartTitleEdit}
                  className={`text-2xl font-semibold tracking-tight flex-1 cursor-pointer hover:opacity-70 transition-opacity ${task.status === "done" ? "line-through text-gray-400" : ""}`}
                  title={t("detail.clickToEdit")}
                >
                  {task.title}
                </h1>
              )}
              <button
                onClick={handleCycleStatus}
                className={`text-xs font-medium px-3 py-1.5 rounded-full whitespace-nowrap transition-colors hover:opacity-80 mt-1 ${STATUS_COLORS[task.status] ?? "bg-gray-100 text-gray-600"}`}
              >
                {tc(`status.${task.status}`)}
              </button>
            </div>

            <div className="flex items-center gap-3">
              <span className="text-sm text-gray-500">
                {t("filterProject")}
              </span>
              {currentProject && (
                <Link
                  to="/projects/$projectId"
                  params={{ projectId: currentProject.id }}
                  className="flex items-center gap-1.5 text-sm text-gray-700 hover:text-gray-900 transition-colors"
                >
                  <span
                    className="w-2.5 h-2.5 rounded-full"
                    style={{ backgroundColor: currentProject.color }}
                  />
                  <span className="font-medium">{currentProject.name}</span>
                </Link>
              )}
              <select
                value={task.projectId ?? ""}
                onChange={(e) => {
                  const val = e.target.value;
                  update.mutate({
                    id: taskId,
                    data: { projectId: val || undefined },
                  });
                }}
                className="border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
              >
                <option value="">{tc("noProject")}</option>
                {activeProjects.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </div>

            <div className="flex items-center gap-3">
              <span className="text-sm text-gray-500">{t("dueDate")}</span>
              <input
                type="date"
                value={task.dueAt ? task.dueAt.slice(0, 10) : ""}
                onChange={(e) => {
                  const val = e.target.value;
                  if (!val) return;
                  update.mutate({
                    id: taskId,
                    data: { dueAt: new Date(val + "T00:00:00").toISOString() },
                  });
                }}
                className="border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
              />
            </div>

            <div className="flex items-center gap-3">
              <button
                onClick={() => fileInputRef.current?.click()}
                disabled={uploading}
                className="border border-gray-300 rounded-md px-3 py-1.5 text-sm font-medium hover:bg-gray-50 transition-colors disabled:opacity-50"
                title={t("detail.uploadAttachment")}
              >
                {uploading ? "…" : "📎"}
              </button>
              {uploadError && (
                <span className="text-xs text-red-500">
                  {t("detail.uploadFailed")}
                </span>
              )}
              {task.mediaUrl && (
                task.mediaType === "image" ? (
                  <a
                    href={task.mediaUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="block"
                  >
                    <img
                      src={task.mediaUrl}
                      alt="attachment"
                      className="max-h-48 rounded-lg border border-gray-200 object-contain"
                    />
                  </a>
                ) : (
                  <a
                    href={task.mediaUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-sm text-blue-600 hover:underline"
                  >
                    {t("detail.viewAttachment")}
                  </a>
                )
              )}
              <input
                ref={fileInputRef}
                type="file"
                accept="image/*,audio/*"
                className="hidden"
                onChange={handleFileUpload}
              />
            </div>

            <Timer taskId={taskId} />

            <section className="flex flex-col gap-4">
              <h2 className="text-sm font-medium text-gray-500 uppercase tracking-wide">
                {t("log.title")}
              </h2>

              <div className="flex flex-col gap-2">
                <textarea
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      handleAddEntry();
                    }
                  }}
                  placeholder={t("log.placeholder")}
                  rows={2}
                  className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none"
                />
                <div className="flex flex-col gap-1 items-end">
                  <div className="flex gap-2">
                    <button
                      onClick={handlePolish}
                      disabled={polishing || !body.trim()}
                      className="border border-gray-300 rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-50 transition-colors disabled:opacity-50"
                      title={tc("actions.polish")}
                    >
                      {polishing ? "…" : "✨"}
                    </button>
                    <button
                      onClick={handleAddEntry}
                      disabled={createEntry.isPending || !body.trim()}
                      className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
                    >
                      {t("log.addNote")}
                    </button>
                  </div>
                  {polishError && (
                    <p className="text-xs text-red-500">
                      {tc("errors.polishFailed")}
                    </p>
                  )}
                </div>
              </div>

              {entriesLoading ? (
                <div className="text-gray-400 text-sm">{tc("loading")}</div>
              ) : (
                <ul className="flex flex-col gap-2">
                  {(entries ?? []).map((e: LogEntryBody) => (
                    <li
                      key={e.id}
                      className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex flex-col gap-2"
                    >
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
                            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none w-full"
                          />
                          <div className="flex gap-2 justify-end">
                            <button
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
                              className="text-xs bg-gray-900 text-white rounded-md px-3 py-1.5 hover:bg-gray-700 transition-colors disabled:opacity-50"
                            >
                              {tc("actions.save")}
                            </button>
                            <button
                              onClick={() => setEditingEntryId(null)}
                              className="text-xs border border-gray-300 rounded-md px-3 py-1.5 hover:bg-gray-50 transition-colors"
                            >
                              {tc("actions.cancel")}
                            </button>
                          </div>
                        </>
                      ) : (
                        <>
                          <p
                            className="text-sm whitespace-pre-wrap cursor-pointer hover:opacity-70 transition-opacity"
                            onClick={() => {
                              setEditingEntryId(e.id);
                              setEditDraft(e.body);
                            }}
                          >
                            {e.body}
                          </p>
                          <div className="flex items-center gap-2">
                            <span className="text-xs text-gray-400">
                              {new Date(e.createdAt).toLocaleString()}
                            </span>
                            <span className="flex-1" />
                            <button
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
                              className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                            >
                              {tc("actions.delete")}
                            </button>
                          </div>
                        </>
                      )}
                    </li>
                  ))}
                  {(entries ?? []).length === 0 && (
                    <p className="text-gray-400 text-sm">{t("log.noNotes")}</p>
                  )}
                </ul>
              )}
            </section>
          </>
        ) : null}
      </div>
    </div>
  );
}
