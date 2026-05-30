import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  useListTasks,
  useCreateTask,
  useUpdateTask,
  useDeleteTask,
  getListTasksQueryKey,
  useListProjects,
} from "../api";
import type { TaskBody, TaskUpdateInputBodyStatus } from "../api";
import { Nav } from "../components/nav";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/tasks/")({
  component: Tasks,
});

function DueBadge({ dueAt, t }: { dueAt: string; t: (k: string) => string }) {
  const todayStr = new Date().toLocaleDateString("en-CA");
  const dueStr = new Date(dueAt).toLocaleDateString("en-CA");
  const overdue = dueStr < todayStr;
  const isToday = dueStr === todayStr;
  const label = overdue
    ? t("overdue")
    : isToday
      ? t("dueToday")
      : new Date(dueAt).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        });
  const cls = overdue
    ? "bg-red-100 text-red-700"
    : isToday
      ? "bg-amber-100 text-amber-700"
      : "bg-gray-100 text-gray-500";
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full flex-shrink-0 ${cls}`}>
      {label}
    </span>
  );
}

const STATUS_CYCLE: Record<string, TaskUpdateInputBodyStatus> = {
  todo: "in_progress",
  in_progress: "done",
  done: "todo",
};

const STATUS_COLORS: Record<string, string> = {
  todo: "bg-gray-100 text-gray-600",
  in_progress: "bg-blue-100 text-blue-700",
  done: "bg-green-100 text-green-700",
  archived: "bg-gray-100 text-gray-400",
};

function Tasks() {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [title, setTitle] = useState("");
  const [filterProjectId, setFilterProjectId] = useState("");
  const [newTaskProjectId, setNewTaskProjectId] = useState("");
  const [showArchived, setShowArchived] = useState(false);

  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter((p) => !p.archived);
  const projectMap = new Map(activeProjects.map((p) => [p.id, p]));

  const taskParams = filterProjectId
    ? { projectId: filterProjectId }
    : undefined;
  const { data: tasks, error, isLoading } = useListTasks(taskParams);

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const create = useCreateTask({ mutation: { onSuccess: invalidate } });
  const update = useUpdateTask({ mutation: { onSuccess: invalidate } });
  const del = useDeleteTask({ mutation: { onSuccess: invalidate } });

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("failedToLoad")}</div>;
  }

  const handleAdd = () => {
    const trimmed = title.trim();
    if (!trimmed) return;
    create.mutate(
      {
        data: {
          title: trimmed,
          type: "task",
          ...(newTaskProjectId ? { projectId: newTaskProjectId } : {}),
        },
      },
      { onSuccess: () => setTitle("") },
    );
  };

  const handleCycleStatus = (task: TaskBody) => {
    const next = STATUS_CYCLE[task.status] ?? "todo";
    update.mutate({ id: task.id, data: { status: next } });
  };

  const active = (tasks ?? []).filter(
    (task: TaskBody) => task.status !== "archived",
  );
  const archived = (tasks ?? []).filter(
    (task: TaskBody) => task.status === "archived",
  );

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>

        <div className="flex gap-2">
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                handleAdd();
              }
            }}
            placeholder={t("addPlaceholder")}
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          <select
            value={newTaskProjectId}
            onChange={(e) => setNewTaskProjectId(e.target.value)}
            className="border border-gray-300 rounded-md px-2 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          >
            <option value="">{tc("noProject")}</option>
            {activeProjects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
          <button
            onClick={handleAdd}
            disabled={create.isPending || !title.trim()}
            className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            {t("add")}
          </button>
        </div>

        <div className="flex items-center gap-2">
          <span className="text-sm text-gray-500">{t("filterProject")}</span>
          <select
            value={filterProjectId}
            onChange={(e) => setFilterProjectId(e.target.value)}
            className="border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          >
            <option value="">{t("allProjects")}</option>
            {activeProjects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </div>

        {isLoading ? (
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        ) : (
          <>
            <ul className="flex flex-col gap-2">
              {active.map((task: TaskBody) => (
                <li
                  key={task.id}
                  className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3"
                >
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      handleCycleStatus(task);
                    }}
                    className={`text-xs font-medium px-2 py-1 rounded-full whitespace-nowrap transition-colors hover:opacity-80 ${STATUS_COLORS[task.status] ?? "bg-gray-100 text-gray-600"}`}
                  >
                    {tc(`status.${task.status}`)}
                  </button>
                  {task.projectId && projectMap.get(task.projectId) && (
                    <Link
                      to="/projects/$projectId"
                      params={{ projectId: task.projectId }}
                      className="flex items-center gap-1.5 text-xs text-gray-400 hover:text-gray-600 transition-colors shrink-0"
                    >
                      <span
                        className="w-2 h-2 rounded-full"
                        style={{
                          backgroundColor: projectMap.get(task.projectId)!
                            .color,
                        }}
                      />
                      {projectMap.get(task.projectId)!.name}
                    </Link>
                  )}
                  <Link
                    to="/tasks/$taskId"
                    params={{ taskId: task.id }}
                    className={`flex-1 text-sm hover:underline ${task.status === "done" ? "line-through text-gray-400" : ""}`}
                  >
                    {task.title}
                  </Link>
                  {task.dueAt && task.status !== "done" && (
                    <DueBadge dueAt={task.dueAt} t={t} />
                  )}
                  <button
                    onClick={() =>
                      update.mutate({
                        id: task.id,
                        data: { status: "archived" },
                      })
                    }
                    className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
                  >
                    {tc("actions.archive")}
                  </button>
                  <button
                    onClick={() => del.mutate({ id: task.id })}
                    className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                  >
                    {tc("actions.delete")}
                  </button>
                </li>
              ))}
              {active.length === 0 && (
                <p className="text-gray-400 text-sm">{t("noTasks")}</p>
              )}
            </ul>

            {archived.length > 0 && (
              <div className="flex flex-col gap-2">
                <button
                  onClick={() => setShowArchived((v) => !v)}
                  className="text-xs text-gray-400 hover:text-gray-600 transition-colors self-start"
                >
                  {showArchived ? t("hideArchived") : t("showArchived")} (
                  {archived.length})
                </button>
                {showArchived && (
                  <ul className="flex flex-col gap-2">
                    {archived.map((task: TaskBody) => (
                      <li
                        key={task.id}
                        className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3 opacity-60"
                      >
                        <span className="flex-1 text-sm line-through text-gray-400">
                          {task.title}
                        </span>
                        <button
                          onClick={() =>
                            update.mutate({
                              id: task.id,
                              data: { status: "todo" },
                            })
                          }
                          className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
                        >
                          {t("unarchive")}
                        </button>
                        <button
                          onClick={() => del.mutate({ id: task.id })}
                          className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                        >
                          {tc("actions.delete")}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
