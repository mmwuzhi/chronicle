import { useTranslation } from "react-i18next";
import type { TodoState } from "../utils/todo";

function SquarePlusIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <rect x="3" y="3" width="18" height="18" rx="3" />
      <path strokeLinecap="round" d="M8 12h8M12 8v8" />
    </svg>
  );
}

/**
 * The todo facet control on a capture card. A plain capture shows a quiet
 * flag-as-todo button (revealed on row hover — a square-plus icon plus label,
 * not a bare checkbox, so it can't read as "mark done"); flagging it is what
 * classifies the capture as actionable. A flagged capture shows a real
 * checkbox toggling open ↔ done — the state words match the facet name
 * (Todo/Done, same vocabulary as the filter tabs), and the action-vs-state
 * distinction is carried by the icon: plus = can become a todo, checkbox =
 * is one. Un-flagging lives in the card's overflow menu.
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
        <SquarePlusIcon />
        {t("todo.flag")}
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
