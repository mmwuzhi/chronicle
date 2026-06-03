import { useState, useRef, useEffect, useCallback } from "react";
import { useTranslation } from "react-i18next";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";
import { fmtShortDateTime } from "../utils/format";

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

const PromoteIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={2}
    viewBox="0 0 24 24"
    style={{ flexShrink: 0 }}
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M7.5 21 3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5"
    />
  </svg>
);

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
    <li
      className="ch-row"
      style={{ display: "flex", flexDirection: "column", gap: 12 }}
    >
      {c.mediaType === "image" && c.mediaUrl && (
        <img
          src={c.mediaUrl}
          alt=""
          style={{
            borderRadius: "var(--radius-sm)",
            maxHeight: 160,
            objectFit: "contain",
            width: "100%",
          }}
        />
      )}
      {c.mediaType === "audio" && c.mediaUrl && (
        <audio
          controls
          src={c.mediaUrl}
          style={{ width: "100%", height: 32 }}
        />
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
          style={{
            border: "none",
            outline: "none",
            padding: 0,
            background: "transparent",
            resize: "none",
            fontSize: "var(--fs-sm)",
            width: "100%",
            color: "var(--text)",
          }}
        />
      ) : (
        <p
          style={{
            fontSize: "var(--fs-sm)",
            whiteSpace: "pre-wrap",
            cursor: "text",
            margin: 0,
            color: "var(--text)",
            lineHeight: 1.55,
          }}
          onClick={() => {
            setDraft(c.rawText ?? "");
            setEditing(true);
          }}
        >
          {c.rawText}
        </p>
      )}
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <select
          value={c.classifiedAs}
          onChange={(e) =>
            onReclassify(
              c.id,
              e.target.value as CaptureUpdateInputBodyClassifiedAs,
            )
          }
          className={`ch-pill ${CL_CLASS[c.classifiedAs] ?? "cl-unclassified"}`}
          style={{ border: "none", cursor: "pointer", appearance: "none" }}
        >
          {RECLASSIFY_OPTIONS.map((opt) => (
            <option key={opt} value={opt}>
              {tc(`classification.${opt}`)}
            </option>
          ))}
        </select>
        <span style={{ flex: 1 }} />
        {editing ? (
          <>
            <button className="ch-btn ch-btn-sm" onClick={commitEdit}>
              {tc("actions.save")}
            </button>
            <button
              className="ch-btn ch-btn-ghost ch-btn-sm"
              onClick={() => {
                setDraft(c.rawText ?? "");
                setEditing(false);
              }}
            >
              {tc("actions.cancel")}
            </button>
          </>
        ) : (
          <>
            {c.createdAt && (
              <span className="ch-meta">{fmtShortDateTime(c.createdAt)}</span>
            )}
            {c.classifiedAs === "task" && c.rawText && (
              <button
                className="ch-btn ch-btn-ai ch-btn-sm"
                onClick={() => onPromoteToTask(c.rawText!, c.id)}
                style={{
                  display: "inline-flex",
                  alignItems: "center",
                  gap: 6,
                }}
              >
                <PromoteIcon /> {t("promoteToTask")}
              </button>
            )}
            <DropdownMenu.Root>
              <DropdownMenu.Trigger asChild>
                <button
                  className="ch-iconbtn"
                  style={{ width: 28, height: 28, fontSize: 16 }}
                  aria-label="More options"
                >
                  ···
                </button>
              </DropdownMenu.Trigger>
              <DropdownMenu.Portal>
                <DropdownMenu.Content
                  className="ch-dropdown"
                  align="end"
                  sideOffset={4}
                >
                  <DropdownMenu.Item
                    className="ch-dropdown-item danger"
                    onSelect={() => onDelete(c.id)}
                  >
                    {tc("actions.delete")}
                  </DropdownMenu.Item>
                </DropdownMenu.Content>
              </DropdownMenu.Portal>
            </DropdownMenu.Root>
          </>
        )}
      </div>
    </li>
  );
}
