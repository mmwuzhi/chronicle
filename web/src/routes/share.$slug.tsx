import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { apiClient } from "../lib/axios";

export const Route = createFileRoute("/share/$slug")({
  component: SharedReport,
});

interface ReportStats {
  tasksCreated: number;
  tasksDone: number;
  totalTimeSec: number;
  capturesCreated: number;
  logEntriesWritten: number;
}

interface TaskSummary {
  title: string;
  status: string;
  projectName: string;
  timeSec: number;
}

interface ReportData {
  summary: string;
  stats: ReportStats;
  tasks: TaskSummary[];
}

interface ReportBody {
  id: string;
  weekStart: string;
  data: ReportData;
  shareSlug: string | null;
  createdAt: string;
}

function fmtTime(sec: number) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${h}h ${m}m`;
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, {
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

function StatCard({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex flex-col gap-0.5 p-3 bg-gray-50 rounded-lg">
      <span className="text-xs text-gray-500">{label}</span>
      <span className="text-base font-semibold text-gray-900">{value}</span>
    </div>
  );
}

function SharedReport() {
  const { slug } = Route.useParams();
  const { t } = useTranslation("reports");
  const { t: tc } = useTranslation("common");

  const {
    data: report,
    isLoading,
    error,
  } = useQuery({
    queryKey: ["share", slug],
    queryFn: () =>
      apiClient.get<ReportBody>(`/share/${slug}`).then((r) => r.data),
  });

  if (isLoading) {
    return (
      <div className="min-h-screen bg-white flex items-center justify-center text-sm text-gray-400">
        {tc("loading")}
      </div>
    );
  }

  if (error || !report) {
    return (
      <div className="min-h-screen bg-white flex items-center justify-center text-sm text-gray-400">
        {tc("error")}
      </div>
    );
  }

  const { stats, tasks, summary } = report.data;

  return (
    <div className="min-h-screen bg-white">
      <div className="max-w-2xl mx-auto px-6 py-12 flex flex-col gap-6">
        <div className="flex flex-col gap-1">
          <p className="text-xs font-medium text-gray-400 uppercase tracking-wide">
            {tc("brand")}
          </p>
          <h1 className="text-xl font-semibold text-gray-900">
            {t("weekOf", { date: fmtDate(report.weekStart) })}
          </h1>
        </div>

        <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
          <StatCard
            label={t("stats.tasksCreated")}
            value={stats.tasksCreated}
          />
          <StatCard label={t("stats.tasksDone")} value={stats.tasksDone} />
          <StatCard
            label={t("stats.timeTracked")}
            value={fmtTime(stats.totalTimeSec)}
          />
          <StatCard label={t("stats.captures")} value={stats.capturesCreated} />
          <StatCard
            label={t("stats.logEntries")}
            value={stats.logEntriesWritten}
          />
        </div>

        {summary ? (
          <div className="text-sm text-gray-700 leading-relaxed whitespace-pre-line">
            {summary}
          </div>
        ) : null}

        {tasks.length > 0 && (
          <div className="flex flex-col gap-2">
            <h2 className="text-xs font-medium text-gray-500 uppercase tracking-wide">
              {t("tasks")} ({tasks.length})
            </h2>
            <ul className="space-y-1.5">
              {tasks.map((task, i) => (
                <li
                  key={i}
                  className="flex items-center gap-2 text-sm text-gray-700"
                >
                  <span
                    className={`inline-block w-1.5 h-1.5 rounded-full flex-shrink-0 ${
                      task.status === "done"
                        ? "bg-green-500"
                        : task.status === "in_progress"
                          ? "bg-blue-500"
                          : "bg-gray-300"
                    }`}
                  />
                  <span className="flex-1">{task.title}</span>
                  {task.projectName && (
                    <span className="text-gray-400 text-xs">
                      [{task.projectName}]
                    </span>
                  )}
                  {task.timeSec > 0 && (
                    <span className="text-gray-400 text-xs flex-shrink-0">
                      {Math.round(task.timeSec / 60)}m
                    </span>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )}

        <p className="text-xs text-gray-400 pt-4 border-t border-gray-100">
          {tc("brand")} · {tc("tagline")}
        </p>
      </div>
    </div>
  );
}
