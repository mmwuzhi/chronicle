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
import type { CaptureBody, CaptureCreateInputBodyMediaType } from "../api";
import { Nav } from "../components/nav";
import { CaptureCard } from "../components/CaptureCard";
import { Composer } from "../components/Composer";
import { Markdown } from "../components/Markdown";
import { useTranslation } from "react-i18next";

interface UploadResult {
  mediaUrl: string;
  mediaType: string;
  rawText?: string;
}

export const Route = createFileRoute("/captures")({ component: Captures });

type Tab = "all" | "unclassified" | "idea" | "task" | "routine" | "log";
const TAB_IDS: Tab[] = [
  "all",
  "unclassified",
  "idea",
  "task",
  "routine",
  "log",
];

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [tab, setTab] = useState<Tab>("all");
  const [text, setText] = useState("");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const [recording, setRecording] = useState(false);
  const [pendingPromote, setPendingPromote] = useState<{
    rawText: string;
    captureId: string;
  } | null>(null);
  const [promoteProjectId, setPromoteProjectId] = useState("");
  const imageInputRef = useRef<HTMLInputElement>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const audioChunksRef = useRef<Blob[]>([]);

  const params = tab === "all" ? undefined : { classifiedAs: tab };
  const { data: captures, error, isLoading } = useListCaptures(params);

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListCapturesQueryKey() });
  const invalidateTasks = () =>
    queryClient.invalidateQueries({ queryKey: getListTasksQueryKey() });

  const create = useCreateCapture({ mutation: { onSuccess: invalidate } });
  const update = useUpdateCapture({ mutation: { onSuccess: invalidate } });
  const del = useDeleteCapture({ mutation: { onSuccess: invalidate } });
  const createTask = useCreateTask({
    mutation: { onSuccess: invalidateTasks },
  });
  const createLogEntry = useCreateLogEntry();
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter((p) => !p.archived);

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

  const uploadAndCreate = async (file: File | Blob, filename?: string) => {
    setUploadError(false);
    setUploading(true);
    try {
      const fd = new FormData();
      fd.append(
        "file",
        file,
        filename ?? (file instanceof File ? file.name : "recording.webm"),
      );
      const res = await apiClient.post<UploadResult>("/captures/upload", fd);
      const { mediaUrl, mediaType, rawText } = res.data;
      if (rawText) setText(rawText);
      create.mutate(
        {
          data: {
            mediaUrl,
            mediaType: mediaType as CaptureCreateInputBodyMediaType,
            rawText: rawText ?? undefined,
            classifiedAs: "unclassified",
          },
        },
        {
          onSuccess: () => {
            if (!rawText) setText("");
          },
        },
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
    if (recording) {
      mediaRecorderRef.current?.stop();
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mr = new MediaRecorder(stream);
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => {
        audioChunksRef.current.push(e.data);
      };
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

  const handlePolish = async (value: string) => {
    const trimmed = value.trim();
    const res = await apiClient.post<{ polished: string }>("/ai/polish", {
      text: trimmed,
    });
    return res.data.polished;
  };

  const handleAdd = (value = text) => {
    const trimmed = value.trim();
    if (!trimmed) return;
    create.mutate(
      {
        data: {
          rawText: trimmed,
          mediaType: "text",
          classifiedAs: "unclassified",
        },
      },
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
      {
        data: {
          title,
          type: "task",
          ...(promoteProjectId ? { projectId: promoteProjectId } : {}),
        },
      },
      {
        onSuccess: (task) => {
          if (body) createLogEntry.mutate({ data: { taskId: task.id, body } });
          del.mutate(
            { id: pendingPromote.captureId },
            { onSuccess: invalidate },
          );
          setPendingPromote(null);
        },
      },
    );
  };

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("title")}</h1>
          <p
            style={{
              margin: "4px 0 0",
              fontSize: "var(--fs-sm)",
              color: "var(--text-muted)",
            }}
          >
            {t("subtitle")}
          </p>
        </div>

        <Composer
          value={text}
          onChange={setText}
          onSubmit={handleAdd}
          placeholder={t("placeholder")}
          submitLabel={tc("actions.save")}
          submitDisabled={create.isPending}
          onPolish={handlePolish}
          onAttach={() => imageInputRef.current?.click()}
          onRecord={handleAudioToggle}
          attachLabel={t("attach")}
          recordLabel={t("record")}
          recording={recording}
          busy={uploading || recording}
          busyLabel={recording ? t("recording") : t("transcribing")}
          error={uploadError ? t("uploadFailed") : null}
          attachmentInput={
            <input
              ref={imageInputRef}
              type="file"
              accept="image/*"
              style={{ display: "none" }}
              onChange={handleImageUpload}
            />
          }
        />

        {/* Filter tabs */}
        <div
          style={{
            display: "flex",
            gap: 6,
            marginBottom: 16,
            flexWrap: "wrap",
          }}
        >
          {TAB_IDS.map((id) => (
            <button
              key={id}
              className={`ch-navlink${tab === id ? " active" : ""}`}
              style={{ cursor: "pointer" }}
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
                  onReclassify={(id, cls) =>
                    update.mutate({ id, data: { classifiedAs: cls } })
                  }
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
                    apiClient
                      .patch(`/captures/${id}`, { rawText })
                      .then(() => invalidate())
                      .catch(() => invalidate());
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
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 50,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "color-mix(in srgb, var(--text) 22%, transparent)",
          }}
        >
          <div
            className="ch-card"
            style={{
              padding: 24,
              width: "calc(100% - 32px)",
              maxWidth: 360,
              display: "flex",
              flexDirection: "column",
              gap: 16,
            }}
          >
            <h2
              style={{
                margin: 0,
                fontFamily: "var(--font-display)",
                fontSize: 16,
                fontWeight: 700,
              }}
            >
              {t("promoteDialog.title")}
            </h2>
            <div style={{ color: "var(--text-muted)" }}>
              <Markdown>{pendingPromote.rawText}</Markdown>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <label
                style={{
                  fontSize: "var(--fs-xs)",
                  fontWeight: 600,
                  color: "var(--text-muted)",
                }}
              >
                {t("promoteDialog.project")}
              </label>
              <select
                value={promoteProjectId}
                onChange={(e) => setPromoteProjectId(e.target.value)}
                className="ch-input"
                style={{ padding: "8px 12px", fontSize: "var(--fs-sm)" }}
              >
                <option value="">{tc("noProject")}</option>
                {activeProjects.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </div>
            <div
              style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}
            >
              <button
                className="ch-btn ch-btn-sm"
                onClick={() => setPendingPromote(null)}
              >
                {tc("actions.cancel")}
              </button>
              <button
                className="ch-btn ch-btn-primary ch-btn-sm"
                onClick={handleConfirmPromote}
                disabled={createTask.isPending}
              >
                {t("promoteDialog.confirm")}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
