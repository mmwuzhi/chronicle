import { useState } from "react";
import type { ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { trailingTagToken } from "@/utils/todo";
import { AutoTextarea } from "@/components/CaptureCard";
import { cn } from "@/lib/cn";
import { TodoChip } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { FieldError } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";

const AttachIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    className="shrink-0"
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="m18.375 12.739-7.693 7.693a4.5 4.5 0 0 1-6.364-6.364l10.94-10.94A3 3 0 1 1 19.5 7.372L8.552 18.32m.009-.01-.01.01m5.699-9.941-7.81 7.81a1.5 1.5 0 0 0 2.112 2.13"
    />
  </svg>
);

const MicIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    className="shrink-0"
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z"
    />
  </svg>
);

type ComposerProps = {
  value: string;
  onChange: (value: string) => void;
  onSubmit: (value: string) => void;
  placeholder: string;
  submitLabel: string;
  submitDisabled?: boolean;
  onPolish?: (value: string) => Promise<string>;
  polishDisabled?: boolean;
  onAttach?: () => void;
  onRecord?: () => void;
  attachLabel?: string;
  recordLabel?: string;
  recording?: boolean;
  busy?: boolean;
  busyLabel?: string;
  error?: string | null;
  minRows?: number;
  attachmentInput?: ReactNode;
  extraControls?: ReactNode;
  canSubmitWithoutText?: boolean;
  // System tags offered while a trailing #-token is being typed ("#", "#t"…).
  // The menu is the discoverability layer for text-driven behaviors: each
  // entry pairs the tag with a one-line hint of what it does.
  tagSuggestions?: { tag: string; hint: string }[];
};

export function Composer({
  value,
  onChange,
  onSubmit,
  placeholder,
  submitLabel,
  submitDisabled,
  onPolish,
  polishDisabled,
  onAttach,
  onRecord,
  attachLabel,
  recordLabel,
  recording,
  busy,
  busyLabel,
  error,
  minRows,
  attachmentInput,
  extraControls,
  canSubmitWithoutText,
  tagSuggestions,
}: ComposerProps): React.JSX.Element {
  const { t: tc } = useTranslation("common");
  const [suggestion, setSuggestion] = useState<string | null>(null);
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);
  const [dismissedToken, setDismissedToken] = useState<string | null>(null);

  const tagToken = tagSuggestions?.length ? trailingTagToken(value) : null;
  const tagMatches =
    tagToken !== null && tagToken !== dismissedToken
      ? (tagSuggestions ?? []).filter(
          (s) => s.tag.startsWith(tagToken) && s.tag !== tagToken,
        )
      : [];

  const completeTag = (tag: string) => {
    onChange(
      value.slice(0, value.length - (tagToken?.length ?? 0)) + tag + " ",
    );
  };

  const trimmed = value.trim();
  const canSubmit =
    (trimmed.length > 0 || canSubmitWithoutText === true) &&
    suggestion === null;
  const shownError = polishError ? tc("errors.polishFailed") : error;

  const handlePolish = async () => {
    if (!onPolish || !trimmed) return;
    setPolishError(false);
    setPolishing(true);
    try {
      setSuggestion(await onPolish(trimmed));
    } catch {
      setPolishError(true);
      setTimeout(() => setPolishError(false), 3000);
    } finally {
      setPolishing(false);
    }
  };

  return (
    <Card className="mb-4 p-4">
      <AutoTextarea
        value={value}
        onChange={(next) => {
          onChange(next);
          if (suggestion !== null) setSuggestion(null);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            if (canSubmit) onSubmit(trimmed);
            return;
          }
          if (tagMatches.length > 0) {
            if (e.key === "Tab" || e.key === "Enter") {
              e.preventDefault();
              completeTag(tagMatches[0].tag);
            } else if (e.key === "Escape") {
              setDismissedToken(tagToken);
            }
          }
        }}
        placeholder={placeholder}
        className="mb-2.5 min-h-24 w-full resize-none border-0 bg-transparent p-0 font-app text-body leading-normal text-ink outline-none placeholder:text-faint focus:shadow-none"
        style={{
          minHeight: minRows ? `${minRows * 24}px` : undefined,
        }}
      />
      {tagMatches.length > 0 && (
        <div className="mb-2.5 flex items-center gap-2 rounded-control border border-line bg-tint px-2 py-1.5">
          {tagMatches.map((s) => (
            <button
              key={s.tag}
              type="button"
              className="inline-flex cursor-pointer items-center gap-2 rounded-control border-0 bg-transparent px-1 py-0.5 [font:inherit] hover:bg-accent-weak/40"
              // onMouseDown so the click completes before the textarea loses focus.
              onMouseDown={(e) => {
                e.preventDefault();
                completeTag(s.tag);
              }}
            >
              <TodoChip>{s.tag}</TodoChip>
              <Meta>{s.hint}</Meta>
            </button>
          ))}
          <Meta className="ml-auto">Tab</Meta>
        </div>
      )}
      {extraControls}

      {suggestion !== null && (
        <div className="mb-2.5 rounded-control border border-accent-weak bg-accent-weak/45 p-2.5">
          <div className="mb-1.5 text-caption font-bold text-accent-strong">
            {tc("actions.polishResult")}
          </div>
          <div className="text-small text-ink">{suggestion}</div>
          <div className="mt-2.5 flex justify-end gap-2">
            <Button
              variant="ai"
              size="sm"
              onClick={() => {
                onChange(suggestion);
                setSuggestion(null);
              }}
            >
              {tc("actions.accept")}
            </Button>
            <Button size="sm" onClick={() => setSuggestion(null)}>
              {tc("actions.dismiss")}
            </Button>
          </div>
        </div>
      )}

      <div className="flex flex-wrap items-center gap-1.5">
        {onAttach && (
          <Button
            size="sm"
            onClick={onAttach}
            disabled={busy || recording}
            data-inline-icon
          >
            <AttachIcon /> {attachLabel}
          </Button>
        )}
        {onRecord && (
          <Button
            size="sm"
            className={cn(recording && "border-danger text-danger")}
            onClick={onRecord}
            disabled={busy && !recording}
            data-inline-icon
          >
            {recording ? "■" : <MicIcon />} {recordLabel}
          </Button>
        )}
        {onPolish && (
          <Button
            variant="ai"
            size="sm"
            onClick={handlePolish}
            disabled={
              polishing || !trimmed || suggestion !== null || polishDisabled
            }
            data-inline-icon
          >
            {polishing ? "..." : "*"} {tc("actions.polish")}
          </Button>
        )}
        {shownError && <FieldError>{shownError}</FieldError>}
        {busy && busyLabel && <Meta>{busyLabel}</Meta>}
        <Button
          variant="primary"
          size="sm"
          className="ml-auto"
          onClick={() => {
            if (canSubmit) onSubmit(trimmed);
          }}
          disabled={submitDisabled || !canSubmit}
        >
          {submitLabel}
        </Button>
      </div>
      {attachmentInput}
    </Card>
  );
}
