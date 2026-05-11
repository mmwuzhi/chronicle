import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import {
  useListTasks,
  useCreateTask,
  useUpdateTask,
  useDeleteTask,
} from "../api";
import type { TaskBody, TaskUpdateInputBodyStatus } from "../api";
import { Nav } from "../components/nav";

export const Route = createFileRoute("/tasks")({
  component: Tasks,
});

const STATUS_CYCLE: Record<string, TaskUpdateInputBodyStatus> = {
  todo: "in_progress",
  in_progress: "done",
  done: "todo",
};

const STATUS_LABELS: Record<string, string> = {
  todo: "To Do",
  in_progress: "In Progress",
  done: "Done",
  archived: "Archived",
};

const STATUS_COLORS: Record<string, string> = {
  todo: "bg-gray-100 text-gray-600",
  in_progress: "bg-blue-100 text-blue-700",
  done: "bg-green-100 text-green-700",
  archived: "bg-gray-100 text-gray-400",
};

function Tasks() {
  const navigate = useNavigate();
  const [title, setTitle] = useState("");

  const { data: tasks, error, isLoading } = useListTasks(undefined);
  const create = useCreateTask();
  const update = useUpdateTask();
  const del = useDeleteTask();

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">Failed to load tasks</div>;
  }

  const handleAdd = () => {
    const trimmed = title.trim();
    if (!trimmed) return;
    create.mutate(
      { data: { title: trimmed, type: "task" } },
      { onSuccess: () => setTitle("") },
    );
  };

  const handleCycleStatus = (task: TaskBody) => {
    const next = STATUS_CYCLE[task.status] ?? "todo";
    update.mutate({ id: task.id, data: { status: next } });
  };

  const active = (tasks ?? []).filter((t: TaskBody) => t.status !== "archived");

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-6">
        <h1 className="text-2xl font-semibold tracking-tight">Tasks</h1>

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
            placeholder="Add a task… (Enter to save)"
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          <button
            onClick={handleAdd}
            disabled={create.isPending || !title.trim()}
            className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            Add
          </button>
        </div>

        {isLoading ? (
          <div className="text-gray-400 text-sm">Loading…</div>
        ) : (
          <ul className="flex flex-col gap-2">
            {active.map((t: TaskBody) => (
              <li
                key={t.id}
                className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3"
              >
                <button
                  onClick={() => handleCycleStatus(t)}
                  className={`text-xs font-medium px-2 py-1 rounded-full whitespace-nowrap transition-colors hover:opacity-80 ${STATUS_COLORS[t.status] ?? "bg-gray-100 text-gray-600"}`}
                >
                  {STATUS_LABELS[t.status] ?? t.status}
                </button>
                <span
                  className={`flex-1 text-sm ${t.status === "done" ? "line-through text-gray-400" : ""}`}
                >
                  {t.title}
                </span>
                <button
                  onClick={() => del.mutate({ id: t.id })}
                  className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                >
                  Delete
                </button>
              </li>
            ))}
            {active.length === 0 && (
              <p className="text-gray-400 text-sm">No tasks yet.</p>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}
