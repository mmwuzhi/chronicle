import { useEffect, useRef, useState } from "react";
import {
  useListTimeBlocks,
  useCreateTimeBlock,
  useUpdateTimeBlock,
} from "../api";
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
  const formatDuration = useFormatDuration();
  const { data: blocks, refetch } = useListTimeBlocks({ taskId });
  const createBlock = useCreateTimeBlock();
  const updateBlock = useUpdateTimeBlock();

  const running = (blocks ?? []).find((b: TimeBlockBody) => b.endedAt === null);

  const [elapsed, setElapsed] = useState(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const runningId = running?.id;
  const runningStartedAt = running?.startedAt;

  useEffect(() => {
    if (intervalRef.current) clearInterval(intervalRef.current);

    if (!runningId || !runningStartedAt) return;

    const startMs = new Date(runningStartedAt).getTime();
    const update = () => setElapsed(Math.floor((Date.now() - startMs) / 1000));

    const timeout = setTimeout(update, 0);
    intervalRef.current = setInterval(update, 1000);

    return () => {
      clearTimeout(timeout);
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [runningId, runningStartedAt]);

  const handleStart = () => {
    createBlock.mutate(
      { data: { taskId, startedAt: new Date().toISOString() } },
      { onSuccess: () => refetch() },
    );
  };

  const handleStop = () => {
    if (!running) return;
    const endedAt = new Date().toISOString();
    const durationSec = Math.floor(
      (new Date(endedAt).getTime() - new Date(running.startedAt).getTime()) /
        1000,
    );
    updateBlock.mutate(
      { id: running.id, data: { endedAt, durationSec } },
      { onSuccess: () => refetch() },
    );
  };

  const completed = (blocks ?? []).filter(
    (b: TimeBlockBody) => b.endedAt !== null,
  );
  const totalSec = completed.reduce(
    (sum: number, b: TimeBlockBody) => sum + (b.durationSec ?? 0),
    0,
  );

  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-sm font-medium text-gray-500 uppercase tracking-wide">
        {t("time.title")}
      </h2>

      <div className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex items-center gap-4">
        {running ? (
          <>
            <span className="text-2xl font-mono font-semibold tabular-nums text-gray-900">
              {formatDuration(elapsed)}
            </span>
            <span className="flex-1" />
            <button
              onClick={handleStop}
              disabled={updateBlock.isPending}
              className="bg-red-500 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-red-600 transition-colors disabled:opacity-50"
            >
              {t("time.stop")}
            </button>
          </>
        ) : (
          <>
            <span className="text-sm text-gray-400">
              {totalSec > 0
                ? t("time.total", { duration: formatDuration(totalSec) })
                : t("time.noTimeLogged")}
            </span>
            <span className="flex-1" />
            <button
              onClick={handleStart}
              disabled={createBlock.isPending}
              className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
            >
              {t("time.startTimer")}
            </button>
          </>
        )}
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
