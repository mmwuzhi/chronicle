import { useState, useRef, useEffect, useCallback } from "react";
import { useTranslation } from "react-i18next";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";

const CL_CLASS: Record<string, string> = {
  unclassified: "cl-unclassified",
  idea: "cl-idea",
  task: "cl-task",
  routine: "cl-routine",
  log: "cl-log",
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
  style,
  autoFocus,
}: {
  value: string;
  onChange: (v: string) => void;
  onKeyDown?: React.KeyboardEventHandler<HTMLTextAreaElement>;
  onBlur?: React.FocusEventHandler<HTMLTextAreaElement>;
  placeholder?: string;
  className?: string;
  style?: React.CSSProperties;
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
      style={{ overflow: "hidden", ...style }}
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
  onPromoteToTask: (rawText: string, captureId: string) => void;
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
    <li className="ch-row" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      {c.mediaType === "image" && c.mediaUrl && (
        <img src={c.mediaUrl} alt="" style={{ borderRadius: "var(--radius-sm)", maxHeight: 160, objectFit: "contain", width: "100%" }} />
      )}
      {c.mediaType === "audio" && c.mediaUrl && (
        <audio controls src={c.mediaUrl} style={{ width: "100%", height: 32 }} />
      )}
      {editing ? (
        <AutoTextarea
          autoFocus
          value={draft}
          onChange={setDraft}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); commitEdit(); }
            if (e.key === "Escape") { setDraft(c.rawText ?? ""); setEditing(false); }
          }}
          onBlur={commitEdit}
          style={{ border: "none", outline: "none", padding: 0, background: "transparent", resize: "none", fontSize: "var(--fs-sm)", width: "100%", color: "var(--text)" }}
        />
      ) : (
        <p
          style={{ fontSize: "var(--fs-sm)", whiteSpace: "pre-wrap", cursor: "text", margin: 0, color: "var(--text)", lineHeight: 1.55 }}
          onClick={() => { setDraft(c.rawText ?? ""); setEditing(true); }}
        >
          {c.rawText}
        </p>
      )}
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <select
          value={c.classifiedAs}
          onChange={(e) => onReclassify(c.id, e.target.value as CaptureUpdateInputBodyClassifiedAs)}
          className={`ch-pill ${CL_CLASS[c.classifiedAs] ?? "cl-unclassified"}`}
          style={{ border: "none", cursor: "pointer", appearance: "none" }}
        >
          {RECLASSIFY_OPTIONS.map((opt) => (
            <option key={opt} value={opt}>{tc(`classification.${opt}`)}</option>
          ))}
        </select>
        <span style={{ flex: 1 }} />
        {editing ? (
          <>
            <button className="ch-btn ch-btn-sm" onClick={commitEdit}>{tc("actions.save")}</button>
            <button className="ch-btn ch-btn-ghost ch-btn-sm" onClick={() => { setDraft(c.rawText ?? ""); setEditing(false); }}>{tc("actions.cancel")}</button>
          </>
        ) : (
          <>
            {c.createdAt && <span className="ch-meta">{fmtDateTime(c.createdAt)}</span>}
            {c.classifiedAs === "task" && c.rawText && (
              <button className="ch-btn ch-btn-ai ch-btn-sm" onClick={() => onPromoteToTask(c.rawText!, c.id)}>
                {t("promoteToTask")}
              </button>
            )}
            <button className="ch-btn ch-btn-danger ch-btn-sm" onClick={() => onDelete(c.id)}>
              {tc("actions.delete")}
            </button>
          </>
        )}
      </div>
    </li>
  );
}
