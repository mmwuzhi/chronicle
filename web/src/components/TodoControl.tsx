import { useTranslation } from "react-i18next";
import type { TodoState } from "../utils/todo";

/**
 * The todo facet control on a capture card. A plain capture shows a quiet
 * flag-as-todo button (revealed on row hover — a text label, not a bare
 * checkbox, so it can't read as "mark done"); flagging it is what classifies
 * the capture as actionable. A flagged capture shows a real checkbox toggling
 * open ↔ done. Un-flagging lives in the card's overflow menu.
 */
export function TodoControl({
  todoAt,
  doneAt,
  onSet,
}: {
  todoAt?: string | null;
  doneAt?: string | null;
  onSet: (state: TodoState) => void;
}): React.JSX.Element {
  const { t } = useTranslation("captures");

  if (!todoAt) {
    return (
      <button
        className="ch-btn ch-btn-ghost ch-btn-sm ch-todo-flag"
        onClick={() => onSet("open")}
      >
        ☐ {t("todo.flag")}
      </button>
    );
  }

  const done = doneAt != null;
  return (
    <label className={`ch-todo-check${done ? " done" : ""}`}>
      <input
        type="checkbox"
        checked={done}
        onChange={() => onSet(done ? "open" : "done")}
      />
      {done ? t("todo.done") : t("todo.open")}
    </label>
  );
}
