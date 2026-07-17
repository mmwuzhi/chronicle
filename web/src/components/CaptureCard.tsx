import { useState, useRef, useEffect, useCallback, memo } from "react";
import { useTranslation } from "react-i18next";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useQueryClient } from "@tanstack/react-query";
import {
  useDeleteCaptureAttachment,
  type CaptureAttachmentBody,
  type CaptureBody,
} from "@/api";
import { fmtFileSize, fmtListTime, fmtPreciseDateTime } from "@/utils/format";
import { patchCaptureInPages } from "@/utils/capture-cache";
import { useTranscriptionPoll } from "@/hooks/use-transcription-poll";
import { Markdown } from "@/components/Markdown";
import { RemindControl } from "@/components/RemindControl";
import { cn } from "@/lib/cn";
import { Button, buttonClassName } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Meta } from "@/components/ui/page";

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
      className={cn("overflow-hidden", className)}
      style={style}
    />
  );
}

// Memoized: the cache patchers keep untouched items' references, so a
// single-item mutation re-renders only that card — provided the callbacks
// passed down are stable (the captures route useCallback-wraps them).
// onUseTranscript receives the whole capture (the card already holds it) so
// the parent handler doesn't have to close over the captures array, which
// would give it a new identity on every data change.
export const CaptureCard = memo(function CaptureCard({
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
  onUseTranscript: (capture: CaptureBody, mode: "append" | "replace") => void;
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
    <Card asChild>
      <li className="group flex flex-col gap-3 p-4 transition-[border-color,box-shadow]">
        {c.mediaType === "image" && c.mediaUrl && (
          <img
            src={c.mediaUrl}
            alt=""
            className="max-h-40 w-full rounded-control object-contain"
          />
        )}
        {c.mediaType === "audio" && c.mediaUrl && (
          <audio controls src={c.mediaUrl} className="h-8 w-full" />
        )}
        {transcribable &&
          ["pending", "processing"].includes(c.transcriptionStatus) && (
            <div className="flex items-center gap-2 text-caption text-muted">
              {t("transcript.processing")}
            </div>
          )}
        {transcribable && c.transcriptionStatus === "failed" && (
          <div className="flex items-center gap-2 text-caption text-danger">
            <span>{t("transcript.failed")}</span>
            <Button size="sm" onClick={() => onRetryTranscription(c.id)}>
              {t("transcript.retry")}
            </Button>
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
            className="w-full resize-none border-0 bg-transparent p-0 text-small text-ink outline-none"
          />
        ) : (
          <div
            className="cursor-text"
            onClick={() => {
              setDraft(c.rawText ?? "");
              setEditing(true);
            }}
          >
            <Markdown>{c.rawText ?? ""}</Markdown>
          </div>
        )}
        {transcribable && c.transcript && (
          <div className="rounded-control border border-accent-weak bg-accent-weak/30 p-3">
            <div className="mb-2 flex items-center justify-between gap-2 text-caption font-bold uppercase text-accent-strong">
              <span>{t("transcript.label")}</span>
              {!editingTranscript && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setTranscriptDraft(c.transcript ?? "");
                    setEditingTranscript(true);
                  }}
                >
                  {tc("actions.edit")}
                </Button>
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
                  className="min-h-24 w-full resize-none rounded-control border border-line bg-surface px-[13px] py-[11px] font-app text-body leading-normal text-ink outline-none focus:border-accent focus:shadow-focus"
                />
                <div className="mt-2.5 flex justify-end gap-2">
                  <Button
                    variant="primary"
                    size="sm"
                    onClick={commitTranscript}
                  >
                    {tc("actions.save")}
                  </Button>
                  <Button size="sm" onClick={() => setEditingTranscript(false)}>
                    {tc("actions.cancel")}
                  </Button>
                </div>
              </>
            ) : (
              <>
                <Markdown>{c.transcript}</Markdown>
                <div className="mt-2.5 flex justify-end gap-2">
                  {c.rawText && (
                    <Button
                      size="sm"
                      onClick={() => onUseTranscript(c, "append")}
                    >
                      {t("transcript.append")}
                    </Button>
                  )}
                  <Button
                    variant="primary"
                    size="sm"
                    onClick={() => onUseTranscript(c, "replace")}
                  >
                    {c.rawText
                      ? t("transcript.replace")
                      : t("transcript.useAsText")}
                  </Button>
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
        <div className="flex items-center gap-2">
          <span className="flex-1" />
          {editing ? (
            <>
              <Button size="sm" onClick={commitEdit}>
                {tc("actions.save")}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  setDraft(c.rawText ?? "");
                  setEditing(false);
                }}
              >
                {tc("actions.cancel")}
              </Button>
            </>
          ) : (
            <>
              <RemindControl
                remindAt={c.remindAt}
                remindHide={c.remindHide}
                onSet={(at, hide) => onSetRemind(c.id, at, hide)}
              />
              {c.createdAt && (
                <Meta title={fmtPreciseDateTime(c.createdAt, i18n.language)}>
                  {fmtListTime(c.createdAt, i18n.language)}
                </Meta>
              )}
              <DropdownMenu.Root>
                <DropdownMenu.Trigger asChild>
                  <button
                    className="grid size-7 cursor-pointer place-items-center rounded-full border border-transparent bg-transparent text-muted transition-colors hover:bg-tint hover:text-ink [&_svg]:size-[19px]"
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
                    className="z-100 min-w-35 rounded-control border border-line bg-surface p-1 shadow-overlay"
                    align="end"
                    sideOffset={4}
                  >
                    <DropdownMenu.Item
                      className="flex cursor-pointer select-none items-center rounded-md px-3 py-2 text-small text-danger outline-none hover:bg-danger-weak data-[highlighted]:bg-danger-weak"
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
    </Card>
  );
});

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
    <div className="flex flex-col gap-2 rounded-control border border-line bg-surface-2 p-2.5">
      <div className="text-caption font-bold text-muted">
        {t("attachments.title")}
      </div>
      {attachments.map((attachment) => (
        <div
          className="flex min-w-0 items-center gap-2.5 max-[520px]:flex-wrap max-[520px]:items-start"
          key={attachment.id}
        >
          <div
            className="grid size-7 shrink-0 place-items-center rounded-[7px] bg-accent-weak text-caption font-extrabold text-accent-strong"
            aria-hidden="true"
          >
            {providerInitial(attachment.provider)}
          </div>
          <div className="flex min-w-0 flex-1 flex-col gap-0.5 max-[520px]:min-w-[calc(100%-38px)]">
            <a
              className="overflow-hidden text-ellipsis whitespace-nowrap text-small font-semibold text-ink"
              href={attachment.webUrl}
              target="_blank"
              rel="noreferrer"
            >
              {attachment.name}
            </a>
            <Meta>
              {providerLabel(attachment.provider)}
              {attachment.sizeBytes != null
                ? ` · ${fmtFileSize(attachment.sizeBytes)}`
                : ""}
            </Meta>
          </div>
          <a
            className={buttonClassName({ variant: "ghost", size: "sm" })}
            href={attachment.webUrl}
            target="_blank"
            rel="noreferrer"
          >
            {t("attachments.open")}
          </a>
          <Button
            variant="ghost"
            size="sm"
            className="text-danger hover:bg-danger-weak hover:text-danger-strong"
            disabled={deleting}
            onClick={() => onDelete(attachment.id)}
          >
            {t("attachments.removeReference")}
          </Button>
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
