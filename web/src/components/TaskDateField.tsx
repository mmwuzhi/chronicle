import { useState } from "react";
import * as Dialog from "@radix-ui/react-dialog";

const CalendarIcon = () => (
  <svg
    width="14"
    height="14"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    aria-hidden="true"
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5"
    />
  </svg>
);

function displayDate(
  value: string | null | undefined,
  emptyLabel: string,
): string {
  if (!value) return emptyLabel;
  const [year, month, day] = value.slice(0, 10).split("-").map(Number);
  return new Date(year, month - 1, day).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

export function TaskDateField({
  label,
  value,
  emptyLabel,
  saveLabel,
  cancelLabel,
  clearLabel,
  onSave,
  onClear,
}: {
  label: string;
  value: string | null | undefined;
  emptyLabel: string;
  saveLabel: string;
  cancelLabel: string;
  clearLabel: string;
  onSave: (date: string) => void;
  onClear: () => void;
}): React.JSX.Element {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(value?.slice(0, 10) ?? "");

  return (
    <Dialog.Root
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setDraft(value?.slice(0, 10) ?? "");
      }}
    >
      <Dialog.Trigger asChild>
        <button className={`ch-datebtn${value ? "" : " empty"}`}>
          <CalendarIcon />
          {displayDate(value, emptyLabel)}
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="ch-dialog-overlay" />
        <Dialog.Content
          className="ch-card ch-date-dialog"
          aria-describedby={undefined}
        >
          <Dialog.Title className="ch-dialog-title">{label}</Dialog.Title>
          <input
            autoFocus
            className="ch-input"
            type="date"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
          />
          <div className="ch-dialog-actions">
            {value && (
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => {
                  onClear();
                  setOpen(false);
                }}
              >
                {clearLabel}
              </button>
            )}
            <span className="ch-dialog-spacer" />
            <Dialog.Close asChild>
              <button className="ch-btn ch-btn-sm">{cancelLabel}</button>
            </Dialog.Close>
            <button
              className="ch-btn ch-btn-primary ch-btn-sm"
              disabled={!draft}
              onClick={() => {
                if (!draft) return;
                onSave(draft);
                setOpen(false);
              }}
            >
              {saveLabel}
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
