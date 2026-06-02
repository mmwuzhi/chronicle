import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useConfirm } from "../components/confirm-dialog";
import {
  useListTasks,
  useCreateTask,
  useUpdateTask,
  useDeleteTask,
  getListTasksQueryKey,
  useListProjects,
} from "../api";
import type { TaskBody } from "../api";
import { Nav } from "../components/nav";
import { DueBadge } from "../components/DueBadge";
import { STATUS_CYCLE, STATUS_COLORS } from "../constants/status";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/tasks/")({
  component: Tasks,
});

function Tasks() {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
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
  const update = useUpdateTask({
    mutation: {
      onMutate: async ({ id, data }) => {
        await queryClient.cancelQueries({ queryKey: getListTasksQueryKey() });
        const previous = queryClient.getQueriesData<TaskBody[]>({
          queryKey: getListTasksQueryKey(),
        });
        queryClient.setQueriesData<TaskBody[]>(
          { queryKey: getListTasksQueryKey() },
          (old) =>
            old == null
              ? old
              : old.map((t) => (t.id === id ? { ...t, ...data } : t)),
        );
        return { previous };
      },
      onError: (_err, _vars, context) => {
        context?.previous.forEach(([key, val]) =>
          queryClient.setQueryData(key, val),
        );
      },
      onSettled: invalidate,
    },
  });
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

        <div className="bg-white border border-gray-200 rounded-xl p-3 flex flex-col gap-2.5 shadow-sm">
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
            className="w-full text-sm focus:outline-none placeholder:text-gray-400 bg-transparent"
          />
          <div className="flex items-center gap-2">
            <div className="flex gap-1 flex-1 overflow-x-auto">
              <button
                onClick={() => setNewTaskProjectId("")}
                className={`text-xs px-2.5 py-1 rounded-full whitespace-nowrap transition-colors ${
                  newTaskProjectId === ""
                    ? "bg-gray-100 ring-1 ring-gray-300 text-gray-700"
                    : "text-gray-400 hover:text-gray-600 hover:bg-gray-50"
                }`}
              >
                {tc("noProject")}
              </button>
              {activeProjects.map((p) => (
                <button
                  key={p.id}
                  onClick={() => setNewTaskProjectId(p.id)}
                  className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full whitespace-nowrap transition-colors ${
                    newTaskProjectId === p.id
                      ? "bg-gray-100 ring-1 ring-gray-300 text-gray-700"
                      : "text-gray-400 hover:text-gray-600 hover:bg-gray-50"
                  }`}
                >
                  <span
                    className="w-1.5 h-1.5 rounded-full shrink-0"
                    style={{ backgroundColor: p.color }}
                  />
                  {p.name}
                </button>
              ))}
            </div>
            <button
              onClick={handleAdd}
              disabled={create.isPending || !title.trim()}
              className="bg-gray-900 text-white rounded-md px-4 py-1.5 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50 shrink-0"
            >
              {t("add")}
            </button>
          </div>
        </div>

        <div className="flex gap-1 overflow-x-auto">
          <button
            onClick={() => setFilterProjectId("")}
            className={`px-3 py-1.5 rounded-md text-sm font-medium whitespace-nowrap transition-colors ${
              filterProjectId === ""
                ? "bg-gray-900 text-white"
                : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
            }`}
          >
            {t("allProjects")}
          </button>
          {activeProjects.map((p) => (
            <button
              key={p.id}
              onClick={() => setFilterProjectId(p.id)}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium whitespace-nowrap transition-colors ${
                filterProjectId === p.id
                  ? "bg-gray-900 text-white"
                  : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
              }`}
            >
              <span
                className="w-2 h-2 rounded-full shrink-0"
                style={{
                  backgroundColor: filterProjectId === p.id ? "white" : p.color,
                }}
              />
              {p.name}
            </button>
          ))}
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
                    onClick={async () => {
                      const ok = await confirm({
                        title: "Delete task?",
                        description: "This cannot be undone.",
                        confirmLabel: "Delete",
                        variant: "danger",
                      });
                      if (ok) del.mutate({ id: task.id });
                    }}
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
                          onClick={async () => {
                            const ok = await confirm({
                              title: "Delete task?",
                              description: "This cannot be undone.",
                              confirmLabel: "Delete",
                              variant: "danger",
                            });
                            if (ok) del.mutate({ id: task.id });
                          }}
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
