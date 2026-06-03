import { createFileRoute, Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  useGetMe,
  useListTasks,
  useListCaptures,
  useListTimeBlocks,
  useListLogEntries,
  useUpdateTask,
  getListTasksQueryKey,
} from "../api";
import type { CaptureBody, TaskBody, TaskUpdateInputBodyStatus } from "../api";

import { Nav } from "../components/nav";

export const Route = createFileRoute("/")({ component: Index });

function weekStart(): Date {
  const now = new Date();
  const day = now.getUTCDay();
  const diff = day === 0 ? 6 : day - 1;
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - diff),
  );
}

const CL_CLASS: Record<string, string> = {
  unclassified: "cl-unclassified",
  idea: "cl-idea",
  task: "cl-task",
  routine: "cl-routine",
  log: "cl-log",
};

const STATUS_CYCLE: Record<string, TaskUpdateInputBodyStatus> = {
  todo: "in_progress",
  in_progress: "done",
  done: "todo",
};

function Dashboard() {
  const { t } = useTranslation("dashboard");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();

  const { data: me } = useGetMe();
  const { data: tasks } = useListTasks(undefined, { query: { enabled: !!me } });
  const { data: captures } = useListCaptures(undefined, {
    query: { enabled: !!me },
  });
  const { data: blocks } = useListTimeBlocks(undefined, {
    query: { enabled: !!me },
  });
  const { data: entries } = useListLogEntries(undefined, {
    query: { enabled: !!me },
  });

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

  const ws = weekStart();
  const allTasks = tasks ?? [];
  const activeTasks = allTasks.filter(
    (t: TaskBody) => t.status === "todo" || t.status === "in_progress",
  );
  const doneTasks = allTasks.filter((t: TaskBody) => t.status === "done");
  const recentCaptures = (captures ?? []).slice(0, 5);
  const weekBlocks = (blocks ?? []).filter((b) => new Date(b.startedAt) >= ws);
  const totalSec = weekBlocks.reduce((s, b) => s + (b.durationSec ?? 0), 0);
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);
  const entryCount = (entries ?? []).length;
  const name = me?.email?.split("@")[0] ?? "";

  const stats = [
    {
      label: t("tasksDone", { done: doneTasks.length, total: allTasks.length }),
    },
    { label: t("capturesCreated", { count: (captures ?? []).length }) },
    { label: t("logEntries", { count: entryCount }) },
    { label: t("timeTracked", { h: hours, m: minutes }) },
  ];

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <p className="ch-eyebrow">{t("greeting")}</p>
          <h1 className="ch-title">{name}</h1>
        </div>

        {/* Week stats card */}
        <div
          className="ch-card"
          style={{
            padding: "var(--pad)",
            background:
              "linear-gradient(180deg, var(--accent-weak), transparent 70%)",
            marginBottom: 24,
          }}
        >
          <p className="ch-eyebrow" style={{ marginBottom: 12 }}>
            {t("thisWeek")}
          </p>
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(2, 1fr)",
              gap: "var(--gap)",
            }}
          >
            {stats.map((s, i) => (
              <div
                key={i}
                style={{
                  fontSize: "var(--fs-sm)",
                  fontWeight: 600,
                  color: "var(--text)",
                }}
              >
                {s.label}
              </div>
            ))}
          </div>
        </div>

        {/* Recent captures */}
        <div className="ch-section">
          <span className="bar" />
          <span className="ch-sectlabel">{t("recentCaptures")}</span>
          <span className="ch-sectcount">{recentCaptures.length}</span>
          <span className="rule" />
        </div>
        {recentCaptures.length === 0 ? (
          <div className="ch-empty">
            <p>{t("noCaptures")}</p>
          </div>
        ) : (
          <div className="ch-list">
            {recentCaptures.map((c: CaptureBody) => (
              <Link
                key={c.id}
                to="/captures"
                className="ch-row clickable"
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  textDecoration: "none",
                }}
              >
                <p
                  style={{
                    flex: 1,
                    fontSize: "var(--fs-sm)",
                    margin: 0,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {c.rawText ?? "—"}
                </p>
                <span
                  className={`ch-pill ${CL_CLASS[c.classifiedAs] ?? "cl-unclassified"}`}
                >
                  {tc(`classification.${c.classifiedAs}`)}
                </span>
              </Link>
            ))}
          </div>
        )}

        {/* Active tasks */}
        <div className="ch-section">
          <span className="bar" />
          <span className="ch-sectlabel">{t("activeTasks")}</span>
          <span className="ch-sectcount">{activeTasks.length}</span>
          <span className="rule" />
        </div>
        {activeTasks.length === 0 ? (
          <div className="ch-empty">
            <p>{t("noTasks")}</p>
          </div>
        ) : (
          <div className="ch-list">
            {activeTasks.slice(0, 10).map((task: TaskBody) => (
              <div
                key={task.id}
                className="ch-row"
                style={{ display: "flex", alignItems: "center", gap: 12 }}
              >
                <button
                  className={`ch-pill ch-status st-${task.status}`}
                  onClick={() =>
                    updateTask.mutate({
                      id: task.id,
                      data: {
                        status: STATUS_CYCLE[
                          task.status
                        ] as TaskUpdateInputBodyStatus,
                      },
                    })
                  }
                  title={tc(`status.${task.status}`)}
                >
                  {tc(`status.${task.status}`)}
                </button>
                <Link
                  to="/tasks/$taskId"
                  params={{ taskId: task.id }}
                  style={{
                    flex: 1,
                    fontSize: "var(--fs-sm)",
                    textDecoration: "none",
                    color: "var(--text)",
                    minWidth: 0,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {task.title}
                </Link>
              </div>
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function Landing() {
  const { t } = useTranslation();
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        minHeight: "100vh",
        gap: 16,
      }}
    >
      <div
        style={{
          width: 48,
          height: 48,
          borderRadius: 12,
          background: "var(--accent)",
          color: "#fff",
          display: "grid",
          placeItems: "center",
          fontSize: 24,
          fontWeight: 800,
        }}
      >
        C
      </div>
      <h1 className="ch-title">{t("brand")}</h1>
      <p style={{ color: "var(--text-muted)", fontSize: "var(--fs-sm)" }}>
        {t("tagline")}
      </p>
      <div style={{ display: "flex", gap: 10, marginTop: 8 }}>
        <Link to="/login" className="ch-btn ch-btn-primary">
          {t("signIn")}
        </Link>
        <Link to="/register" className="ch-btn">
          {t("createAccount")}
        </Link>
      </div>
    </div>
  );
}

function Index() {
  const { data: me, isLoading } = useGetMe();
  if (isLoading) return null;
  if (!me) return <Landing />;
  return <Dashboard />;
}
