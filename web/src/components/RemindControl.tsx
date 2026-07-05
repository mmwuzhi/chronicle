import { useState } from "react";
import { useTranslation } from "react-i18next";
import { fmtPreciseDateTime } from "../utils/format";

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
      <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
        <input
          type="datetime-local"
          autoFocus
          className="ch-input ch-input-sm"
          onChange={(e) => {
            const v = e.target.value;
            if (!v) return;
            onSet(new Date(v).toISOString(), !keepVisible);
            setEditing(false);
          }}
        />
        <label
          className="ch-meta"
          style={{ display: "inline-flex", alignItems: "center", gap: 4 }}
          title={t("remind.keepVisibleHint")}
        >
          <input
            type="checkbox"
            checked={keepVisible}
            onChange={(e) => setKeepVisible(e.target.checked)}
          />
          {t("remind.keepVisible")}
        </label>
        <button
          className="ch-btn ch-btn-ghost ch-btn-sm"
          onClick={() => setEditing(false)}
        >
          {t("remind.cancel")}
        </button>
      </span>
    );
  }

  if (remindAt) {
    const due = new Date(remindAt);
    return (
      <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
        <span className="ch-time-chip" title={due.toLocaleString()}>
          <BellIcon />
          {t("remind.at", {
            time: fmtPreciseDateTime(remindAt, i18n.language),
          })}
        </span>
        <button
          className="ch-btn ch-btn-ghost ch-btn-sm"
          onClick={() => onSet(null, true)}
        >
          {t("remind.clear")}
        </button>
      </span>
    );
  }

  return (
    <button
      className="ch-btn ch-btn-ghost ch-btn-sm ch-remind-flag"
      onClick={() => {
        // Re-derive from the capture's current state each time, so the checkbox
        // isn't stale after a prior set→clear on this same card.
        setKeepVisible(remindHide === false);
        setEditing(true);
      }}
    >
      <BellIcon />
      {t("remind.set")}
    </button>
  );
}
