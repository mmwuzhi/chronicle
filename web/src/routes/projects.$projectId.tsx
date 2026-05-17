import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
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
} from "../api";
import type { TaskBody, TaskUpdateInputBodyStatus } from "../api";
import { Nav } from "../components/nav";

export const Route = createFileRoute("/projects/$projectId")({
  component: ProjectDetail,
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

function ProjectDetail() {
  const { projectId } = Route.useParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [title, setTitle] = useState("");
  const [editing, setEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editColor, setEditColor] = useState("");
  const [deleteOpen, setDeleteOpen] = useState(false);

  const {
    data: projects,
    isLoading: projectsLoading,
    error: projectsError,
  } = useListProjects();
  const project = projects?.find((p) => p.id === projectId);

  const { data: tasks, isLoading: tasksLoading } = useListTasks({ projectId });

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
    return <div className="p-8 text-red-500">Failed to load project</div>;
  }

  if (projectsLoading) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-8 py-8">
          <div className="text-gray-400 text-sm">Loading…</div>
        </div>
      </div>
    );
  }

  if (!project) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-4">
          <p className="text-gray-500 text-sm">Project not found.</p>
          <Link
            to="/projects"
            className="text-sm text-gray-900 font-medium hover:underline"
          >
            Back to projects
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
    (t: TaskBody) => t.status !== "archived",
  );

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-6">
        {/* Breadcrumb */}
        <div className="flex items-center gap-2 text-sm text-gray-400">
          <Link
            to="/projects"
            className="hover:text-gray-600 transition-colors"
          >
            Projects
          </Link>
          <span>/</span>
          <span className="text-gray-600">{project.name}</span>
        </div>

        {/* Header */}
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
              Save
            </button>
            <button
              onClick={() => setEditing(false)}
              className="text-sm text-gray-400 hover:text-gray-600 transition-colors"
            >
              Cancel
            </button>
          </div>
        ) : (
          <div className="flex items-center gap-3">
            <span
              className="w-4 h-4 rounded-full shrink-0"
              style={{ backgroundColor: project.color }}
            />
            <h1 className="text-2xl font-semibold tracking-tight flex-1">
              {project.name}
            </h1>
            <button
              onClick={startEdit}
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              Edit
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
              Archive
            </button>
            <Dialog.Root open={deleteOpen} onOpenChange={setDeleteOpen}>
              <Dialog.Trigger asChild>
                <button className="text-xs text-gray-400 hover:text-red-500 transition-colors">
                  Delete
                </button>
              </Dialog.Trigger>
              <Dialog.Portal>
                <Dialog.Overlay className="fixed inset-0 bg-black/40" />
                <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
                  <Dialog.Title className="text-lg font-semibold">
                    Delete project
                  </Dialog.Title>
                  <Dialog.Description className="text-sm text-gray-600">
                    This will permanently delete "{project.name}". Tasks in this
                    project will be kept but unassigned.
                  </Dialog.Description>
                  <div className="flex justify-end gap-3 mt-2">
                    <Dialog.Close asChild>
                      <button className="text-sm px-4 py-2 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors">
                        Cancel
                      </button>
                    </Dialog.Close>
                    <button
                      onClick={() =>
                        deleteProject.mutate({ id: projectId })
                      }
                      disabled={deleteProject.isPending}
                      className="text-sm px-4 py-2 rounded-md bg-red-600 text-white hover:bg-red-700 transition-colors disabled:opacity-50"
                    >
                      {deleteProject.isPending ? "Deleting…" : "Yes, delete"}
                    </button>
                  </div>
                </Dialog.Content>
              </Dialog.Portal>
            </Dialog.Root>
          </div>
        )}

        {/* Quick-add task */}
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
            placeholder="Add a task… (Enter to save)"
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          <button
            onClick={handleAddTask}
            disabled={createTask.isPending || !title.trim()}
            className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            Add
          </button>
        </div>

        {/* Task list */}
        {tasksLoading ? (
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
                <Link
                  to="/tasks/$taskId"
                  params={{ taskId: t.id }}
                  className={`flex-1 text-sm hover:underline ${t.status === "done" ? "line-through text-gray-400" : ""}`}
                >
                  {t.title}
                </Link>
                <button
                  onClick={() => deleteTask.mutate({ id: t.id })}
                  className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                >
                  Delete
                </button>
              </li>
            ))}
            {active.length === 0 && (
              <p className="text-gray-400 text-sm">
                No tasks in this project yet.
              </p>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}
