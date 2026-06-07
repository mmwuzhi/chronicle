import type { LogTimeDraft } from "../utils/log-time";
import { logTimeRangeMinutes } from "../utils/log-time";

export function LogTimeEditor({
  value,
  onChange,
  labels,
}: {
  value: LogTimeDraft;
  onChange: (value: LogTimeDraft) => void;
  labels: {
    noTime: string;
    duration: string;
    range: string;
    minutes: string;
    start: string;
    end: string;
  };
}): React.JSX.Element {
  const set = (patch: Partial<LogTimeDraft>) =>
    onChange({ ...value, ...patch });
  const maximumMinutes =
    value.mode === "range" ? logTimeRangeMinutes(value) : undefined;

  return (
    <div className="ch-log-time-editor">
      <div className="ch-segmented" role="group">
        {(
          [
            ["none", labels.noTime],
            ["duration", labels.duration],
            ["range", labels.range],
          ] as const
        ).map(([mode, label]) => (
          <button
            key={mode}
            type="button"
            className={value.mode === mode ? "active" : ""}
            onClick={() => set({ mode })}
          >
            {label}
          </button>
        ))}
      </div>
      {value.mode !== "none" && (
        <label className="ch-field-inline">
          <span>{labels.minutes}</span>
          <input
            className="ch-input"
            inputMode="numeric"
            min={1}
            max={maximumMinutes}
            value={value.minutes}
            onChange={(event) => {
              const digits = event.target.value.replace(/\D/g, "");
              if (!digits || maximumMinutes == null) {
                set({ minutes: digits });
                return;
              }
              set({
                minutes: String(
                  Math.min(Number.parseInt(digits, 10), maximumMinutes),
                ),
              });
            }}
            placeholder="30"
          />
        </label>
      )}
      {value.mode === "range" && (
        <div className="ch-log-time-range">
          <label>
            <span>{labels.start}</span>
            <input
              className="ch-input"
              type="datetime-local"
              value={value.startedAt}
              onChange={(event) => set({ startedAt: event.target.value })}
            />
          </label>
          <label>
            <span>{labels.end}</span>
            <input
              className="ch-input"
              type="datetime-local"
              value={value.endedAt}
              onChange={(event) => set({ endedAt: event.target.value })}
            />
          </label>
        </div>
      )}
    </div>
  );
}
