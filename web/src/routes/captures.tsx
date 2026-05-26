import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, useRef, useEffect, useCallback } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { apiClient } from "../lib/axios";
import {
  useListCaptures,
  useCreateCapture,
  useUpdateCapture,
  useDeleteCapture,
  getListCapturesQueryKey,
} from "../api";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";
import { Nav } from "../components/nav";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/captures")({
  component: Captures,
});

type Tab = "all" | "unclassified" | "idea" | "task";

const TAB_IDS: Tab[] = ["all", "unclassified", "idea", "task"];

const CLASS_COLORS: Record<string, string> = {
  unclassified: "bg-gray-100 text-gray-500",
  idea: "bg-purple-100 text-purple-700",
  task: "bg-blue-100 text-blue-700",
  routine: "bg-green-100 text-green-700",
  log: "bg-yellow-100 text-yellow-700",
};

const RECLASSIFY_OPTIONS: CaptureUpdateInputBodyClassifiedAs[] = [
  "unclassified",
  "idea",
  "task",
  "routine",
  "log",
];

function fmtDate(iso: string) {
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) +
    " " +
    d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

function AutoTextarea({
  value,
  onChange,
  onKeyDown,
  placeholder,
  className,
  autoFocus,
}: {
  value: string;
  onChange: (v: string) => void;
  onKeyDown?: React.KeyboardEventHandler<HTMLTextAreaElement>;
  placeholder?: string;
  className?: string;
  autoFocus?: boolean;
}) {
  const ref = useRef<HTMLTextAreaElement>(null);

  const resize = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = el.scrollHeight + "px";
  }, []);

  useEffect(() => {
    resize();
  }, [value, resize]);

  return (
    <textarea
      ref={ref}
      value={value}
      autoFocus={autoFocus}
      onChange={(e) => { onChange(e.target.value); resize(); }}
      onKeyDown={onKeyDown}
      placeholder={placeholder}
      rows={1}
      className={className}
      style={{ overflow: "hidden" }}
    />
  );
}

function CaptureCard({
  c,
  onReclassify,
  onDelete,
  onSaveText,
}: {
  c: CaptureBody;
  onReclassify: (id: string, v: CaptureUpdateInputBodyClassifiedAs) => void;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => void;
}) {
  const { t: tc } = useTranslation("common");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(c.rawText ?? "");

  useEffect(() => {
    if (!editing) setDraft(c.rawText ?? "");
  }, [c.rawText, editing]);

  const commitEdit = () => {
    const trimmed = draft.trim();
    if (trimmed && trimmed !== c.rawText) {
      onSaveText(c.id, trimmed);
    }
    setEditing(false);
  };

  return (
    <li className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex flex-col gap-3">
      {editing ? (
        <AutoTextarea
          autoFocus
          value={draft}
          onChange={setDraft}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); commitEdit(); }
            if (e.key === "Escape") { setDraft(c.rawText ?? ""); setEditing(false); }
          }}
          className="text-sm w-full border-0 p-0 focus:outline-none resize-none bg-transparent"
        />
      ) : (
        <p
          className="text-sm whitespace-pre-wrap cursor-text"
          onClick={() => { setDraft(c.rawText ?? ""); setEditing(true); }}
        >
          {c.rawText}
        </p>
      )}
      <div className="flex items-center gap-2">
        <select
          value={c.classifiedAs}
          onChange={(e) =>
            onReclassify(c.id, e.target.value as CaptureUpdateInputBodyClassifiedAs)
          }
          className={`text-xs font-medium px-2 py-1 rounded-full border-0 cursor-pointer ${CLASS_COLORS[c.classifiedAs] ?? "bg-gray-100 text-gray-500"}`}
        >
          {RECLASSIFY_OPTIONS.map((opt) => (
            <option key={opt} value={opt}>
              {tc(`classification.${opt}`)}
            </option>
          ))}
        </select>
        <span className="flex-1" />
        {editing ? (
          <>
            <button
              onClick={commitEdit}
              className="text-xs text-gray-700 hover:text-gray-900 font-medium transition-colors"
            >
              {tc("actions.save")}
            </button>
            <button
              onClick={() => { setDraft(c.rawText ?? ""); setEditing(false); }}
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.cancel")}
            </button>
          </>
        ) : (
          <>
            {c.createdAt && (
              <span className="text-xs text-gray-400">{fmtDate(c.createdAt)}</span>
            )}
            <button
              onClick={() => onDelete(c.id)}
              className="text-xs text-gray-400 hover:text-red-500 transition-colors"
            >
              {tc("actions.delete")}
            </button>
          </>
        )}
      </div>
    </li>
  );
}

function Captures() {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [tab, setTab] = useState<Tab>("all");
  const [text, setText] = useState("");
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);

  const params = tab === "all" ? undefined : { classifiedAs: tab };
  const { data: captures, error, isLoading } = useListCaptures(params);

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListCapturesQueryKey() });

  const create = useCreateCapture({ mutation: { onSuccess: invalidate } });
  const update = useUpdateCapture({ mutation: { onSuccess: invalidate } });
  const del = useDeleteCapture({ mutation: { onSuccess: invalidate } });

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("failedToLoad")}</div>;
  }

  const handlePolish = async () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setPolishError(false);
    setPolishing(true);
    try {
      const res = await apiClient.post<{ polished: string }>("/ai/polish", { text: trimmed });
      setText(res.data.polished);
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

  const handleReclassify = (id: string, classifiedAs: CaptureUpdateInputBodyClassifiedAs) => {
    update.mutate({ id, data: { classifiedAs } });
  };

  const handleSaveText = (id: string, rawText: string) => {
    apiClient
      .patch(`/captures/${id}`, { rawText })
      .then(() => invalidate())
      .catch(() => invalidate());
  };

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-6">
        <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>

        <div className="flex gap-2 items-end">
          <AutoTextarea
            value={text}
            onChange={setText}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                handleAdd();
              }
            }}
            placeholder={t("placeholder")}
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none min-h-[40px]"
          />
          <div className="flex flex-col gap-1 items-end flex-shrink-0">
            <div className="flex gap-2">
              <button
                onClick={handlePolish}
                disabled={polishing || !text.trim()}
                className="border border-gray-300 rounded-md px-3 py-2 text-sm font-medium hover:bg-gray-50 transition-colors disabled:opacity-50"
                title={tc("actions.polish")}
              >
                {polishing ? "…" : "✨"}
              </button>
              <button
                onClick={handleAdd}
                disabled={create.isPending || !text.trim()}
                className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
              >
                {tc("actions.save")}
              </button>
            </div>
            {polishError && (
              <p className="text-xs text-red-500">{tc("errors.polishFailed")}</p>
            )}
          </div>
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
                onDelete={(id) => del.mutate({ id })}
                onSaveText={handleSaveText}
              />
            ))}
            {(captures ?? []).length === 0 && (
              <p className="text-gray-400 text-sm">{t("nothingHere")}</p>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}
