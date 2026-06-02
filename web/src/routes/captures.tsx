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
  CaptureUpdateInputBodyClassifiedAs,
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

export const Route = createFileRoute("/captures")({
  component: Captures,
});

type Tab = "all" | "unclassified" | "idea" | "task";

const TAB_IDS: Tab[] = ["all", "unclassified", "idea", "task"];

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
  const createTask = useCreateTask({ mutation: { onSuccess: invalidateTasks } });
  const createLogEntry = useCreateLogEntry();
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter((p) => !p.archived);

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("failedToLoad")}</div>;
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

  const handlePolish = async () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setPolishError(false);
    setPolishing(true);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", {
        text: trimmed,
      });
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

  const handleReclassify = (
    id: string,
    classifiedAs: CaptureUpdateInputBodyClassifiedAs,
  ) => {
    update.mutate({ id, data: { classifiedAs } });
  };

  const handleSaveText = (id: string, rawText: string) => {
    apiClient
      .patch(`/captures/${id}`, { rawText })
      .then(() => invalidate())
      .catch(() => invalidate());
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
          if (body) {
            createLogEntry.mutate({ data: { taskId: task.id, body } });
          }
          del.mutate({ id: pendingPromote.captureId }, { onSuccess: invalidate });
          setPendingPromote(null);
        },
      },
    );
  };

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>

        <div className="flex flex-col gap-2">
          <AutoTextarea
            value={polishedText !== null ? polishedText : text}
            onChange={(v) => {
              if (polishedText !== null) setPolishedText(v);
              else setText(v);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                if (polishedText !== null) {
                  const trimmed = polishedText.trim();
                  if (!trimmed) return;
                  create.mutate(
                    {
                      data: {
                        rawText: trimmed,
                        mediaType: "text",
                        classifiedAs: "unclassified",
                      },
                    },
                    {
                      onSuccess: () => {
                        setText("");
                        setPolishedText(null);
                      },
                    },
                  );
                } else {
                  handleAdd();
                }
              }
            }}
            placeholder={t("placeholder")}
            className={`w-full border rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none min-h-[40px] ${polishedText !== null ? "border-purple-300 bg-purple-50 ring-1 ring-purple-200" : "border-gray-300"}`}
          />
          {polishedText !== null && (
            <div className="flex items-center gap-2">
              <span className="text-xs text-purple-600 font-medium">
                ✨ {tc("actions.polishResult")}
              </span>
              <div className="flex gap-2 ml-auto">
                <button
                  onClick={() => {
                    setText(polishedText);
                    setPolishedText(null);
                  }}
                  className="text-xs px-2.5 py-1 rounded-md bg-purple-600 text-white hover:bg-purple-700 transition-colors"
                >
                  {tc("actions.accept")}
                </button>
                <button
                  onClick={() => navigator.clipboard.writeText(polishedText)}
                  className="text-xs px-2.5 py-1 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
                >
                  {tc("actions.copy")}
                </button>
                <button
                  onClick={() => setPolishedText(null)}
                  className="text-xs px-2.5 py-1 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
                >
                  {tc("actions.dismiss")}
                </button>
              </div>
            </div>
          )}
          <div className="flex items-center gap-2">
            <button
              onClick={() => imageInputRef.current?.click()}
              disabled={uploading || recording}
              className="border border-gray-300 rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-50 transition-colors disabled:opacity-50"
              title={t("uploadImage")}
            >
              📎
            </button>
            <button
              onClick={handleAudioToggle}
              disabled={uploading}
              className={`border rounded-md px-3 py-2 text-sm font-medium transition-colors disabled:opacity-50 ${recording ? "border-red-400 bg-red-50 text-red-600 hover:bg-red-100" : "border-gray-300 hover:bg-gray-50"}`}
              title={t("uploadAudio")}
            >
              {recording ? "⏹" : "🎙"}
            </button>
            <button
              onClick={handlePolish}
              disabled={polishing || !text.trim() || polishedText !== null}
              className="border border-gray-300 rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-50 transition-colors disabled:opacity-50"
              title={tc("actions.polish")}
            >
              {polishing ? "…" : "✨"}
            </button>
            <div className="flex-1" />
            {(polishError || uploadError || uploading) && (
              <span className="text-xs text-gray-400">
                {polishError ? (
                  <span className="text-red-500">
                    {tc("errors.polishFailed")}
                  </span>
                ) : uploadError ? (
                  <span className="text-red-500">{t("uploadFailed")}</span>
                ) : recording ? (
                  t("recording")
                ) : (
                  t("transcribing")
                )}
              </span>
            )}
            <button
              onClick={handleAdd}
              disabled={
                create.isPending || !text.trim() || polishedText !== null
              }
              className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
            >
              {tc("actions.save")}
            </button>
          </div>
          <input
            ref={imageInputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={handleImageUpload}
          />
        </div>

        <div className="flex gap-1">
          {TAB_IDS.map((id) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                tab === id
                  ? "bg-gray-900 text-white"
                  : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
              }`}
            >
              {t(`tabs.${id}`)}
            </button>
          ))}
        </div>

        {isLoading ? (
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        ) : (
          <ul className="flex flex-col gap-2">
            {(captures ?? []).map((c: CaptureBody) => (
              <CaptureCard
                key={c.id}
                c={c}
                onReclassify={handleReclassify}
                onDelete={async (id) => {
                  const ok = await confirm({
                    title: "Delete capture?",
                    description: "This cannot be undone.",
                    confirmLabel: "Delete",
                    variant: "danger",
                  });
                  if (ok) del.mutate({ id });
                }}
                onSaveText={handleSaveText}
                onPromoteToTask={handlePromoteToTask}
              />
            ))}
            {(captures ?? []).length === 0 && (
              <p className="text-gray-400 text-sm">{t("nothingHere")}</p>
            )}
          </ul>
        )}
      </div>

      {pendingPromote && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-white rounded-xl border border-gray-200 shadow-lg p-6 w-full max-w-sm flex flex-col gap-4 mx-4">
            <h2 className="text-base font-semibold">{t("promoteDialog.title")}</h2>
            <p className="text-sm text-gray-500 line-clamp-3 whitespace-pre-wrap">
              {pendingPromote.rawText}
            </p>
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-gray-600">
                {t("promoteDialog.project")}
              </label>
              <select
                value={promoteProjectId}
                onChange={(e) => setPromoteProjectId(e.target.value)}
                className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
              >
                <option value="">{tc("noProject")}</option>
                {activeProjects.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex gap-2 justify-end">
              <button
                onClick={() => setPendingPromote(null)}
                className="px-4 py-2 text-sm rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
              >
                {tc("actions.cancel")}
              </button>
              <button
                onClick={handleConfirmPromote}
                disabled={createTask.isPending}
                className="px-4 py-2 text-sm rounded-md bg-gray-900 text-white hover:bg-gray-700 transition-colors disabled:opacity-50"
              >
                {t("promoteDialog.confirm")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
