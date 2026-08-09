import {
  useLayoutEffect,
  useRef,
  useState,
  type ComponentPropsWithoutRef,
  type ReactNode,
} from "react";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import type { CaptureBody } from "@/api";
import { CaptureRelated } from "@/components/CaptureRelated";
import { CaptureShareDialog } from "@/components/CaptureShareDialog";
import { Markdown } from "@/components/Markdown";
import { Button, buttonClassName } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/field";
import { TodoChip } from "@/components/ui/badge";
import { Meta } from "@/components/ui/page";
import { useConfirm } from "@/hooks/use-confirm";
import { fmtListTime, fmtPreciseDateTime } from "@/utils/format";
import { TODO_TAG, trailingTagToken } from "@/utils/todo";
import { captureText } from "@/utils/capture";
import {
  hasActiveTextSelection,
  isInteractiveTarget,
} from "@/utils/interaction";

interface CaptureDetailDialogProps {
  capture: CaptureBody;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaveText: (id: string, text: string) => Promise<unknown>;
  onSaveTranscript: (id: string, transcript: string) => Promise<unknown>;
  onUseTranscript: (capture: CaptureBody, mode: "append" | "replace") => void;
  onMutationError: () => void;
  attachments?: ReactNode;
}

export function CaptureDetailDialog({
  capture,
  open,
  onOpenChange,
  onSaveText,
  onSaveTranscript,
  onUseTranscript,
  onMutationError,
  attachments,
}: CaptureDetailDialogProps): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const confirm = useConfirm();
  const [editingText, setEditingText] = useState(false);
  const [editingTranscript, setEditingTranscript] = useState(false);
  const [saving, setSaving] = useState(false);
  const [copied, setCopied] = useState(false);
  const [textDraft, setTextDraft] = useState(capture.rawText ?? "");
  const [transcriptDraft, setTranscriptDraft] = useState(
    capture.transcript ?? "",
  );
  const transcribable =
    capture.mediaType === "audio" || capture.mediaType === "image";
  const textTagToken = editingText ? trailingTagToken(textDraft) : null;
  const offersTodoSuggestion =
    textTagToken !== null &&
    textTagToken !== TODO_TAG &&
    TODO_TAG.startsWith(textTagToken);

  const hasUnsavedChanges =
    (editingText && textDraft !== (capture.rawText ?? "")) ||
    (editingTranscript && transcriptDraft !== (capture.transcript ?? ""));

  const closeDialog = () => {
    setEditingText(false);
    setEditingTranscript(false);
    onOpenChange(false);
  };

  const confirmDiscard = async (dirty: boolean) =>
    !dirty ||
    confirm({
      title: tc("confirm.discardChanges"),
      description: tc("confirm.discardChangesDescription"),
      confirmLabel: tc("confirm.discard"),
      cancelLabel: tc("confirm.keepEditing"),
      variant: "danger",
    });

  const requestClose = async () => {
    if (saving || !(await confirmDiscard(hasUnsavedChanges))) return;
    closeDialog();
  };

  const setOpen = (nextOpen: boolean) => {
    if (nextOpen) {
      onOpenChange(true);
      return;
    }
    void requestClose();
  };

  const saveText = async () => {
    const trimmed = textDraft.trim();
    if (!trimmed || trimmed === capture.rawText) {
      setEditingText(false);
      return;
    }
    setSaving(true);
    try {
      await onSaveText(capture.id, trimmed);
      setEditingText(false);
    } catch {
      // The route mutation already surfaces the error; retain the draft for retry.
    } finally {
      setSaving(false);
    }
  };

  const saveTranscript = async () => {
    const trimmed = transcriptDraft.trim();
    if (!trimmed || trimmed === capture.transcript) {
      setEditingTranscript(false);
      return;
    }
    setSaving(true);
    try {
      await onSaveTranscript(capture.id, trimmed);
      setEditingTranscript(false);
    } catch {
      // The route mutation already surfaces the error; retain the draft for retry.
    } finally {
      setSaving(false);
    }
  };
  const beginTextEdit = async () => {
    if (saving) return;
    const transcriptDirty =
      editingTranscript && transcriptDraft !== (capture.transcript ?? "");
    if (!(await confirmDiscard(transcriptDirty))) return;
    setTranscriptDraft(capture.transcript ?? "");
    setTextDraft(capture.rawText ?? "");
    setEditingTranscript(false);
    setEditingText(true);
  };
  const beginTranscriptEdit = async () => {
    if (saving) return;
    const textDirty = editingText && textDraft !== (capture.rawText ?? "");
    if (!(await confirmDiscard(textDirty))) return;
    setTextDraft(capture.rawText ?? "");
    setTranscriptDraft(capture.transcript ?? "");
    setEditingText(false);
    setEditingTranscript(true);
  };
  const cancelTextEdit = () => {
    setTextDraft(capture.rawText ?? "");
    setEditingText(false);
  };
  const cancelTranscriptEdit = () => {
    setTranscriptDraft(capture.transcript ?? "");
    setEditingTranscript(false);
  };
  const completeTodoSuggestion = () => {
    if (!textTagToken || !TODO_TAG.startsWith(textTagToken)) return;
    setTextDraft(
      textDraft.slice(0, textDraft.length - textTagToken.length) +
        `${TODO_TAG} `,
    );
  };
  const copyCapture = async () => {
    const content = captureText(capture);
    if (!content) return;
    try {
      await navigator.clipboard.writeText(content);
      setCopied(true);
    } catch {
      onMutationError();
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent
        aria-busy={saving}
        className="ch-capture-detail-dialog gap-0 overflow-hidden p-0 max-sm:left-0 max-sm:top-0 max-sm:w-full max-sm:translate-x-0 max-sm:translate-y-0 max-sm:rounded-none max-sm:border-0 max-sm:shadow-none"
      >
        <DialogDescription className="sr-only">Capture</DialogDescription>
        <header className="flex shrink-0 items-center gap-3 border-b border-hairline px-5 py-3.5 max-sm:px-4">
          <DialogTitle className="sr-only">Capture</DialogTitle>
          <div className="min-w-0 flex-1">
            {capture.createdAt && (
              <Meta
                title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
              >
                {fmtListTime(capture.createdAt, i18n.language)}
              </Meta>
            )}
          </div>
          {!editingText && !editingTranscript && (
            <div className="flex shrink-0 items-center gap-1 max-[520px]:hidden">
              <Link
                to="/captures/context"
                search={{ anchorId: capture.id }}
                className={buttonClassName({ variant: "ghost", size: "sm" })}
              >
                {t("context.open")}
              </Link>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => void copyCapture()}
              >
                {copied ? t("detail.copied") : tc("actions.copy")}
              </Button>
              {capture.rawText?.trim() && (
                <CaptureShareDialog capture={capture} />
              )}
            </div>
          )}
          {editingText && (
            <div className="flex shrink-0 items-center gap-1">
              <Button
                variant="primary"
                size="sm"
                disabled={saving}
                onClick={() => void saveText()}
              >
                {tc("actions.save")}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                disabled={saving}
                onClick={cancelTextEdit}
              >
                {tc("actions.cancel")}
              </Button>
            </div>
          )}
          {editingTranscript && (
            <div className="flex shrink-0 items-center gap-1">
              <Button
                variant="primary"
                size="sm"
                disabled={saving}
                onClick={() => void saveTranscript()}
              >
                {tc("actions.save")}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                disabled={saving}
                onClick={cancelTranscriptEdit}
              >
                {tc("actions.cancel")}
              </Button>
            </div>
          )}
          <DialogClose asChild>
            <button
              disabled={saving}
              className="grid size-8 shrink-0 cursor-pointer place-items-center rounded-full border-0 bg-transparent text-muted transition-colors hover:bg-tint hover:text-ink focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-accent/20"
              aria-label={tc("actions.dismiss")}
            >
              <svg
                viewBox="0 0 20 20"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                aria-hidden="true"
                className="size-4"
              >
                <path d="m5 5 10 10M15 5 5 15" strokeLinecap="round" />
              </svg>
            </button>
          </DialogClose>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-6 py-5 max-sm:px-4">
          <div className="mx-auto flex w-full max-w-[640px] flex-col gap-5">
            {!editingText && !editingTranscript && (
              <div className="hidden items-center gap-1 max-[520px]:flex">
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  className={buttonClassName({
                    variant: "default",
                    size: "sm",
                    className: "flex-1",
                  })}
                >
                  {t("context.open")}
                </Link>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => void copyCapture()}
                >
                  {copied ? t("detail.copied") : tc("actions.copy")}
                </Button>
                {capture.rawText?.trim() && (
                  <CaptureShareDialog
                    capture={capture}
                    triggerVariant="default"
                    triggerClassName="flex-1"
                  />
                )}
              </div>
            )}
            {capture.mediaType === "image" && capture.mediaUrl && (
              <img
                src={capture.mediaUrl}
                alt=""
                className="max-h-[55vh] w-full rounded-card object-contain"
              />
            )}
            {capture.mediaType === "audio" && capture.mediaUrl && (
              <audio controls src={capture.mediaUrl} className="w-full" />
            )}

            {editingText ? (
              <div className="flex flex-col">
                <GrowingTextarea
                  autoFocus
                  value={textDraft}
                  onChange={(event) => setTextDraft(event.target.value)}
                  onKeyDown={(event) => {
                    if (
                      event.key === "Enter" &&
                      (event.metaKey || event.ctrlKey)
                    ) {
                      event.preventDefault();
                      void saveText();
                      return;
                    }
                    if (
                      offersTodoSuggestion &&
                      (event.key === "Tab" || event.key === "Enter")
                    ) {
                      event.preventDefault();
                      completeTodoSuggestion();
                      return;
                    }
                    if (event.key === "Escape") {
                      event.stopPropagation();
                      cancelTextEdit();
                    }
                  }}
                />
                {offersTodoSuggestion && (
                  <TodoTagSuggestion
                    hint={t("tagMenu.todoHint")}
                    onComplete={completeTodoSuggestion}
                  />
                )}
              </div>
            ) : (
              <div className="group relative">
                <div
                  className="ch-capture-detail-text -m-2 cursor-text rounded-control p-2 text-body leading-normal transition-colors hover:bg-surface-2"
                  onClick={(event) => {
                    if (
                      isInteractiveTarget(event.target) ||
                      hasActiveTextSelection()
                    ) {
                      return;
                    }
                    void beginTextEdit();
                  }}
                >
                  <Markdown>{capture.rawText ?? ""}</Markdown>
                </div>
                <Button
                  variant="ghost"
                  size="sm"
                  className="absolute right-0 top-0 opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
                  onClick={() => void beginTextEdit()}
                >
                  {tc("actions.edit")}
                </Button>
              </div>
            )}

            {transcribable && capture.transcript && (
              <section className="rounded-card border border-accent-weak bg-accent-weak/30 p-4">
                <div className="mb-3 text-caption font-bold uppercase tracking-[0.08em] text-accent-strong">
                  {t("transcript.label")}
                </div>
                {editingTranscript ? (
                  <GrowingTextarea
                    autoFocus
                    value={transcriptDraft}
                    onChange={(event) => setTranscriptDraft(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Escape") {
                        event.stopPropagation();
                        cancelTranscriptEdit();
                      }
                    }}
                  />
                ) : (
                  <>
                    <div className="group relative">
                      <div
                        className="ch-capture-detail-transcript -m-2 cursor-text rounded-control p-2 transition-colors hover:bg-surface/70"
                        onClick={(event) => {
                          if (
                            isInteractiveTarget(event.target) ||
                            hasActiveTextSelection()
                          ) {
                            return;
                          }
                          void beginTranscriptEdit();
                        }}
                      >
                        <Markdown>{capture.transcript}</Markdown>
                      </div>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="absolute right-0 top-0 opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
                        onClick={() => void beginTranscriptEdit()}
                      >
                        {tc("actions.edit")}
                      </Button>
                    </div>
                    <div className="mt-3 flex flex-wrap justify-end gap-2">
                      {capture.rawText && (
                        <Button
                          size="sm"
                          onClick={() => onUseTranscript(capture, "append")}
                        >
                          {t("transcript.append")}
                        </Button>
                      )}
                      <Button
                        variant="primary"
                        size="sm"
                        onClick={() => onUseTranscript(capture, "replace")}
                      >
                        {capture.rawText
                          ? t("transcript.replace")
                          : t("transcript.useAsText")}
                      </Button>
                    </div>
                  </>
                )}
              </section>
            )}

            {attachments}

            <div
              aria-hidden={editingText || editingTranscript}
              className={
                editingText || editingTranscript
                  ? "invisible pointer-events-none"
                  : undefined
              }
            >
              <CaptureRelated
                anchorId={capture.id}
                onMutationError={onMutationError}
              />
            </div>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function GrowingTextarea({
  value,
  className,
  ...props
}: Omit<ComponentPropsWithoutRef<typeof Textarea>, "value"> & {
  value: string;
}): React.JSX.Element {
  const ref = useRef<HTMLTextAreaElement>(null);

  useLayoutEffect(() => {
    let lastWidth = -1;
    const resize = () => {
      const textarea = ref.current;
      if (!textarea) return;
      if (textarea.clientWidth === lastWidth) return;
      lastWidth = textarea.clientWidth;
      textarea.style.height = "auto";
      textarea.style.height = `${textarea.scrollHeight}px`;
    };

    resize();
    const observer =
      typeof ResizeObserver === "undefined" ? null : new ResizeObserver(resize);
    if (ref.current) observer?.observe(ref.current);
    window.addEventListener("resize", resize);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", resize);
    };
  }, [value]);

  return (
    <Textarea
      ref={ref}
      rows={1}
      value={value}
      className={`ch-capture-detail-editor shrink-0 resize-none overflow-hidden ${className ?? ""}`}
      {...props}
    />
  );
}

function TodoTagSuggestion({
  hint,
  onComplete,
}: {
  hint: string;
  onComplete: () => void;
}): React.JSX.Element {
  return (
    <button
      type="button"
      className="-mx-2 mt-2 flex cursor-pointer items-center gap-2 rounded-control border border-line bg-tint px-2 py-1.5 text-left transition-colors hover:border-strong"
      onMouseDown={(event) => event.preventDefault()}
      onClick={onComplete}
    >
      <TodoChip>{TODO_TAG}</TodoChip>
      <Meta>{hint}</Meta>
      <Meta className="ml-auto">Tab</Meta>
    </button>
  );
}
