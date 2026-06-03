import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { apiClient } from "../lib/axios";
import { useConfirm } from "../components/confirm-dialog";
import {
  useListCaptures,
  useCreateCapture,
  useUpdateCapture,
  useDeleteCapture,
  getListCapturesQueryKey,
  useCreateTask,
  useCreateLogEntry,
  useListProjects,
  getListTasksQueryKey,
} from "../api";
import type {
  CaptureBody,
  CaptureCreateInputBodyMediaType,
} from "../api";
import { Nav } from "../components/nav";
import { CaptureCard, AutoTextarea } from "../components/CaptureCard";
import { useTranslation } from "react-i18next";

interface UploadResult {
  mediaUrl: string;
  mediaType: string;
  rawText?: string;
}

export const Route = createFileRoute("/captures")({ component: Captures });

type Tab = "all" | "unclassified" | "idea" | "task";
const TAB_IDS: Tab[] = ["all", "unclassified", "idea", "task"];

const CL_CLASS: Record<Tab, string> = {
  all: "cl-unclassified",
  unclassified: "cl-unclassified",
  idea: "cl-idea",
  task: "cl-task",
};

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [tab, setTab] = useState<Tab>("all");
  const [text, setText] = useState("");
  const [polishedText, setPolishedText] = useState<string | null>(null);
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const [recording, setRecording] = useState(false);
  const [pendingPromote, setPendingPromote] = useState<{ rawText: string; captureId: string } | null>(null);
  const [promoteProjectId, setPromoteProjectId] = useState("");
  const imageInputRef = useRef<HTMLInputElement>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const audioChunksRef = useRef<Blob[]>([]);

  const params = tab === "all" ? undefined : { classifiedAs: tab };
  const { data: captures, error, isLoading } = useListCaptures(params);

  const invalidate = () => queryClient.invalidateQueries({ queryKey: getListCapturesQueryKey() });
  const invalidateTasks = () => queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const create = useCreateCapture({ mutation: { onSuccess: invalidate } });
  const update = useUpdateCapture({ mutation: { onSuccess: invalidate } });
  const del = useDeleteCapture({ mutation: { onSuccess: invalidate } });
  const createTask = useCreateTask({ mutation: { onSuccess: invalidateTasks } });
  const createLogEntry = useCreateLogEntry();
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter((p) => !p.archived);

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) { navigate({ to: "/login" }); return null; }
    return <div style={{ padding: 32, color: "#c2410c" }}>{t("failedToLoad")}</div>;
  }

  const uploadAndCreate = async (file: File | Blob, filename?: string) => {
    setUploadError(false);
    setUploading(true);
    try {
      const fd = new FormData();
      fd.append("file", file, filename ?? (file instanceof File ? file.name : "recording.webm"));
      const res = await apiClient.post<UploadResult>("/captures/upload", fd);
      const { mediaUrl, mediaType, rawText } = res.data;
      if (rawText) setText(rawText);
      create.mutate(
        { data: { mediaUrl, mediaType: mediaType as CaptureCreateInputBodyMediaType, rawText: rawText ?? undefined, classifiedAs: "unclassified" } },
        { onSuccess: () => { if (!rawText) setText(""); } },
      );
    } catch {
      setUploadError(true);
      setTimeout(() => setUploadError(false), 3000);
    } finally {
      setUploading(false);
    }
  };

  const handleImageUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    uploadAndCreate(file);
    e.target.value = "";
  };

  const handleAudioToggle = async () => {
    if (recording) { mediaRecorderRef.current?.stop(); return; }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mr = new MediaRecorder(stream);
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => { audioChunksRef.current.push(e.data); };
      mr.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        setRecording(false);
        const blob = new Blob(audioChunksRef.current, { type: "audio/webm" });
        uploadAndCreate(blob, "recording.webm");
      };
      mr.start();
      mediaRecorderRef.current = mr;
      setRecording(true);
    } catch {
      setUploadError(true);
      setTimeout(() => setUploadError(false), 3000);
    }
  };

  const handlePolish = async () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setPolishError(false);
    setPolishing(true);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", { text: trimmed });
      setPolishedText(res.data.polished);
    } catch {
      setPolishError(true);
      setTimeout(() => setPolishError(false), 3000);
    } finally {
      setPolishing(false);
    }
  };

  const handleAdd = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    create.mutate(
      { data: { rawText: trimmed, mediaType: "text", classifiedAs: "unclassified" } },
      { onSuccess: () => setText("") },
    );
  };

  const handlePromoteToTask = (rawText: string, captureId: string) => {
    setPendingPromote({ rawText, captureId });
    setPromoteProjectId("");
  };

  const handleConfirmPromote = () => {
    if (!pendingPromote) return;
    const lines = pendingPromote.rawText.split("\n");
    const title = lines[0].trim();
    const body = lines.slice(1).join("\n").trim();
    createTask.mutate(
      { data: { title, type: "task", ...(promoteProjectId ? { projectId: promoteProjectId } : {}) } },
      {
        onSuccess: (task) => {
          if (body) createLogEntry.mutate({ data: { taskId: task.id, body } });
          del.mutate({ id: pendingPromote.captureId }, { onSuccess: invalidate });
          setPendingPromote(null);
        },
      },
    );
  };

  const displayText = polishedText !== null ? polishedText : text;

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
        </div>

        {/* Composer */}
        <div className="ch-card" style={{ padding: "var(--pad)", marginBottom: 16 }}>
          <AutoTextarea
            value={displayText}
            onChange={(v) => { if (polishedText !== null) setPolishedText(v); else setText(v); }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                if (polishedText !== null) {
                  const trimmed = polishedText.trim();
                  if (!trimmed) return;
                  create.mutate(
                    { data: { rawText: trimmed, mediaType: "text", classifiedAs: "unclassified" } },
                    { onSuccess: () => { setText(""); setPolishedText(null); } },
                  );
                } else {
                  handleAdd();
                }
              }
            }}
            placeholder={t("placeholder")}
            className="ch-textarea"
            style={{
              border: "none", boxShadow: "none", padding: 0, marginBottom: 10,
              ...(polishedText !== null ? { color: "var(--accent-strong)" } : {}),
            } as React.CSSProperties}
          />

          {polishedText !== null && (
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 10 }}>
              <span style={{ fontSize: "var(--fs-xs)", color: "var(--accent-strong)", fontWeight: 600 }}>
                ✨ {tc("actions.polishResult")}
              </span>
              <div style={{ flex: 1 }} />
              <button
                className="ch-btn ch-btn-ai ch-btn-sm"
                onClick={() => { setText(polishedText); setPolishedText(null); }}
              >
                {tc("actions.accept")}
              </button>
              <button className="ch-btn ch-btn-sm" onClick={() => setPolishedText(null)}>
                {tc("actions.dismiss")}
              </button>
            </div>
          )}

          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <button
              className="ch-btn ch-btn-sm"
              onClick={() => imageInputRef.current?.click()}
              disabled={uploading || recording}
              title={t("uploadImage")}
            >
              📎
            </button>
            <button
              className={`ch-btn ch-btn-sm${recording ? "" : ""}`}
              style={recording ? { borderColor: "#c2410c", color: "#c2410c" } : undefined}
              onClick={handleAudioToggle}
              disabled={uploading}
              title={t("uploadAudio")}
            >
              {recording ? "⏹" : "🎙"}
            </button>
            <button
              className="ch-btn ch-btn-ai ch-btn-sm"
              onClick={handlePolish}
              disabled={polishing || !text.trim() || polishedText !== null}
              title={tc("actions.polish")}
            >
              {polishing ? "…" : "✨"}
            </button>
            <div style={{ flex: 1 }} />
            {(polishError || uploadError) && (
              <span style={{ fontSize: "var(--fs-xs)", color: "#c2410c" }}>
                {polishError ? tc("errors.polishFailed") : t("uploadFailed")}
              </span>
            )}
            {(uploading || recording) && (
              <span className="ch-meta">{recording ? t("recording") : t("transcribing")}</span>
            )}
            <button
              className="ch-btn ch-btn-primary ch-btn-sm"
              onClick={handleAdd}
              disabled={create.isPending || !text.trim() || polishedText !== null}
            >
              {tc("actions.save")}
            </button>
          </div>
          <input ref={imageInputRef} type="file" accept="image/*" style={{ display: "none" }} onChange={handleImageUpload} />
        </div>

        {/* Filter tabs */}
        <div style={{ display: "flex", gap: 6, marginBottom: 16, flexWrap: "wrap" }}>
          {TAB_IDS.map((id) => (
            <button
              key={id}
              className={`ch-pill ${tab === id ? CL_CLASS[id] : "cl-unclassified"}`}
              style={{ cursor: "pointer", border: "none" }}
              onClick={() => setTab(id)}
            >
              {t(`tabs.${id}`)}
            </button>
          ))}
        </div>

        {isLoading ? (
          <p className="ch-meta">{tc("loading")}</p>
        ) : (
          <div className="ch-list">
            {(captures ?? []).length === 0 ? (
              <div className="ch-empty">
                <p>{t("nothingHere")}</p>
              </div>
            ) : (
              (captures ?? []).map((c: CaptureBody) => (
                <CaptureCard
                  key={c.id}
                  c={c}
                  onReclassify={(id, cls) => update.mutate({ id, data: { classifiedAs: cls } })}
                  onDelete={async (id) => {
                    const ok = await confirm({
                      title: tc("confirm.deleteCapture"),
                      description: tc("confirm.cannotUndo"),
                      confirmLabel: tc("actions.delete"),
                      variant: "danger",
                    });
                    if (ok) del.mutate({ id });
                  }}
                  onSaveText={(id, rawText) => {
                    apiClient.patch(`/captures/${id}`, { rawText }).then(() => invalidate()).catch(() => invalidate());
                  }}
                  onPromoteToTask={handlePromoteToTask}
                />
              ))
            )}
          </div>
        )}
      </div>

      {/* Promote dialog */}
      {pendingPromote && (
        <div style={{ position: "fixed", inset: 0, zIndex: 50, display: "flex", alignItems: "center", justifyContent: "center", background: "color-mix(in srgb, var(--text) 22%, transparent)" }}>
          <div className="ch-card" style={{ padding: 24, width: "calc(100% - 32px)", maxWidth: 360, display: "flex", flexDirection: "column", gap: 16 }}>
            <h2 style={{ margin: 0, fontFamily: "var(--font-display)", fontSize: 16, fontWeight: 700 }}>{t("promoteDialog.title")}</h2>
            <p style={{ margin: 0, fontSize: "var(--fs-sm)", color: "var(--text-muted)", whiteSpace: "pre-wrap" }}>{pendingPromote.rawText}</p>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <label style={{ fontSize: "var(--fs-xs)", fontWeight: 600, color: "var(--text-muted)" }}>{t("promoteDialog.project")}</label>
              <select
                value={promoteProjectId}
                onChange={(e) => setPromoteProjectId(e.target.value)}
                className="ch-input"
                style={{ padding: "8px 12px", fontSize: "var(--fs-sm)" }}
              >
                <option value="">{tc("noProject")}</option>
                {activeProjects.map((p) => (
                  <option key={p.id} value={p.id}>{p.name}</option>
                ))}
              </select>
            </div>
            <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
              <button className="ch-btn ch-btn-sm" onClick={() => setPendingPromote(null)}>{tc("actions.cancel")}</button>
              <button className="ch-btn ch-btn-primary ch-btn-sm" onClick={handleConfirmPromote} disabled={createTask.isPending}>
                {t("promoteDialog.confirm")}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
