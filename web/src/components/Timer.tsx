import { useState } from "react";
import { useListTimeBlocks, useCreateTimeBlock } from "../api";
import type { TimeBlockBody } from "../api";
import { useTranslation } from "react-i18next";
import { fmtShortDateTime } from "../utils/format";

const ClockIcon = () => (
  <svg
    width="18"
    height="18"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    viewBox="0 0 24 24"
    style={{ flexShrink: 0, color: "var(--text-muted)" }}
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
    />
  </svg>
);

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
    const parsed = parseInt(minutes, 10);
    if (!parsed || parsed <= 0) return;
    const durationSec = parsed * 60;
    const now = new Date();
    const startedAt = new Date(
      now.getTime() - durationSec * 1000,
    ).toISOString();
    createBlock.mutate(
      { data: { taskId, startedAt, endedAt: now.toISOString(), durationSec } },
      {
        onSuccess: () => {
          refetch();
          setMinutes("");
        },
      },
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
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      {/* Total time row */}
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <ClockIcon />
        <span
          style={{
            fontSize: 26,
            fontWeight: 700,
            fontFamily: "var(--font-display)",
            color: "var(--text)",
            lineHeight: 1,
          }}
        >
          {totalSec > 0 ? formatDuration(totalSec) : "—"}
        </span>
        <span style={{ flex: 1 }} />
        <input
          type="text"
          inputMode="numeric"
          pattern="[0-9]*"
          value={minutes}
          onChange={(e) => setMinutes(e.target.value.replace(/[^0-9]/g, ""))}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              handleAdd();
            }
          }}
          placeholder={t("time.minutesPlaceholder")}
          className="ch-input"
          style={{ width: 72, textAlign: "right", padding: "5px 10px" }}
        />
        <button
          onClick={handleAdd}
          disabled={
            createBlock.isPending || !minutes || parseInt(minutes, 10) <= 0
          }
          className="ch-btn ch-btn-primary ch-btn-sm"
        >
          + {tc("actions.add")}
        </button>
      </div>

      {/* Time blocks list */}
      {completed.length === 0 ? (
        <p className="ch-meta" style={{ margin: 0 }}>
          {t("time.noTimeLogged")}
        </p>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          {completed.map((b: TimeBlockBody) => (
            <div
              key={b.id}
              style={{ display: "flex", alignItems: "center", gap: 10 }}
            >
              <span className="ch-meta">{fmtShortDateTime(b.startedAt)}</span>
              <span
                className="ch-meta"
                style={{ color: "var(--accent)", fontWeight: 600 }}
              >
                +{b.durationSec != null ? formatDuration(b.durationSec) : "—"}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
