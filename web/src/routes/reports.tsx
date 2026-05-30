import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { apiClient } from "../lib/axios";
import { Nav } from "../components/nav";
import { fmtDate } from "../utils/format";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/reports")({
  component: Reports,
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

const REPORTS_KEY = ["reports"];

function fmtTime(sec: number) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${h}h ${m}m`;
}

function StatCard({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex flex-col gap-0.5 p-3 bg-gray-50 rounded-lg">
      <span className="text-xs text-gray-500">{label}</span>
      <span className="text-base font-semibold text-gray-900">{value}</span>
    </div>
  );
}

function ReportCard({ report }: { report: ReportBody }) {
  const { t } = useTranslation("reports");
  const qc = useQueryClient();
  const [copied, setCopied] = useState(false);
  const [shareErr, setShareErr] = useState(false);
  const [unshareErr, setUnshareErr] = useState(false);

  const shareMutation = useMutation({
    mutationFn: () =>
      apiClient
        .post<{ slug: string }>(`/reports/${report.id}/share`)
        .then((r) => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => {
      setShareErr(true);
      setTimeout(() => setShareErr(false), 3000);
    },
  });

  const unshareMutation = useMutation({
    mutationFn: () => apiClient.delete(`/reports/${report.id}/share`),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => {
      setUnshareErr(true);
      setTimeout(() => setUnshareErr(false), 3000);
    },
  });

  const copyLink = () => {
    if (!report.shareSlug) return;
    const url = `${window.location.origin}/share/${report.shareSlug}`;
    navigator.clipboard.writeText(url).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  const { stats, tasks, summary } = report.data;

  return (
    <div className="border border-gray-200 rounded-xl p-5 flex flex-col gap-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="font-semibold text-gray-900 text-sm">
          {t("weekOf", { date: fmtDate(report.weekStart) })}
        </h2>
        <div className="flex items-center gap-2">
          {report.shareSlug ? (
            <>
              <button
                onClick={copyLink}
                className="text-xs text-gray-500 hover:text-gray-900 transition-colors"
              >
                {copied ? t("linkCopied") : t("copyLink")}
              </button>
              <button
                onClick={() => unshareMutation.mutate()}
                disabled={unshareMutation.isPending}
                className="text-xs text-red-500 hover:text-red-700 transition-colors disabled:opacity-50"
              >
                {t("unshare")}
              </button>
            </>
          ) : (
            <button
              onClick={() => shareMutation.mutate()}
              disabled={shareMutation.isPending}
              className="text-xs text-blue-600 hover:text-blue-800 transition-colors disabled:opacity-50"
            >
              {t("share")}
            </button>
          )}
        </div>
      </div>

      {(shareErr || unshareErr) && (
        <p className="text-xs text-red-500">
          {shareErr ? t("errors.shareFailed") : t("errors.unshareFailed")}
        </p>
      )}

      <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
        <StatCard label={t("stats.tasksCreated")} value={stats.tasksCreated} />
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
      ) : (
        <p className="text-xs text-gray-400 italic">{t("noSummary")}</p>
      )}

      {tasks.length > 0 && (
        <details className="group">
          <summary className="text-xs font-medium text-gray-500 cursor-pointer select-none hover:text-gray-900 transition-colors">
            {t("tasks")} ({tasks.length})
          </summary>
          <ul className="mt-2 space-y-1">
            {tasks.map((task, i) => (
              <li
                key={i}
                className="flex items-center gap-2 text-xs text-gray-600"
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
                <span className="flex-1 truncate">{task.title}</span>
                {task.projectName && (
                  <span className="text-gray-400">[{task.projectName}]</span>
                )}
                {task.timeSec > 0 && (
                  <span className="text-gray-400 flex-shrink-0">
                    {Math.round(task.timeSec / 60)}m
                  </span>
                )}
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

function Reports() {
  const { t } = useTranslation("reports");
  const { t: tc } = useTranslation("common");
  const qc = useQueryClient();
  const [generateErr, setGenerateErr] = useState(false);

  const {
    data: reports,
    isLoading,
    error,
  } = useQuery({
    queryKey: REPORTS_KEY,
    queryFn: () => apiClient.get<ReportBody[]>("/reports").then((r) => r.data),
  });

  const generateMutation = useMutation({
    mutationFn: () =>
      apiClient.post<ReportBody>("/reports/generate").then((r) => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => {
      setGenerateErr(true);
      setTimeout(() => setGenerateErr(false), 4000);
    },
  });

  if (error) {
    return (
      <div className="min-h-screen bg-white">
        <Nav />
        <div className="max-w-3xl mx-auto px-4 md:px-8 py-12 text-sm text-gray-500">
          {tc("error")}
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-white">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <div className="flex items-center justify-between">
          <h1 className="text-lg font-semibold text-gray-900">{t("title")}</h1>
          <button
            onClick={() => generateMutation.mutate()}
            disabled={generateMutation.isPending}
            className="text-sm bg-gray-900 text-white px-4 py-2 rounded-lg hover:bg-gray-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {generateMutation.isPending ? t("generating") : t("generate")}
          </button>
        </div>

        {generateErr && (
          <p className="text-sm text-red-500">{t("errors.generateFailed")}</p>
        )}

        {isLoading ? (
          <p className="text-sm text-gray-400">{tc("loading")}</p>
        ) : reports && reports.length > 0 ? (
          <div className="flex flex-col gap-4">
            {reports.map((r) => (
              <ReportCard key={r.id} report={r} />
            ))}
          </div>
        ) : (
          <p className="text-sm text-gray-400">{t("noReports")}</p>
        )}
      </div>
    </div>
  );
}
