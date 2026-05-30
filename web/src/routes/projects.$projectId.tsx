import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useConfirm } from "../components/confirm-dialog";
import {
  useListProjects,
  useUpdateProject,
  useDeleteProject,
  getListProjectsQueryKey,
  useListTasks,
  useCreateTask,
  useUpdateTask,
  useDeleteTask,
  getListTasksQueryKey,
  useListTimeBlocks,
} from "../api";
import type { TaskBody } from "../api";
import { Nav } from "../components/nav";
import { STATUS_CYCLE, STATUS_COLORS } from "../constants/status";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/projects/$projectId")({
  component: ProjectDetail,
});

function ProjectDetail() {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const { projectId } = Route.useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [title, setTitle] = useState("");
  const [editing, setEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editColor, setEditColor] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const confirm = useConfirm();

  const {
    data: projects,
    isLoading: projectsLoading,
    error: projectsError,
  } = useListProjects();
  const project = projects?.find((p) => p.id === projectId);

  const { data: tasks, isLoading: tasksLoading } = useListTasks({ projectId });
  const { data: timeBlocks } = useListTimeBlocks();

  const invalidateProjects = () =>
    queryClient.invalidateQueries({ queryKey: getListProjectsQueryKey() });
  const invalidateTasks = () =>
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const updateProject = useUpdateProject({
    mutation: { onSuccess: invalidateProjects },
  });
  const deleteProject = useDeleteProject({
    mutation: {
      onSuccess: () => {
        invalidateProjects();
        navigate({ to: "/projects" });
      },
    },
  });
  const createTask = useCreateTask({
    mutation: { onSuccess: invalidateTasks },
  });
  const updateTask = useUpdateTask({
    mutation: { onSuccess: invalidateTasks },
  });
  const deleteTask = useDeleteTask({
    mutation: { onSuccess: invalidateTasks },
  });

  if (projectsError) {
    const status = (projectsError as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("detail.failedToLoad")}</div>;
  }

  if (projectsLoading) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8">
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        </div>
      </div>
    );
  }

  if (!project) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-4">
          <p className="text-gray-500 text-sm">{t("detail.notFound")}</p>
          <Link
            to="/projects"
            className="text-sm text-gray-900 font-medium hover:underline"
          >
            {t("detail.backToProjects")}
          </Link>
        </div>
      </div>
    );
  }

  const handleAddTask = () => {
    const trimmed = title.trim();
    if (!trimmed) return;
    createTask.mutate(
      { data: { title: trimmed, type: "task", projectId } },
      { onSuccess: () => setTitle("") },
    );
  };

  const handleCycleStatus = (task: TaskBody) => {
    const next = STATUS_CYCLE[task.status] ?? "todo";
    updateTask.mutate({ id: task.id, data: { status: next } });
  };

  const handleSaveEdit = () => {
    updateProject.mutate({
      id: projectId,
      data: { name: editName, color: editColor },
    });
    setEditing(false);
  };

  const startEdit = () => {
    setEditName(project.name);
    setEditColor(project.color);
    setEditing(true);
  };

  const active = (tasks ?? []).filter(
    (task: TaskBody) => task.status !== "archived",
  );
  const archivedTasks = (tasks ?? []).filter(
    (task: TaskBody) => task.status === "archived",
  );

  const taskIds = new Set((tasks ?? []).map((t: TaskBody) => t.id));
  const totalSec = (timeBlocks ?? [])
    .filter((b) => b.taskId !== null && taskIds.has(b.taskId))
    .reduce((s, b) => s + (b.durationSec ?? 0), 0);
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <div className="flex items-center gap-2 text-sm text-gray-400">
          <Link
            to="/projects"
            className="hover:text-gray-600 transition-colors"
          >
            {t("title")}
          </Link>
          <span>/</span>
          <span className="text-gray-600">{project.name}</span>
        </div>

        {editing ? (
          <div className="flex items-center gap-3">
            <input
              type="color"
              value={editColor}
              onChange={(e) => setEditColor(e.target.value)}
              className="h-[38px] w-10 cursor-pointer rounded border border-gray-300 p-0.5"
            />
            <input
              value={editName}
              onChange={(e) => setEditName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleSaveEdit();
                if (e.key === "Escape") setEditing(false);
              }}
              className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
              autoFocus
            />
            <button
              onClick={handleSaveEdit}
              disabled={updateProject.isPending || !editName.trim()}
              className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
            >
              {tc("actions.save")}
            </button>
            <button
              onClick={() => setEditing(false)}
              className="text-sm text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.cancel")}
            </button>
          </div>
        ) : (
          <div className="flex items-center gap-3">
            <span
              className="w-4 h-4 rounded-full shrink-0"
              style={{ backgroundColor: project.color }}
            />
            <div className="flex-1 flex flex-col gap-0.5">
              <h1 className="text-2xl font-semibold tracking-tight">
                {project.name}
              </h1>
              {totalSec > 0 && (
                <p className="text-xs text-gray-400">
                  {t("detail.timeTracked", { h: hours, m: minutes })}
                </p>
              )}
            </div>
            <button
              onClick={startEdit}
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.edit")}
            </button>
            <button
              onClick={() =>
                updateProject.mutate({
                  id: projectId,
                  data: { archived: true },
                })
              }
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.archive")}
            </button>
            <button
              onClick={async () => {
                const ok = await confirm({
                  title: t("detail.deleteTitle"),
                  description: t("detail.deleteDescription", {
                    name: project.name,
                  }),
                  confirmLabel: t("detail.deleteConfirm"),
                  variant: "danger",
                });
                if (ok) deleteProject.mutate({ id: projectId });
              }}
              className="text-xs text-gray-400 hover:text-red-500 transition-colors"
            >
              {tc("actions.delete")}
            </button>
          </div>
        )}

        <div className="flex gap-2">
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                handleAddTask();
              }
            }}
            placeholder={t("detail.addPlaceholder")}
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          <button
            onClick={handleAddTask}
            disabled={createTask.isPending || !title.trim()}
            className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            {tc("actions.add")}
          </button>
        </div>

        {tasksLoading ? (
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
                    onClick={() => handleCycleStatus(task)}
                    className={`text-xs font-medium px-2 py-1 rounded-full whitespace-nowrap transition-colors hover:opacity-80 ${STATUS_COLORS[task.status] ?? "bg-gray-100 text-gray-600"}`}
                  >
                    {tc(`status.${task.status}`)}
                  </button>
                  <Link
                    to="/tasks/$taskId"
                    params={{ taskId: task.id }}
                    className={`flex-1 text-sm hover:underline ${task.status === "done" ? "line-through text-gray-400" : ""}`}
                  >
                    {task.title}
                  </Link>
                  <button
                    onClick={() =>
                      updateTask.mutate({
                        id: task.id,
                        data: { status: "archived" },
                      })
                    }
                    className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
                  >
                    {tc("actions.archive")}
                  </button>
                  <button
                    onClick={() => deleteTask.mutate({ id: task.id })}
                    className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                  >
                    {tc("actions.delete")}
                  </button>
                </li>
              ))}
              {active.length === 0 && (
                <p className="text-gray-400 text-sm">{t("detail.noTasks")}</p>
              )}
            </ul>

            {archivedTasks.length > 0 && (
              <div className="flex flex-col gap-2">
                <button
                  onClick={() => setShowArchived((v) => !v)}
                  className="text-xs text-gray-400 hover:text-gray-600 transition-colors self-start"
                >
                  {showArchived ? t("hideArchived") : t("showArchived")} (
                  {archivedTasks.length})
                </button>
                {showArchived && (
                  <ul className="flex flex-col gap-2">
                    {archivedTasks.map((task: TaskBody) => (
                      <li
                        key={task.id}
                        className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3 opacity-60"
                      >
                        <span className="flex-1 text-sm line-through text-gray-400">
                          {task.title}
                        </span>
                        <button
                          onClick={() =>
                            updateTask.mutate({
                              id: task.id,
                              data: { status: "todo" },
                            })
                          }
                          className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
                        >
                          {t("unarchive")}
                        </button>
                        <button
                          onClick={() => deleteTask.mutate({ id: task.id })}
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
