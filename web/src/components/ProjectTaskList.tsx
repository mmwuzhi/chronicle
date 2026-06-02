import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { useConfirm } from "./confirm-dialog";
import {
  useListTasks,
  useUpdateTask,
  useDeleteTask,
  getListTasksQueryKey,
} from "../api";
import type { TaskBody } from "../api";
import { STATUS_CYCLE, STATUS_COLORS } from "../constants/status";

export function ProjectTaskList({ projectId }: { projectId: string }) {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [showArchived, setShowArchived] = useState(false);

  const { data: tasks, isLoading } = useListTasks({ projectId });

  const invalidateTasks = () =>
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const updateTask = useUpdateTask({
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
      onSettled: invalidateTasks,
    },
  });
  const deleteTask = useDeleteTask({
    mutation: { onSuccess: invalidateTasks },
  });

  if (isLoading) {
    return <div className="text-gray-400 text-sm">{tc("loading")}</div>;
  }

  const active = (tasks ?? []).filter(
    (task: TaskBody) => task.status !== "archived",
  );
  const archivedTasks = (tasks ?? []).filter(
    (task: TaskBody) => task.status === "archived",
  );

  return (
    <>
      <ul className="flex flex-col gap-2">
        {active.map((task: TaskBody) => (
          <li
            key={task.id}
            className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3"
          >
            <button
              onClick={() => {
                const next = STATUS_CYCLE[task.status] ?? "todo";
                updateTask.mutate({ id: task.id, data: { status: next } });
              }}
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
                updateTask.mutate({ id: task.id, data: { status: "archived" } })
              }
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.archive")}
            </button>
            <button
              onClick={async () => {
                const ok = await confirm({
                  title: tc("confirm.deleteTask"),
                  description: tc("confirm.cannotUndo"),
                  confirmLabel: tc("actions.delete"),
                  variant: "danger",
                });
                if (ok) deleteTask.mutate({ id: task.id });
              }}
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
                    onClick={async () => {
                      const ok = await confirm({
                        title: tc("confirm.deleteTask"),
                        description: tc("confirm.cannotUndo"),
                        confirmLabel: tc("actions.delete"),
                        variant: "danger",
                      });
                      if (ok) deleteTask.mutate({ id: task.id });
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
  );
}
