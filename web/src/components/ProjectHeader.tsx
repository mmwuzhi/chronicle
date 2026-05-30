import { useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  useUpdateProject,
  useDeleteProject,
  getListProjectsQueryKey,
} from "../api";
import type { ProjectBody } from "../api";
import { useConfirm } from "./confirm-dialog";

export function ProjectHeader({
  project,
  projectId,
  totalSec,
}: {
  project: ProjectBody;
  projectId: string;
  totalSec: number;
}) {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [editing, setEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editColor, setEditColor] = useState("");

  const invalidateProjects = () =>
    queryClient.invalidateQueries({ queryKey: getListProjectsQueryKey() });

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

  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);

  const startEdit = () => {
    setEditName(project.name);
    setEditColor(project.color);
    setEditing(true);
  };

  const handleSaveEdit = () => {
    updateProject.mutate({
      id: projectId,
      data: { name: editName, color: editColor },
    });
    setEditing(false);
  };

  return (
    <>
      <div className="flex items-center gap-2 text-sm text-gray-400">
        <Link to="/projects" className="hover:text-gray-600 transition-colors">
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
              updateProject.mutate({ id: projectId, data: { archived: true } })
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
    </>
  );
}
