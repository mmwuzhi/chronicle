import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { useCreateTask, getListTasksQueryKey } from "../api";

export function TaskComposer({ projectId }: { projectId: string }) {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const [title, setTitle] = useState("");

  const invalidateTasks = () =>
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const createTask = useCreateTask({
    mutation: { onSuccess: invalidateTasks },
  });

  const handleAdd = () => {
    const trimmed = title.trim();
    if (!trimmed) return;
    createTask.mutate(
      { data: { title: trimmed, type: "task", projectId } },
      { onSuccess: () => setTitle("") },
    );
  };

  return (
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
        placeholder={t("detail.addPlaceholder")}
        className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
      />
      <button
        onClick={handleAdd}
        disabled={createTask.isPending || !title.trim()}
        className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
      >
        {tc("actions.add")}
      </button>
    </div>
  );
}
