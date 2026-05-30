import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { apiClient } from "../lib/axios";
import { useQueryClient } from "@tanstack/react-query";
import {
  useGetTask,
  useUpdateTask,
  useListLogEntries,
  useCreateLogEntry,
  useDeleteLogEntry,
  useListProjects,
  getListTasksQueryKey,
  getGetTaskQueryKey,
} from "../api";
import type { LogEntryBody } from "../api";
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
  const [body, setBody] = useState("");
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);

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

  const update = useUpdateTask({ mutation: { onSuccess: invalidateTasks } });
  const createEntry = useCreateLogEntry();
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
      { onSuccess: () => setBody("") },
    );
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
              <h1
                className={`text-2xl font-semibold tracking-tight flex-1 ${task.status === "done" ? "line-through text-gray-400" : ""}`}
              >
                {task.title}
              </h1>
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
                      <p className="text-sm whitespace-pre-wrap">{e.body}</p>
                      <div className="flex items-center gap-2">
                        <span className="text-xs text-gray-400">
                          {new Date(e.createdAt).toLocaleString()}
                        </span>
                        <span className="flex-1" />
                        <button
                          onClick={() => deleteEntry.mutate({ id: e.id })}
                          className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                        >
                          {tc("actions.delete")}
                        </button>
                      </div>
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
