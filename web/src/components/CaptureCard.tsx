import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
} from "react";
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
import { CaptureDetailDialog } from "@/components/CaptureDetailDialog";
import { CollapsibleMarkdown } from "@/components/CollapsibleMarkdown";
import { RemindControl } from "@/components/RemindControl";
import { cn } from "@/lib/cn";
import {
  hasActiveTextSelection,
  isInteractiveTarget,
} from "@/utils/interaction";
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
  masonry = false,
  onDelete,
  onSaveText,
  onSaveTranscript,
  onUseTranscript,
  onRetryTranscription,
  onSetRemind,
  onMutationError,
}: {
  c: CaptureBody;
  masonry?: boolean;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => Promise<unknown>;
  onSaveTranscript: (id: string, transcript: string) => Promise<unknown>;
  onUseTranscript: (capture: CaptureBody, mode: "append" | "replace") => void;
  onRetryTranscription: (id: string) => void;
  onSetRemind: (id: string, at: string | null, hide: boolean) => void;
  onMutationError: () => void;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const [detailOpen, setDetailOpen] = useState(false);
  const cardRef = useRef<HTMLLIElement>(null);
  const [masonrySpan, setMasonrySpan] = useState(1);
  useLayoutEffect(() => {
    const card = cardRef.current;
    if (!masonry || !card) return;

    const resize = () => {
      const grid = card.parentElement;
      if (!grid) return;
      const gap = Number.parseFloat(
        getComputedStyle(grid).getPropertyValue("--masonry-gap"),
      );
      const nextSpan = Math.max(
        1,
        Math.ceil(card.getBoundingClientRect().height + (gap || 0)),
      );
      setMasonrySpan((current) => (current === nextSpan ? current : nextSpan));
    };

    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(card);
    return () => observer.disconnect();
  }, [masonry]);
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
  const openDetail = () => setDetailOpen(true);

  return (
    <Card asChild>
      <li
        ref={cardRef}
        className={cn(
          "group flex cursor-pointer flex-col gap-3 p-4 transition-[border-color,box-shadow] hover:border-strong",
          masonry ? "ch-capture-masonry-card" : "h-full",
        )}
        style={
          masonry
            ? ({
                "--masonry-span": masonrySpan,
              } as CSSProperties)
            : undefined
        }
        onClick={(event) => {
          const target = event.target;
          if (
            (target instanceof Element &&
              target.closest("[data-capture-card-actions]")) ||
            isInteractiveTarget(target) ||
            hasActiveTextSelection()
          ) {
            return;
          }
          openDetail();
        }}
      >
        <div className="ch-capture-card-body flex flex-1 cursor-pointer flex-col gap-3 rounded-control">
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
          <CollapsibleMarkdown showMoreLabel={t("longContent.showMore")}>
            {c.rawText ?? ""}
          </CollapsibleMarkdown>
          {transcribable && c.transcript && (
            <div className="rounded-control border border-accent-weak bg-accent-weak/30 p-3">
              <div className="mb-2 text-caption font-bold uppercase text-accent-strong">
                {t("transcript.label")}
              </div>
              <CollapsibleMarkdown
                showMoreLabel={t("longContent.showMore")}
                tone="accent"
              >
                {c.transcript}
              </CollapsibleMarkdown>
            </div>
          )}
          {attachments.length > 0 && (
            <button
              type="button"
              className="flex cursor-pointer items-center justify-between gap-3 rounded-control border border-line bg-surface-2 px-3 py-2 text-left text-small text-muted transition-colors hover:border-strong hover:text-ink"
              onClick={openDetail}
            >
              <span>{t("attachments.title")}</span>
              <span className="font-code text-caption text-faint">
                {attachments.length}
              </span>
            </button>
          )}
        </div>
        <div className="mt-auto flex items-center">
          <span className="flex-1" />
          <div
            className="flex cursor-default items-center gap-2"
            data-capture-card-actions
          >
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
            <button
              type="button"
              className="grid size-7 cursor-pointer place-items-center rounded-full border border-transparent bg-transparent text-muted transition-colors hover:bg-tint hover:text-ink focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-accent/20"
              aria-label={t("openCapture")}
              aria-haspopup="dialog"
              onClick={openDetail}
            >
              <svg
                viewBox="0 0 20 20"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                aria-hidden="true"
                className="size-4"
              >
                <path
                  d="m7 5 5 5-5 5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </button>
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
          </div>
        </div>
        {detailOpen && (
          <CaptureDetailDialog
            capture={c}
            open
            onOpenChange={setDetailOpen}
            onSaveText={onSaveText}
            onSaveTranscript={onSaveTranscript}
            onUseTranscript={onUseTranscript}
            onMutationError={onMutationError}
            attachments={
              attachments.length > 0 ? (
                <CaptureAttachments
                  attachments={attachments}
                  deleting={deleteAttachment.isPending}
                  onDelete={(attachmentId) =>
                    deleteAttachment.mutate({ id: c.id, attachmentId })
                  }
                />
              ) : undefined
            }
          />
        )}
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
