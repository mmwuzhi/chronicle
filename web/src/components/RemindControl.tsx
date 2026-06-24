import { useState } from "react";
import { useTranslation } from "react-i18next";

// Time-based recall control on a capture card: set / clear a future remind_at.
// Browse hides a not-yet-due reminder until it arrives; the desktop app fires a
// native notification at the time. Search/recall never filter on remind_at.
export function RemindControl({
  remindAt,
  onSet,
}: {
  remindAt: string | null;
  onSet: (at: string | null) => void;
}): React.JSX.Element {
  const { t } = useTranslation("captures");
  const [editing, setEditing] = useState(false);

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
            onSet(new Date(v).toISOString());
            setEditing(false);
          }}
        />
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
          onClick={() => onSet(null)}
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
