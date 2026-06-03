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
import { STATUS_CYCLE } from "../constants/status";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/tasks/")({ component: Tasks });

type StatusFilter = "all" | "active" | "done";

function Tasks() {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [title, setTitle] = useState("");
  const [filterProjectId, setFilterProjectId] = useState("");
  const [newTaskProjectId, setNewTaskProjectId] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
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
    return (
      <div style={{ padding: 32, color: "#c2410c" }}>{t("failedToLoad")}</div>
    );
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

  const allActive = (tasks ?? []).filter(
    (task: TaskBody) => task.status !== "archived",
  );
  const archived = (tasks ?? []).filter(
    (task: TaskBody) => task.status === "archived",
  );

  const filtered =
    statusFilter === "active"
      ? allActive.filter((t: TaskBody) => t.status !== "done")
      : statusFilter === "done"
        ? allActive.filter((t: TaskBody) => t.status === "done")
        : allActive;

  const STATUS_LABEL: Record<string, string> = {
    todo: "·",
    in_progress: "▶",
    done: "✓",
  };

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
        </div>

        {/* Quick-add bar */}
        <div
          className="ch-card"
          style={{ padding: "var(--pad)", marginBottom: 16 }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <input
              className="ch-input"
              style={{ flex: 1, padding: "8px 12px" }}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  handleAdd();
                }
              }}
              placeholder={t("addPlaceholder")}
            />
            <button
              className="ch-btn ch-btn-primary ch-btn-sm"
              onClick={handleAdd}
              disabled={create.isPending || !title.trim()}
            >
              {t("add")}
            </button>
          </div>
          {/* Project selector for new tasks */}
          {activeProjects.length > 0 && (
            <div
              style={{
                display: "flex",
                gap: 6,
                marginTop: 10,
                flexWrap: "wrap",
              }}
            >
              <button
                className={`ch-pill ${newTaskProjectId === "" ? "cl-task" : "cl-unclassified"}`}
                style={{ cursor: "pointer", border: "none" }}
                onClick={() => setNewTaskProjectId("")}
              >
                {tc("noProject")}
              </button>
              {activeProjects.map((p) => (
                <button
                  key={p.id}
                  className={`ch-pill ${newTaskProjectId === p.id ? "cl-task" : "cl-unclassified"}`}
                  style={{ cursor: "pointer", border: "none" }}
                  onClick={() => setNewTaskProjectId(p.id)}
                >
                  <span
                    style={{
                      width: 6,
                      height: 6,
                      borderRadius: "50%",
                      background: p.color,
                      display: "inline-block",
                    }}
                  />
                  {p.name}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Filters row */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            marginBottom: 16,
            flexWrap: "wrap",
          }}
        >
          {/* Project filter */}
          {activeProjects.length > 0 && (
            <select
              value={filterProjectId}
              onChange={(e) => setFilterProjectId(e.target.value)}
              className="ch-input"
              style={{
                width: "auto",
                padding: "6px 10px",
                fontSize: "var(--fs-sm)",
              }}
            >
              <option value="">{t("allProjects")}</option>
              {activeProjects.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          )}
          {/* Status segment */}
          <div className="ch-seg" style={{ marginLeft: "auto" }}>
            {(["all", "active", "done"] as StatusFilter[]).map((s) => (
              <button
                key={s}
                className={`ch-seg-btn${statusFilter === s ? " active" : ""}`}
                onClick={() => setStatusFilter(s)}
              >
                {s === "all"
                  ? tc("status.all")
                  : s === "active"
                    ? tc("status.active")
                    : tc("status.done")}
              </button>
            ))}
          </div>
        </div>

        {isLoading ? (
          <div className="ch-meta">{tc("loading")}</div>
        ) : (
          <>
            <div className="ch-list">
              {filtered.map((task: TaskBody) => (
                <div
                  key={task.id}
                  className="ch-row"
                  style={{ display: "flex", alignItems: "center", gap: 10 }}
                >
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      handleCycleStatus(task);
                    }}
                    title={tc(`status.${task.status}`)}
                    style={{
                      width: 28,
                      height: 28,
                      borderRadius: "50%",
                      border: "1.5px solid var(--border-strong)",
                      background:
                        task.status === "in_progress"
                          ? "var(--accent-weak)"
                          : task.status === "done"
                            ? "color-mix(in srgb, var(--text-faint) 16%, transparent)"
                            : "transparent",
                      color:
                        task.status === "in_progress"
                          ? "var(--accent-strong)"
                          : "var(--text-faint)",
                      display: "grid",
                      placeItems: "center",
                      cursor: "pointer",
                      flexShrink: 0,
                      fontSize: 12,
                      fontWeight: 700,
                      transition: "background .12s",
                    }}
                  >
                    {STATUS_LABEL[task.status] ?? "·"}
                  </button>

                  {task.projectId && projectMap.get(task.projectId) && (
                    <Link
                      to="/projects/$projectId"
                      params={{ projectId: task.projectId }}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 5,
                        textDecoration: "none",
                        flexShrink: 0,
                      }}
                      onClick={(e) => e.stopPropagation()}
                    >
                      <span
                        style={{
                          width: 7,
                          height: 7,
                          borderRadius: "50%",
                          background: projectMap.get(task.projectId)!.color,
                        }}
                      />
                    </Link>
                  )}

                  <Link
                    to="/tasks/$taskId"
                    params={{ taskId: task.id }}
                    style={{
                      flex: 1,
                      fontSize: "var(--fs-sm)",
                      textDecoration: "none",
                      color:
                        task.status === "done"
                          ? "var(--text-faint)"
                          : "var(--text)",
                      textDecorationLine:
                        task.status === "done" ? "line-through" : "none",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {task.title}
                  </Link>

                  {task.dueAt && task.status !== "done" && (
                    <DueBadge dueAt={task.dueAt} t={t} />
                  )}

                  <button
                    className="ch-btn ch-btn-ghost ch-btn-sm"
                    onClick={() =>
                      update.mutate({
                        id: task.id,
                        data: { status: "archived" },
                      })
                    }
                    style={{ fontSize: "var(--fs-xs)", padding: "4px 8px" }}
                  >
                    {tc("actions.archive")}
                  </button>
                  <button
                    className="ch-btn ch-btn-ghost ch-btn-sm"
                    style={{
                      color: "var(--text-faint)",
                      fontSize: "var(--fs-xs)",
                      padding: "4px 8px",
                    }}
                    onClick={async () => {
                      const ok = await confirm({
                        title: tc("confirm.deleteTask"),
                        description: tc("confirm.cannotUndo"),
                        confirmLabel: tc("actions.delete"),
                        variant: "danger",
                      });
                      if (ok) del.mutate({ id: task.id });
                    }}
                  >
                    {tc("actions.delete")}
                  </button>
                </div>
              ))}
              {filtered.length === 0 && (
                <div className="ch-empty">
                  <p>{t("noTasks")}</p>
                </div>
              )}
            </div>

            {archived.length > 0 && (
              <div style={{ marginTop: 24 }}>
                <button
                  className="ch-btn ch-btn-ghost ch-btn-sm"
                  onClick={() => setShowArchived((v) => !v)}
                >
                  {showArchived ? t("hideArchived") : t("showArchived")} (
                  {archived.length})
                </button>
                {showArchived && (
                  <div
                    className="ch-list"
                    style={{ marginTop: 12, opacity: 0.6 }}
                  >
                    {archived.map((task: TaskBody) => (
                      <div
                        key={task.id}
                        className="ch-row"
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: 10,
                        }}
                      >
                        <span
                          style={{
                            flex: 1,
                            fontSize: "var(--fs-sm)",
                            textDecoration: "line-through",
                            color: "var(--text-faint)",
                          }}
                        >
                          {task.title}
                        </span>
                        <button
                          className="ch-btn ch-btn-ghost ch-btn-sm"
                          onClick={() =>
                            update.mutate({
                              id: task.id,
                              data: { status: "todo" },
                            })
                          }
                        >
                          {t("unarchive")}
                        </button>
                        <button
                          className="ch-btn ch-btn-ghost ch-btn-sm"
                          style={{ color: "var(--text-faint)" }}
                          onClick={async () => {
                            const ok = await confirm({
                              title: tc("confirm.deleteTask"),
                              description: tc("confirm.cannotUndo"),
                              confirmLabel: tc("actions.delete"),
                              variant: "danger",
                            });
                            if (ok) del.mutate({ id: task.id });
                          }}
                        >
                          {tc("actions.delete")}
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </>
  );
}
