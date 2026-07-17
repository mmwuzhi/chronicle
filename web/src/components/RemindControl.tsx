import { useState } from "react";
import { useTranslation } from "react-i18next";
import { fmtPreciseDateTime } from "@/utils/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/field";

function BellIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9M10.3 21a1.94 1.94 0 0 0 3.4 0"
      />
    </svg>
  );
}

// Time-based recall control on a capture card: set / clear a future remind_at.
// Browse hides a not-yet-due reminder until it arrives; the desktop app fires a
// native notification at the time. Search/recall never filter on remind_at.
export function RemindControl({
  remindAt,
  remindHide = true,
  onSet,
}: {
  remindAt: string | null;
  // false = notify-only (stays visible, still notified). Defaults to hide-until-due.
  remindHide?: boolean;
  onSet: (at: string | null, hide: boolean) => void;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const [editing, setEditing] = useState(false);
  // "Keep visible" is the inverse of hide; pre-filled from the current reminder.
  const [keepVisible, setKeepVisible] = useState(remindHide === false);

  if (editing) {
    return (
      <span className="inline-flex flex-wrap items-center gap-1.5">
        <Input
          type="datetime-local"
          autoFocus
          className="min-h-8 w-auto px-2.5 py-1.5 text-small"
          onChange={(e) => {
            const v = e.target.value;
            if (!v) return;
            onSet(new Date(v).toISOString(), !keepVisible);
            setEditing(false);
          }}
        />
        <label
          className="inline-flex items-center gap-1 font-code text-caption text-faint"
          title={t("remind.keepVisibleHint")}
        >
          <input
            type="checkbox"
            checked={keepVisible}
            onChange={(e) => setKeepVisible(e.target.checked)}
          />
          {t("remind.keepVisible")}
        </label>
        <Button variant="ghost" size="sm" onClick={() => setEditing(false)}>
          {t("remind.cancel")}
        </Button>
      </span>
    );
  }

  if (remindAt) {
    const due = new Date(remindAt);
    return (
      <span className="inline-flex items-center gap-1.5">
        <span
          className="inline-flex items-center gap-1.5 font-code text-caption font-semibold text-accent-strong [&_svg]:size-[13px] [&_svg]:shrink-0"
          title={due.toLocaleString()}
        >
          <BellIcon />
          {t("remind.at", {
            time: fmtPreciseDateTime(remindAt, i18n.language),
          })}
        </span>
        <Button variant="ghost" size="sm" onClick={() => onSet(null, true)}>
          {t("remind.clear")}
        </Button>
      </span>
    );
  }

  return (
    <Button
      variant="ghost"
      size="sm"
      className="opacity-100 transition-opacity md:opacity-0 md:group-hover:opacity-100 focus-visible:opacity-100"
      onClick={() => {
        // Re-derive from the capture's current state each time, so the checkbox
        // isn't stale after a prior set→clear on this same card.
        setKeepVisible(remindHide === false);
        setEditing(true);
      }}
    >
      <BellIcon />
      {t("remind.set")}
    </Button>
  );
}
