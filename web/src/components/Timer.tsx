import { useState } from "react";
import { useListTimeBlocks, useCreateTimeBlock } from "../api";
import type { TimeBlockBody } from "../api";
import { useTranslation } from "react-i18next";

function useFormatDuration() {
  const { t } = useTranslation("tasks");
  return (sec: number): string => {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    if (h > 0) return t("duration.hoursMinutes", { h, m });
    if (m > 0) return t("duration.minutesSeconds", { m, s });
    return t("duration.seconds", { s });
  };
}

export function Timer({ taskId }: { taskId: string }) {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const formatDuration = useFormatDuration();
  const { data: blocks, refetch } = useListTimeBlocks({ taskId });
  const createBlock = useCreateTimeBlock();

  const [minutes, setMinutes] = useState("");

  const handleAdd = () => {
    const parsed = parseFloat(minutes);
    if (!parsed || parsed <= 0) return;
    const durationSec = Math.round(parsed * 60);
    const now = new Date();
    const startedAt = new Date(now.getTime() - durationSec * 1000).toISOString();
    createBlock.mutate(
      { data: { taskId, startedAt, endedAt: now.toISOString(), durationSec } },
      { onSuccess: () => { refetch(); setMinutes(""); } },
    );
  };

  const completed = (blocks ?? []).filter((b: TimeBlockBody) => b.endedAt !== null);
  const totalSec = completed.reduce(
    (sum: number, b: TimeBlockBody) => sum + (b.durationSec ?? 0),
    0,
  );

  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-sm font-medium text-gray-500 uppercase tracking-wide">
        {t("time.title")}
      </h2>

      <div className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-3">
        <span className="text-sm text-gray-400 shrink-0">
          {totalSec > 0
            ? t("time.total", { duration: formatDuration(totalSec) })
            : t("time.noTimeLogged")}
        </span>
        <span className="flex-1" />
        <input
          type="number"
          min="0.5"
          step="0.5"
          value={minutes}
          onChange={(e) => setMinutes(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              handleAdd();
            }
          }}
          placeholder={t("time.minutesPlaceholder")}
          className="w-20 border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 text-right"
        />
        <button
          onClick={handleAdd}
          disabled={createBlock.isPending || !minutes || parseFloat(minutes) <= 0}
          className="bg-gray-900 text-white rounded-md px-4 py-1.5 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50 shrink-0"
        >
          {tc("actions.add")}
        </button>
      </div>

      {completed.length > 0 && (
        <ul className="flex flex-col gap-1">
          {completed.map((b: TimeBlockBody) => (
            <li
              key={b.id}
              className="flex items-center gap-2 text-xs text-gray-400 px-1"
            >
              <span>{new Date(b.startedAt).toLocaleString()}</span>
              <span>→</span>
              <span>
                {b.durationSec != null ? formatDuration(b.durationSec) : "—"}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
