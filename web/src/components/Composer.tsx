import { useState } from "react";
import type { ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { AutoTextarea } from "./CaptureCard";

const AttachIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    style={{ flexShrink: 0 }}
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
    style={{ flexShrink: 0 }}
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
}: ComposerProps): React.JSX.Element {
  const { t: tc } = useTranslation("common");
  const [suggestion, setSuggestion] = useState<string | null>(null);
  const [polishing, setPolishing] = useState(false);
  const [polishError, setPolishError] = useState(false);

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
    <div
      className="ch-card"
      style={{ padding: "var(--pad)", marginBottom: 16 }}
    >
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
          }
        }}
        placeholder={placeholder}
        className="ch-textarea"
        style={{
          border: "none",
          boxShadow: "none",
          padding: 0,
          marginBottom: 10,
          minHeight: minRows ? `${minRows * 24}px` : undefined,
        }}
      />
      {extraControls}

      {suggestion !== null && (
        <div
          style={{
            border: "1px solid var(--accent-weak)",
            borderRadius: "var(--radius-sm)",
            background:
              "color-mix(in srgb, var(--accent-weak) 45%, transparent)",
            padding: 10,
            marginBottom: 10,
          }}
        >
          <div
            style={{
              fontSize: "var(--fs-xs)",
              color: "var(--accent-strong)",
              fontWeight: 700,
              marginBottom: 6,
            }}
          >
            {tc("actions.polishResult")}
          </div>
          <div style={{ fontSize: "var(--fs-sm)", color: "var(--text)" }}>
            {suggestion}
          </div>
          <div
            style={{
              display: "flex",
              justifyContent: "flex-end",
              gap: 8,
              marginTop: 10,
            }}
          >
            <button
              className="ch-btn ch-btn-ai ch-btn-sm"
              onClick={() => {
                onChange(suggestion);
                setSuggestion(null);
              }}
            >
              {tc("actions.accept")}
            </button>
            <button
              className="ch-btn ch-btn-sm"
              onClick={() => setSuggestion(null)}
            >
              {tc("actions.dismiss")}
            </button>
          </div>
        </div>
      )}

      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        {onAttach && (
          <button
            className="ch-btn ch-btn-sm"
            onClick={onAttach}
            disabled={busy || recording}
            style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
          >
            <AttachIcon /> {attachLabel}
          </button>
        )}
        {onRecord && (
          <button
            className="ch-btn ch-btn-sm"
            onClick={onRecord}
            disabled={busy && !recording}
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
              ...(recording
                ? { borderColor: "#c2410c", color: "#c2410c" }
                : {}),
            }}
          >
            {recording ? "■" : <MicIcon />} {recordLabel}
          </button>
        )}
        {onPolish && (
          <button
            className="ch-btn ch-btn-ai ch-btn-sm"
            onClick={handlePolish}
            disabled={
              polishing || !trimmed || suggestion !== null || polishDisabled
            }
            style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
          >
            {polishing ? "..." : "*"} {tc("actions.polish")}
          </button>
        )}
        <div style={{ flex: 1 }} />
        {shownError && (
          <span style={{ fontSize: "var(--fs-xs)", color: "#c2410c" }}>
            {shownError}
          </span>
        )}
        {busy && busyLabel && <span className="ch-meta">{busyLabel}</span>}
        <button
          className="ch-btn ch-btn-primary ch-btn-sm"
          onClick={() => {
            if (canSubmit) onSubmit(trimmed);
          }}
          disabled={submitDisabled || !canSubmit}
        >
          {submitLabel}
        </button>
      </div>
      {attachmentInput}
    </div>
  );
}
