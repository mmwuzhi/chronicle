import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import {
  useGetTask,
  useUpdateTask,
  useListLogEntries,
  useCreateLogEntry,
  useDeleteLogEntry,
} from "../api";
import type { LogEntryBody, TaskUpdateInputBodyStatus } from "../api";
import { Nav } from "../components/nav";

export const Route = createFileRoute("/tasks/$taskId")({
  component: TaskDetail,
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

function TaskDetail() {
  const { taskId } = Route.useParams();
  const navigate = useNavigate();
  const [body, setBody] = useState("");

  const {
    data: task,
    error: taskError,
    isLoading: taskLoading,
  } = useGetTask(taskId);
  const { data: entries, isLoading: entriesLoading } = useListLogEntries({
    taskId,
  });
  const update = useUpdateTask();
  const createEntry = useCreateLogEntry();
  const deleteEntry = useDeleteLogEntry();

  if (taskError) {
    const status = (taskError as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">Failed to load task</div>;
  }

  const handleCycleStatus = () => {
    if (!task) return;
    const next = STATUS_CYCLE[task.status] ?? "todo";
    update.mutate({ id: task.id, data: { status: next } });
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
      <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-6">
        <div className="flex items-center gap-2 text-sm text-gray-400">
          <Link to="/tasks" className="hover:text-gray-600 transition-colors">
            Tasks
          </Link>
          <span>/</span>
          <span className="text-gray-600">Detail</span>
        </div>

        {taskLoading ? (
          <div className="text-gray-400 text-sm">Loading…</div>
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
                {STATUS_LABELS[task.status] ?? task.status}
              </button>
            </div>

            <section className="flex flex-col gap-4">
              <h2 className="text-sm font-medium text-gray-500 uppercase tracking-wide">
                Log
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
                  placeholder="Add a note… (Enter to save, Shift+Enter for newline)"
                  rows={2}
                  className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none"
                />
                <div className="flex justify-end">
                  <button
                    onClick={handleAddEntry}
                    disabled={createEntry.isPending || !body.trim()}
                    className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
                  >
                    Add note
                  </button>
                </div>
              </div>

              {entriesLoading ? (
                <div className="text-gray-400 text-sm">Loading…</div>
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
                          Delete
                        </button>
                      </div>
                    </li>
                  ))}
                  {(entries ?? []).length === 0 && (
                    <p className="text-gray-400 text-sm">No notes yet.</p>
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
