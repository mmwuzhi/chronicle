import { useState } from "react";
import { useTranslation } from "react-i18next";

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
  const { t } = useTranslation("captures");
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
      <span
        className="ch-meta"
        style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
      >
        <span title={due.toLocaleString()}>
          ⏰ {t("remind.at", { time: due.toLocaleString() })}
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
      className="ch-btn ch-btn-ghost ch-btn-sm"
      onClick={() => setEditing(true)}
    >
      ⏰ {t("remind.set")}
    </button>
  );
}
