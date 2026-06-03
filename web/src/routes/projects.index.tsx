import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useQueryClient } from "@tanstack/react-query";
import {
  useListProjects,
  useCreateProject,
  useUpdateProject,
  getListProjectsQueryKey,
  useListTasks,
} from "../api";
import type { TaskBody } from "../api";
import { Nav } from "../components/nav";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/projects/")({ component: Projects });

const createSchema = z.object({
  name: z.string().min(1, "Name is required"),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/, "Must be a hex color"),
});
type CreateForm = z.infer<typeof createSchema>;

const PRESET_COLORS = [
  "#0e9e6e",
  "#3b82f6",
  "#8b5cf6",
  "#f59e0b",
  "#ef4444",
  "#ec4899",
  "#06b6d4",
  "#64748b",
];

function Projects() {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [showArchived, setShowArchived] = useState(false);

  const { data: projects, isLoading, error } = useListProjects();
  const { data: allTasks } = useListTasks({});

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListProjectsQueryKey() });
  const create = useCreateProject({ mutation: { onSuccess: invalidate } });
  const update = useUpdateProject({ mutation: { onSuccess: invalidate } });

  const {
    register,
    handleSubmit,
    reset,
    watch,
    setValue,
    formState: { errors },
  } = useForm<CreateForm>({
    resolver: zodResolver(createSchema),
    defaultValues: { color: PRESET_COLORS[0] },
  });

  const watchedColor = watch("color");

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

  const active = projects?.filter((p) => !p.archived) ?? [];
  const archived = projects?.filter((p) => p.archived) ?? [];

  const taskStatsByProject = new Map<string, { done: number; total: number }>();
  for (const task of (allTasks ?? []) as TaskBody[]) {
    if (!task.projectId || task.status === "archived") continue;
    const s = taskStatsByProject.get(task.projectId) ?? { done: 0, total: 0 };
    s.total++;
    if (task.status === "done") s.done++;
    taskStatsByProject.set(task.projectId, s);
  }

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 640, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
        </div>

        {/* Create form */}
        <div
          className="ch-card"
          style={{ padding: "var(--pad)", marginBottom: 24 }}
        >
          <form
            onSubmit={handleSubmit((data) =>
              create.mutate({ data }, { onSuccess: () => reset() }),
            )}
            style={{ display: "flex", flexDirection: "column", gap: 12 }}
          >
            <input
              {...register("name")}
              placeholder={t("newProjectName")}
              className="ch-input"
            />
            {errors.name && (
              <p
                style={{
                  fontSize: "var(--fs-xs)",
                  color: "#c2410c",
                  margin: 0,
                }}
              >
                {errors.name.message}
              </p>
            )}

            {/* Color presets */}
            <div
              style={{
                display: "flex",
                gap: 8,
                alignItems: "center",
                flexWrap: "wrap",
              }}
            >
              {PRESET_COLORS.map((c) => (
                <button
                  key={c}
                  type="button"
                  onClick={() => setValue("color", c)}
                  style={{
                    width: 22,
                    height: 22,
                    borderRadius: "50%",
                    background: c,
                    border:
                      watchedColor === c
                        ? "2px solid var(--text)"
                        : "2px solid transparent",
                    cursor: "pointer",
                    flexShrink: 0,
                  }}
                />
              ))}
              <input
                type="color"
                {...register("color")}
                style={{
                  width: 22,
                  height: 22,
                  borderRadius: "50%",
                  border: "none",
                  padding: 0,
                  cursor: "pointer",
                }}
                title="Custom color"
              />
            </div>

            <div style={{ display: "flex", justifyContent: "flex-end" }}>
              <button
                type="submit"
                disabled={create.isPending}
                className="ch-btn ch-btn-primary ch-btn-sm"
              >
                {t("addProject")}
              </button>
            </div>
          </form>
        </div>

        {isLoading ? (
          <p className="ch-meta">{tc("loading")}</p>
        ) : (
          <>
            <div className="ch-list">
              {active.map((p) => {
                const stats = taskStatsByProject.get(p.id);
                const pct =
                  stats && stats.total > 0
                    ? (stats.done / stats.total) * 100
                    : 0;
                return (
                  <div
                    key={p.id}
                    className="ch-row"
                    style={{ display: "flex", alignItems: "center", gap: 12 }}
                  >
                    <Link
                      to="/projects/$projectId"
                      params={{ projectId: p.id }}
                      style={{
                        flex: 1,
                        display: "flex",
                        alignItems: "center",
                        gap: 12,
                        textDecoration: "none",
                        minWidth: 0,
                      }}
                    >
                      <span
                        style={{
                          width: 12,
                          height: 12,
                          borderRadius: "50%",
                          background: p.color,
                          flexShrink: 0,
                        }}
                      />
                      <span style={{ flex: 1, minWidth: 0 }}>
                        <span
                          style={{
                            display: "block",
                            fontSize: "var(--fs-sm)",
                            fontWeight: 600,
                            color: "var(--text)",
                            overflow: "hidden",
                            textOverflow: "ellipsis",
                            whiteSpace: "nowrap",
                          }}
                        >
                          {p.name}
                        </span>
                        {stats && stats.total > 0 && (
                          <>
                            <span className="ch-meta">
                              {t("tasksDone", {
                                done: stats.done,
                                total: stats.total,
                              })}
                            </span>
                            <div
                              style={{
                                height: 3,
                                borderRadius: 2,
                                background: "var(--bg-tint)",
                                marginTop: 4,
                                overflow: "hidden",
                              }}
                            >
                              <div
                                style={{
                                  height: "100%",
                                  width: `${pct}%`,
                                  background: "var(--accent)",
                                  borderRadius: 2,
                                  transition: "width .3s",
                                }}
                              />
                            </div>
                          </>
                        )}
                      </span>
                    </Link>
                    <button
                      className="ch-btn ch-btn-ghost ch-btn-sm"
                      onClick={() =>
                        update.mutate({ id: p.id, data: { archived: true } })
                      }
                    >
                      {tc("actions.archive")}
                    </button>
                  </div>
                );
              })}
              {active.length === 0 && (
                <div className="ch-empty">
                  <p>{t("noProjects")}</p>
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
                    {archived.map((p) => (
                      <div
                        key={p.id}
                        className="ch-row"
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: 12,
                        }}
                      >
                        <span
                          style={{
                            width: 10,
                            height: 10,
                            borderRadius: "50%",
                            background: p.color,
                            flexShrink: 0,
                          }}
                        />
                        <span
                          style={{
                            flex: 1,
                            fontSize: "var(--fs-sm)",
                            color: "var(--text-muted)",
                          }}
                        >
                          {p.name}
                        </span>
                        <button
                          className="ch-btn ch-btn-ghost ch-btn-sm"
                          onClick={() =>
                            update.mutate({
                              id: p.id,
                              data: { archived: false },
                            })
                          }
                        >
                          {t("unarchive")}
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
