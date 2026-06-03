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
import { DueBadge } from "../components/DueBadge";

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

function timeAgo(iso: string, locale: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  const m = Math.floor(diff / 60000);
  if (m < 60) return rtf.format(-m, "minute");
  const h = Math.floor(m / 60);
  if (h < 24) return rtf.format(-h, "hour");
  return rtf.format(-Math.floor(h / 24), "day");
}

const ChevronRight = () => (
  <svg
    width="16"
    height="16"
    fill="none"
    stroke="currentColor"
    strokeWidth={2}
    viewBox="0 0 24 24"
    style={{ flexShrink: 0, color: "var(--text-faint)" }}
  >
    <path strokeLinecap="round" strokeLinejoin="round" d="m9 18 6-6-6-6" />
  </svg>
);

function Dashboard() {
  const { t, i18n } = useTranslation("dashboard");
  const { t: tc } = useTranslation("common");
  const { t: tt } = useTranslation("tasks");
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

  // Date eyebrow: "TUESDAY · JUN 3"
  const now = new Date();
  const dayName = now
    .toLocaleDateString(undefined, { weekday: "long" })
    .toUpperCase();
  const monthDay = now
    .toLocaleDateString(undefined, { month: "short", day: "numeric" })
    .toUpperCase();
  const dateEyebrow = `${dayName} · ${monthDay}`;

  // Time-aware greeting
  const hour = now.getHours();
  const greetingKey =
    hour < 12 ? "goodMorning" : hour < 17 ? "goodAfternoon" : "goodEvening";

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
      value: `${doneTasks.length}/${allTasks.length}`,
      label: t("tasksDoneLabel"),
    },
    { value: String((captures ?? []).length), label: t("capturesLabel") },
    { value: String(entryCount), label: t("logsLabel") },
    { value: `${hours}h ${minutes}m`, label: t("trackedLabel") },
  ];

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <p className="ch-eyebrow">{dateEyebrow}</p>
          <h1 className="ch-title">
            {t(greetingKey)} {name}
          </h1>
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
          <p
            className="ch-eyebrow"
            style={{ marginBottom: 14, color: "var(--accent-strong)" }}
          >
            <span style={{ marginRight: 4 }}>🌿</span>
            {t("thisWeek")}
          </p>
          <div className="ch-stats-grid">
            {stats.map((s, i) => (
              <div key={i} className="ch-stat-cell">
                <span className="ch-stat-value">{s.value}</span>
                <span className="ch-stat-label">{s.label}</span>
              </div>
            ))}
          </div>
        </div>

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
                style={{ display: "flex", alignItems: "center", gap: 10 }}
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
                  style={{ flexShrink: 0 }}
                >
                  <span className="pdot" />
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
                {task.dueAt && task.status !== "done" && (
                  <DueBadge dueAt={task.dueAt} t={tt} />
                )}
                <ChevronRight />
              </div>
            ))}
          </div>
        )}

        {/* Recent captures */}
        <div className="ch-section">
          <span className="bar" />
          <span className="ch-sectlabel">{t("recentCaptures")}</span>
          <span className="ch-sectcount">{recentCaptures.length}</span>
          <span className="rule" />
          <Link to="/captures" className="ch-sectall">
            {t("viewAll")} →
          </Link>
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
                  flexDirection: "column",
                  gap: 8,
                  textDecoration: "none",
                }}
              >
                <p
                  style={
                    {
                      fontSize: "var(--fs-sm)",
                      margin: 0,
                      color: "var(--text)",
                      lineHeight: 1.55,
                      display: "-webkit-box",
                      WebkitLineClamp: 2,
                      WebkitBoxOrient: "vertical",
                      overflow: "hidden",
                    } as React.CSSProperties
                  }
                >
                  {c.rawText ?? "—"}
                </p>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span
                    className={`ch-pill ${CL_CLASS[c.classifiedAs] ?? "cl-unclassified"}`}
                  >
                    {tc(`classification.${c.classifiedAs}`)}
                  </span>
                  {c.createdAt && (
                    <span className="ch-meta" style={{ marginLeft: "auto" }}>
                      {timeAgo(c.createdAt, i18n.language)}
                    </span>
                  )}
                </div>
              </Link>
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
