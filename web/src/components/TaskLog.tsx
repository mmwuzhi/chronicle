import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListLogEntriesQueryKey,
  useCreateLogEntry,
  useDeleteLogEntry,
  useListLogEntries,
  useUpdateLogEntry,
} from "../api";
import type { LogEntryBody } from "../api";
import { useMutationToast } from "../hooks/use-mutation-toast";
import {
  emptyLogTimeDraft,
  logTimeDraftFromValue,
  logTimePayload,
  type LogTimeDraft,
} from "../utils/log-time";
import { timeAgo } from "../utils/format";
import { apiClient } from "../lib/axios";
import { useConfirm } from "./confirm-dialog";
import { Composer } from "./Composer";
import { LogTimeEditor } from "./LogTimeEditor";
import { Markdown } from "./Markdown";
import { MutationToast } from "./mutation-toast";

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  return `${minutes}m`;
}

export function TaskLog({ taskId }: { taskId: string }): React.JSX.Element {
  const { t, i18n } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const mutationToast = useMutationToast();
  const [body, setBody] = useState("");
  const [logTime, setLogTime] = useState<LogTimeDraft>({
    ...emptyLogTimeDraft,
  });
  const [editingEntryId, setEditingEntryId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [editTimeDraft, setEditTimeDraft] = useState<LogTimeDraft>({
    ...emptyLogTimeDraft,
  });
  const [polishError, setPolishError] = useState(false);
  const { data: entries, isLoading } = useListLogEntries({ taskId });
  const createEntry = useCreateLogEntry({
    mutation: {
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const updateEntry = useUpdateLogEntry({
    mutation: {
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const deleteEntry = useDeleteLogEntry({
    mutation: {
      onError: () => mutationToast.show(tc("errors.mutationFailed")),
    },
  });
  const invalidate = () =>
    queryClient.invalidateQueries({
      queryKey: getListLogEntriesQueryKey({ taskId }),
    });
  const labels = {
    noTime: t("time.noTime"),
    duration: t("time.durationMode"),
    range: t("time.rangeMode"),
    minutes: t("time.minutes"),
    start: t("time.start"),
    end: t("time.end"),
  };

  const polish = async (value: string) => {
    setPolishError(false);
    try {
      const response = await apiClient.post<{ polished: string }>(
        "/ai/polish",
        {
          text: value.trim(),
        },
      );
      return response.data.polished;
    } catch {
      setPolishError(true);
      window.setTimeout(() => setPolishError(false), 3000);
      throw new Error("polish failed");
    }
  };

  const addEntry = (value = body) => {
    const trimmed = value.trim();
    const time = logTimePayload(logTime);
    if (!trimmed && !time) return;
    createEntry.mutate(
      { data: { body: trimmed, taskId, ...(time ? { time } : {}) } },
      {
        onSuccess: () => {
          invalidate();
          setBody("");
          setLogTime({ ...emptyLogTimeDraft });
        },
      },
    );
  };

  const startEditing = (entry: LogEntryBody) => {
    setEditingEntryId(entry.id);
    setEditDraft(entry.body);
    setEditTimeDraft(logTimeDraftFromValue(entry.time));
  };

  return (
    <>
      <div className="ch-section">
        <span className="bar" />
        <span className="ch-sectlabel">{t("log.title")}</span>
        <span className="ch-sectcount">{(entries ?? []).length}</span>
        <span className="ch-time-chip">
          {formatDuration(
            (entries ?? []).reduce(
              (sum, entry) => sum + (entry.time?.durationSec ?? 0),
              0,
            ),
          )}
        </span>
        <span className="rule" />
      </div>
      <Composer
        value={body}
        onChange={setBody}
        onSubmit={addEntry}
        placeholder={t("log.placeholder")}
        submitLabel={t("log.addNote")}
        submitDisabled={createEntry.isPending}
        onPolish={polish}
        error={polishError ? tc("errors.polishFailed") : null}
        minRows={2}
        canSubmitWithoutText={logTimePayload(logTime) !== null}
        extraControls={
          <LogTimeEditor
            value={logTime}
            onChange={setLogTime}
            labels={labels}
          />
        }
      />
      {isLoading ? (
        <p className="ch-meta">{tc("loading")}</p>
      ) : (
        <div className="ch-list">
          {(entries ?? []).length === 0 ? (
            <div className="ch-empty">
              <p>{t("log.noNotes")}</p>
            </div>
          ) : (
            (entries ?? []).map((entry) => (
              <div key={entry.id} className="ch-row">
                {editingEntryId === entry.id ? (
                  <>
                    <textarea
                      autoFocus
                      value={editDraft}
                      onChange={(event) => setEditDraft(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Escape") setEditingEntryId(null);
                      }}
                      rows={3}
                      className="ch-textarea ch-log-edit-textarea"
                    />
                    <LogTimeEditor
                      value={editTimeDraft}
                      onChange={setEditTimeDraft}
                      labels={labels}
                    />
                    <div className="ch-dialog-actions ch-log-edit-actions">
                      <button
                        className="ch-btn ch-btn-primary ch-btn-sm"
                        onClick={() => {
                          const text = editDraft.trim();
                          const time = logTimePayload(editTimeDraft);
                          if (!text && !time) return;
                          updateEntry.mutate(
                            {
                              id: entry.id,
                              data: {
                                body: text,
                                ...(time ? { time } : {}),
                                removeTime:
                                  entry.time != null &&
                                  editTimeDraft.mode === "none",
                              },
                            },
                            {
                              onSuccess: () => {
                                invalidate();
                                setEditingEntryId(null);
                              },
                            },
                          );
                        }}
                        disabled={updateEntry.isPending}
                      >
                        {tc("actions.save")}
                      </button>
                      <button
                        className="ch-btn ch-btn-sm"
                        onClick={() => setEditingEntryId(null)}
                      >
                        {tc("actions.cancel")}
                      </button>
                    </div>
                  </>
                ) : (
                  <>
                    {entry.body && (
                      <div
                        className="ch-editable-log"
                        onClick={() => startEditing(entry)}
                      >
                        <Markdown>{entry.body}</Markdown>
                      </div>
                    )}
                    {entry.time && (
                      <div className="ch-time-chip ch-log-time-chip">
                        {formatDuration(entry.time.durationSec)}
                        {entry.time.inputMode === "range" &&
                          ` · ${new Date(entry.time.startedAt).toLocaleString()} – ${new Date(entry.time.endedAt).toLocaleTimeString()}`}
                      </div>
                    )}
                    <div className="ch-log-footer">
                      <span className="ch-meta">
                        {timeAgo(entry.createdAt, i18n.language)}
                      </span>
                      <span className="ch-dialog-spacer" />
                      <button
                        className="ch-btn ch-btn-ghost ch-btn-sm"
                        onClick={() => startEditing(entry)}
                      >
                        {tc("actions.edit")}
                      </button>
                      <button
                        className="ch-btn ch-btn-danger ch-btn-sm"
                        onClick={async () => {
                          const confirmed = await confirm({
                            title: tc("confirm.deleteLogEntry"),
                            description: tc("confirm.cannotUndo"),
                            confirmLabel: tc("actions.delete"),
                            variant: "danger",
                          });
                          if (confirmed) {
                            deleteEntry.mutate(
                              { id: entry.id },
                              { onSuccess: invalidate },
                            );
                          }
                        }}
                      >
                        {tc("actions.delete")}
                      </button>
                    </div>
                  </>
                )}
              </div>
            ))
          )}
        </div>
      )}
      <MutationToast message={mutationToast.message} />
    </>
  );
}
