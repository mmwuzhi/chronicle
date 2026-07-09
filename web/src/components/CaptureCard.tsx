import { useState, useRef, useEffect, useCallback } from "react";
import { useTranslation } from "react-i18next";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useQueryClient } from "@tanstack/react-query";
import {
  useDeleteCaptureAttachment,
  type CaptureAttachmentBody,
  type CaptureBody,
} from "../api";
import { fmtFileSize, fmtListTime, fmtPreciseDateTime } from "../utils/format";
import { patchCaptureInPages } from "../utils/capture-cache";
import { useTranscriptionPoll } from "../hooks/use-transcription-poll";
import { Markdown } from "./Markdown";
import { RemindControl } from "./RemindControl";

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
}): React.JSX.Element {
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
  onDelete,
  onSaveText,
  onSaveTranscript,
  onUseTranscript,
  onRetryTranscription,
  onSetRemind,
  onMutationError,
}: {
  c: CaptureBody;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => void;
  onSaveTranscript: (id: string, transcript: string) => void;
  onUseTranscript: (id: string, mode: "append" | "replace") => void;
  onRetryTranscription: (id: string) => void;
  onSetRemind: (id: string, at: string | null, hide: boolean) => void;
  onMutationError: () => void;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(c.rawText ?? "");
  const [editingTranscript, setEditingTranscript] = useState(false);
  const [transcriptDraft, setTranscriptDraft] = useState(c.transcript ?? "");
  // Both audio and image captures go through the transcription/OCR workflow, so
  // their processing/failed/retry status surfaces the same way.
  const transcribable = c.mediaType === "audio" || c.mediaType === "image";
  useTranscriptionPoll(c);
  // The page listing embeds attachments on every item, so the card reads them
  // directly instead of issuing one GET /captures/{id}/attachments per card.
  const attachments = c.attachments ?? [];
  const deleteAttachment = useDeleteCaptureAttachment({
    mutation: {
      onSuccess: (_data, variables) => {
        patchCaptureInPages(queryClient, {
          ...c,
          attachments: attachments.filter(
            (attachment) => attachment.id !== variables.attachmentId,
          ),
        });
      },
      onError: onMutationError,
    },
  });

  const commitEdit = () => {
    const trimmed = draft.trim();
    if (trimmed && trimmed !== c.rawText) {
      onSaveText(c.id, trimmed);
    }
    setEditing(false);
  };

  const commitTranscript = () => {
    const trimmed = transcriptDraft.trim();
    if (trimmed && trimmed !== c.transcript) {
      onSaveTranscript(c.id, trimmed);
    }
    setEditingTranscript(false);
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
      {transcribable &&
        ["pending", "processing"].includes(c.transcriptionStatus) && (
          <div className="ch-transcript-status">
            {t("transcript.processing")}
          </div>
        )}
      {transcribable && c.transcriptionStatus === "failed" && (
        <div className="ch-transcript-status error">
          <span>{t("transcript.failed")}</span>
          <button
            className="ch-btn ch-btn-sm"
            onClick={() => onRetryTranscription(c.id)}
          >
            {t("transcript.retry")}
          </button>
        </div>
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
        <div
          style={{ cursor: "text" }}
          onClick={() => {
            setDraft(c.rawText ?? "");
            setEditing(true);
          }}
        >
          <Markdown>{c.rawText ?? ""}</Markdown>
        </div>
      )}
      {c.transcript && (
        <div className="ch-transcript">
          <div className="ch-transcript-head">
            <span>{t("transcript.label")}</span>
            {!editingTranscript && (
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => {
                  setTranscriptDraft(c.transcript ?? "");
                  setEditingTranscript(true);
                }}
              >
                {tc("actions.edit")}
              </button>
            )}
          </div>
          {editingTranscript ? (
            <>
              <AutoTextarea
                autoFocus
                value={transcriptDraft}
                onChange={setTranscriptDraft}
                onKeyDown={(event) => {
                  if (event.key === "Escape") setEditingTranscript(false);
                }}
                className="ch-textarea"
              />
              <div className="ch-transcript-actions">
                <button
                  className="ch-btn ch-btn-primary ch-btn-sm"
                  onClick={commitTranscript}
                >
                  {tc("actions.save")}
                </button>
                <button
                  className="ch-btn ch-btn-sm"
                  onClick={() => setEditingTranscript(false)}
                >
                  {tc("actions.cancel")}
                </button>
              </div>
            </>
          ) : (
            <>
              <Markdown>{c.transcript}</Markdown>
              <div className="ch-transcript-actions">
                {c.rawText && (
                  <button
                    className="ch-btn ch-btn-sm"
                    onClick={() => onUseTranscript(c.id, "append")}
                  >
                    {t("transcript.append")}
                  </button>
                )}
                <button
                  className="ch-btn ch-btn-primary ch-btn-sm"
                  onClick={() => onUseTranscript(c.id, "replace")}
                >
                  {c.rawText
                    ? t("transcript.replace")
                    : t("transcript.useAsText")}
                </button>
              </div>
            </>
          )}
        </div>
      )}
      {attachments.length > 0 && (
        <CaptureAttachments
          attachments={attachments}
          deleting={deleteAttachment.isPending}
          onDelete={(attachmentId) =>
            deleteAttachment.mutate({ id: c.id, attachmentId })
          }
        />
      )}
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
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
            <RemindControl
              remindAt={c.remindAt}
              remindHide={c.remindHide}
              onSet={(at, hide) => onSetRemind(c.id, at, hide)}
            />
            {c.createdAt && (
              <span
                className="ch-meta"
                title={fmtPreciseDateTime(c.createdAt, i18n.language)}
              >
                {fmtListTime(c.createdAt, i18n.language)}
              </span>
            )}
            <DropdownMenu.Root>
              <DropdownMenu.Trigger asChild>
                <button
                  className="ch-iconbtn"
                  style={{ width: 28, height: 28 }}
                  aria-label="More options"
                >
                  <svg
                    viewBox="0 0 24 24"
                    fill="currentColor"
                    aria-hidden="true"
                  >
                    <circle cx="5" cy="12" r="1.9" />
                    <circle cx="12" cy="12" r="1.9" />
                    <circle cx="19" cy="12" r="1.9" />
                  </svg>
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

function CaptureAttachments({
  attachments,
  deleting,
  onDelete,
}: {
  attachments: CaptureAttachmentBody[];
  deleting: boolean;
  onDelete: (attachmentId: string) => void;
}): React.JSX.Element {
  const { t } = useTranslation("captures");

  return (
    <div className="ch-attachments">
      <div className="ch-attachments-title">{t("attachments.title")}</div>
      {attachments.map((attachment) => (
        <div className="ch-attachment-row" key={attachment.id}>
          <div className="ch-attachment-file-icon" aria-hidden="true">
            {providerInitial(attachment.provider)}
          </div>
          <div className="ch-attachment-main">
            <a
              className="ch-attachment-name"
              href={attachment.webUrl}
              target="_blank"
              rel="noreferrer"
            >
              {attachment.name}
            </a>
            <span className="ch-meta">
              {providerLabel(attachment.provider)}
              {attachment.sizeBytes != null
                ? ` · ${fmtFileSize(attachment.sizeBytes)}`
                : ""}
            </span>
          </div>
          <a
            className="ch-btn ch-btn-ghost ch-btn-sm"
            href={attachment.webUrl}
            target="_blank"
            rel="noreferrer"
          >
            {t("attachments.open")}
          </a>
          <button
            className="ch-btn ch-btn-danger ch-btn-sm"
            disabled={deleting}
            onClick={() => onDelete(attachment.id)}
          >
            {t("attachments.removeReference")}
          </button>
        </div>
      ))}
    </div>
  );
}

function providerLabel(provider: string): string {
  switch (provider) {
    case "google_drive":
      return "Google Drive";
    case "onedrive":
      return "OneDrive";
    case "dropbox":
      return "Dropbox";
    default:
      return provider;
  }
}

function providerInitial(provider: string): string {
  const label = providerLabel(provider);
  return label.slice(0, 1).toUpperCase();
}
