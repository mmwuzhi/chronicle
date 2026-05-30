import { useState, useRef, useEffect, useCallback } from "react";
import { useTranslation } from "react-i18next";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";

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

function fmtDateTime(iso: string) {
  const d = new Date(iso);
  return (
    d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) +
    " " +
    d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
  );
}

export function AutoTextarea({
  value,
  onChange,
  onKeyDown,
  onBlur,
  placeholder,
  className,
  autoFocus,
}: {
  value: string;
  onChange: (v: string) => void;
  onKeyDown?: React.KeyboardEventHandler<HTMLTextAreaElement>;
  onBlur?: React.FocusEventHandler<HTMLTextAreaElement>;
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
      onChange={(e) => {
        onChange(e.target.value);
        resize();
      }}
      onKeyDown={onKeyDown}
      onBlur={onBlur}
      placeholder={placeholder}
      rows={1}
      className={className}
      style={{ overflow: "hidden" }}
    />
  );
}

export function CaptureCard({
  c,
  onReclassify,
  onDelete,
  onSaveText,
  onPromoteToTask,
}: {
  c: CaptureBody;
  onReclassify: (id: string, v: CaptureUpdateInputBodyClassifiedAs) => void;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => void;
  onPromoteToTask: (rawText: string) => void;
}) {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(c.rawText ?? "");

  const commitEdit = () => {
    const trimmed = draft.trim();
    if (trimmed && trimmed !== c.rawText) {
      onSaveText(c.id, trimmed);
    }
    setEditing(false);
  };

  return (
    <li className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex flex-col gap-3">
      {c.mediaType === "image" && c.mediaUrl && (
        <img
          src={c.mediaUrl}
          alt=""
          className="rounded-md max-h-48 object-contain w-full"
        />
      )}
      {c.mediaType === "audio" && c.mediaUrl && (
        <audio controls src={c.mediaUrl} className="w-full h-8" />
      )}
      {editing ? (
        <AutoTextarea
          autoFocus
          value={draft}
          onChange={setDraft}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              commitEdit();
            }
            if (e.key === "Escape") {
              setDraft(c.rawText ?? "");
              setEditing(false);
            }
          }}
          onBlur={commitEdit}
          className="text-sm w-full border-0 p-0 focus:outline-none resize-none bg-transparent"
        />
      ) : (
        <p
          className="text-sm whitespace-pre-wrap cursor-text"
          onClick={() => {
            setDraft(c.rawText ?? "");
            setEditing(true);
          }}
        >
          {c.rawText}
        </p>
      )}
      <div className="flex items-center gap-2">
        <select
          value={c.classifiedAs}
          onChange={(e) =>
            onReclassify(
              c.id,
              e.target.value as CaptureUpdateInputBodyClassifiedAs,
            )
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
              onClick={() => {
                setDraft(c.rawText ?? "");
                setEditing(false);
              }}
              className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
            >
              {tc("actions.cancel")}
            </button>
          </>
        ) : (
          <>
            {c.createdAt && (
              <span className="text-xs text-gray-400">
                {fmtDateTime(c.createdAt)}
              </span>
            )}
            {c.classifiedAs === "task" && c.rawText && (
              <button
                onClick={() => onPromoteToTask(c.rawText!)}
                className="text-xs text-blue-600 hover:text-blue-800 font-medium transition-colors"
              >
                {t("promoteToTask")}
              </button>
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
