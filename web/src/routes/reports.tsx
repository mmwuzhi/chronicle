import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { apiClient } from "../lib/axios";
import { Nav } from "../components/nav";
import { fmtDate } from "../utils/format";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/reports")({ component: Reports });

interface ReportStats {
  tasksCreated: number;
  tasksDone: number;
  totalTimeSec: number;
  capturesCreated: number;
  logEntriesWritten: number;
}
interface TaskSummary { title: string; status: string; projectName: string; timeSec: number; }
interface ReportData { summary: string; stats: ReportStats; tasks: TaskSummary[]; }
interface ReportBody { id: string; weekStart: string; data: ReportData; shareSlug: string | null; createdAt: string; }

const REPORTS_KEY = ["reports"];
function fmtTime(sec: number) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${h}h ${m}m`;
}

function ReportCard({ report }: { report: ReportBody }) {
  const { t } = useTranslation("reports");
  const qc = useQueryClient();
  const [copied, setCopied] = useState(false);
  const [shareErr, setShareErr] = useState(false);
  const [unshareErr, setUnshareErr] = useState(false);

  const shareMutation = useMutation({
    mutationFn: () => apiClient.post<{ slug: string }>(`/reports/${report.id}/share`).then((r) => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => { setShareErr(true); setTimeout(() => setShareErr(false), 3000); },
  });
  const unshareMutation = useMutation({
    mutationFn: () => apiClient.delete(`/reports/${report.id}/share`),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => { setUnshareErr(true); setTimeout(() => setUnshareErr(false), 3000); },
  });

  const copyLink = () => {
    if (!report.shareSlug) return;
    navigator.clipboard.writeText(`${window.location.origin}/share/${report.shareSlug}`).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  const { stats, tasks, summary } = report.data;

  const statItems = [
    { label: t("stats.tasksCreated"), value: stats.tasksCreated },
    { label: t("stats.tasksDone"), value: stats.tasksDone },
    { label: t("stats.timeTracked"), value: fmtTime(stats.totalTimeSec) },
    { label: t("stats.captures"), value: stats.capturesCreated },
    { label: t("stats.logEntries"), value: stats.logEntriesWritten },
  ];

  return (
    <div className="ch-card" style={{ padding: "var(--pad)", display: "flex", flexDirection: "column", gap: 14 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
        <span style={{ fontFamily: "var(--font-display)", fontSize: "var(--fs-sm)", fontWeight: 600 }}>
          {t("weekOf", { date: fmtDate(report.weekStart) })}
        </span>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          {(shareErr || unshareErr) && (
            <span style={{ fontSize: "var(--fs-xs)", color: "#c2410c" }}>
              {shareErr ? t("errors.shareFailed") : t("errors.unshareFailed")}
            </span>
          )}
          {report.shareSlug ? (
            <>
              <button className="ch-btn ch-btn-ghost ch-btn-sm" onClick={copyLink}>
                {copied ? t("linkCopied") : t("copyLink")}
              </button>
              <button className="ch-btn ch-btn-danger ch-btn-sm" onClick={() => unshareMutation.mutate()} disabled={unshareMutation.isPending}>
                {t("unshare")}
              </button>
            </>
          ) : (
            <button className="ch-btn ch-btn-sm" onClick={() => shareMutation.mutate()} disabled={shareMutation.isPending}>
              {t("share")}
            </button>
          )}
        </div>
      </div>

      {/* Stats grid */}
      <div style={{
        display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(90px, 1fr))", gap: 8,
        background: "var(--surface-2)", borderRadius: "var(--radius-sm)", padding: "var(--gap)",
      }}>
        {statItems.map((s, i) => (
          <div key={i} style={{ display: "flex", flexDirection: "column", gap: 3 }}>
            <span style={{ fontSize: "var(--fs-xs)", color: "var(--text-faint)" }}>{s.label}</span>
            <span style={{ fontFamily: "var(--font-mono)", fontSize: 15, fontWeight: 700, color: "var(--text)" }}>{s.value}</span>
          </div>
        ))}
      </div>

      {summary ? (
        <p style={{ fontSize: "var(--fs-sm)", lineHeight: 1.6, color: "var(--text)", margin: 0, whiteSpace: "pre-line" }}>
          {summary}
        </p>
      ) : (
        <p style={{ fontSize: "var(--fs-xs)", color: "var(--text-faint)", fontStyle: "italic", margin: 0 }}>
          {t("noSummary")}
        </p>
      )}

      {tasks.length > 0 && (
        <details>
          <summary style={{ fontSize: "var(--fs-xs)", fontWeight: 600, color: "var(--text-muted)", cursor: "pointer" }}>
            {t("tasks")} ({tasks.length})
          </summary>
          <ul style={{ margin: "8px 0 0", padding: 0, listStyle: "none", display: "flex", flexDirection: "column", gap: 4 }}>
            {tasks.map((task, i) => (
              <li key={i} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: "var(--fs-xs)", color: "var(--text-muted)" }}>
                <span style={{
                  width: 6, height: 6, borderRadius: "50%", flexShrink: 0,
                  background: task.status === "done" ? "var(--accent)" : task.status === "in_progress" ? "#60a5fa" : "var(--text-faint)",
                }} />
                <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{task.title}</span>
                {task.projectName && <span style={{ color: "var(--text-faint)" }}>[{task.projectName}]</span>}
                {task.timeSec > 0 && <span style={{ color: "var(--text-faint)", flexShrink: 0 }}>{Math.round(task.timeSec / 60)}m</span>}
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

  const { data: reports, isLoading, error } = useQuery({
    queryKey: REPORTS_KEY,
    queryFn: () => apiClient.get<ReportBody[]>("/reports").then((r) => r.data),
  });

  const generateMutation = useMutation({
    mutationFn: () => apiClient.post<ReportBody>("/reports/generate").then((r) => r.data),
    onSuccess: () => qc.invalidateQueries({ queryKey: REPORTS_KEY }),
    onError: () => { setGenerateErr(true); setTimeout(() => setGenerateErr(false), 4000); },
  });

  if (error) {
    return (
      <>
        <Nav />
        <div style={{ maxWidth: 768, margin: "0 auto", padding: "24px 18px", fontSize: "var(--fs-sm)", color: "var(--text-muted)" }}>
          {tc("error")}
        </div>
      </>
    );
  }

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <h1 className="ch-title">{t("title")}</h1>
            <button
              className="ch-btn ch-btn-primary ch-btn-sm"
              onClick={() => generateMutation.mutate()}
              disabled={generateMutation.isPending}
            >
              {generateMutation.isPending ? t("generating") : t("generate")}
            </button>
          </div>
        </div>

        {generateErr && <p style={{ fontSize: "var(--fs-sm)", color: "#c2410c", marginBottom: 16 }}>{t("errors.generateFailed")}</p>}

        {isLoading ? (
          <p className="ch-meta">{tc("loading")}</p>
        ) : reports && reports.length > 0 ? (
          <div className="ch-list">
            {reports.map((r) => <ReportCard key={r.id} report={r} />)}
          </div>
        ) : (
          <div className="ch-empty">
            <p>{t("noReports")}</p>
          </div>
        )}
      </div>
    </>
  );
}
