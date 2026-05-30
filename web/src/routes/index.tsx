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

export const Route = createFileRoute("/")({
  component: Index,
});

function weekStart(): Date {
  const now = new Date();
  const day = now.getUTCDay();
  const diff = day === 0 ? 6 : day - 1;
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - diff),
  );
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

const CLASS_COLORS: Record<string, string> = {
  unclassified: "bg-gray-100 text-gray-500",
  idea: "bg-purple-100 text-purple-700",
  task: "bg-blue-100 text-blue-700",
  routine: "bg-green-100 text-green-700",
  log: "bg-yellow-100 text-yellow-700",
};

const STATUS_OPTIONS: TaskUpdateInputBodyStatus[] = [
  "todo",
  "in_progress",
  "done",
];

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
    mutation: { onSuccess: invalidateTasks },
  });

  const ws = weekStart();

  const allTasks = tasks ?? [];
  const activeTasks = allTasks.filter(
    (t: TaskBody) => t.status === "todo" || t.status === "in_progress",
  );
  const doneTasks = allTasks.filter((t: TaskBody) => t.status === "done");

  const allCaptures = captures ?? [];
  const recentCaptures = allCaptures.slice(0, 5);

  const weekBlocks = (blocks ?? []).filter((b) => new Date(b.startedAt) >= ws);
  const totalSec = weekBlocks.reduce((s, b) => s + (b.durationSec ?? 0), 0);
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);

  const entryCount = (entries ?? []).length;

  const name = me?.email?.split("@")[0] ?? "";

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-8">
        <div>
          <p className="text-sm text-gray-500">{t("greeting")}</p>
          <h1 className="text-2xl font-semibold tracking-tight">{name}</h1>
        </div>

        <div className="bg-white rounded-lg border border-gray-200 shadow-sm p-5">
          <p className="text-xs font-medium text-gray-400 uppercase tracking-wide mb-4">
            {t("thisWeek")}
          </p>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <Stat
              label={t("tasksDone", {
                done: doneTasks.length,
                total: allTasks.length,
              })}
            />
            <Stat label={t("capturesCreated", { count: allCaptures.length })} />
            <Stat label={t("logEntries", { count: entryCount })} />
            <Stat label={t("timeTracked", { h: hours, m: minutes })} />
          </div>
        </div>

        <section className="flex flex-col gap-3">
          <h2 className="text-sm font-semibold text-gray-700">
            {t("recentCaptures")}
          </h2>
          {recentCaptures.length === 0 ? (
            <p className="text-sm text-gray-400">{t("noCaptures")}</p>
          ) : (
            <ul className="flex flex-col gap-2">
              {recentCaptures.map((c: CaptureBody) => (
                <li key={c.id}>
                  <Link
                    to="/captures"
                    className="bg-white rounded-lg border border-gray-200 px-4 py-3 flex items-center gap-3 hover:bg-gray-50 transition-colors"
                  >
                    <p className="text-sm flex-1 truncate">
                      {c.rawText ?? "—"}
                    </p>
                    <span
                      className={`text-xs px-2 py-0.5 rounded-full flex-shrink-0 ${CLASS_COLORS[c.classifiedAs] ?? "bg-gray-100 text-gray-500"}`}
                    >
                      {tc(`classification.${c.classifiedAs}`)}
                    </span>
                    <span className="text-xs text-gray-400 flex-shrink-0">
                      {fmtDate(c.createdAt)}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="flex flex-col gap-3">
          <h2 className="text-sm font-semibold text-gray-700">
            {t("activeTasks")}
          </h2>
          {activeTasks.length === 0 ? (
            <p className="text-sm text-gray-400">{t("noTasks")}</p>
          ) : (
            <ul className="flex flex-col gap-2">
              {activeTasks.slice(0, 10).map((task: TaskBody) => (
                <li
                  key={task.id}
                  className="bg-white rounded-lg border border-gray-200 px-4 py-3 flex items-center gap-3"
                >
                  <Link
                    to="/tasks/$taskId"
                    params={{ taskId: task.id }}
                    className="text-sm flex-1 truncate hover:underline"
                  >
                    {task.title}
                  </Link>
                  <select
                    value={task.status}
                    onChange={(e) =>
                      updateTask.mutate({
                        id: task.id,
                        data: {
                          status: e.target.value as TaskUpdateInputBodyStatus,
                        },
                      })
                    }
                    onClick={(e) => e.stopPropagation()}
                    className={`text-xs px-2 py-0.5 rounded-full border-0 cursor-pointer flex-shrink-0 ${task.status === "in_progress" ? "bg-blue-100 text-blue-700" : "bg-gray-100 text-gray-500"}`}
                  >
                    {STATUS_OPTIONS.map((s) => (
                      <option key={s} value={s}>
                        {tc(`status.${s}`)}
                      </option>
                    ))}
                  </select>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  );
}

function Stat({ label }: { label: string }) {
  return <div className="text-sm text-gray-700 font-medium">{label}</div>;
}

function Landing() {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col items-center justify-center min-h-screen gap-4">
      <h1 className="text-4xl font-semibold tracking-tight">{t("brand")}</h1>
      <p className="text-gray-500">{t("tagline")}</p>
      <div className="flex gap-3 mt-4">
        <Link
          to="/login"
          className="px-4 py-2 rounded-md bg-gray-900 text-white text-sm hover:bg-gray-700 transition-colors"
        >
          {t("signIn")}
        </Link>
        <Link
          to="/register"
          className="px-4 py-2 rounded-md border border-gray-300 text-sm hover:bg-gray-100 transition-colors"
        >
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
