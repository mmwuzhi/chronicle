import { useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import type {
  SearchCaptureItem,
  SearchLogEntryItem,
  SearchTaskItem,
} from "../api";
import { Markdown } from "./Markdown";

const ResultIcon = ({ type }: { type: "capture" | "task" | "log" }) => (
  <span className="s-ico" aria-hidden="true">
    {type === "capture" ? "✦" : type === "task" ? "✓" : "▤"}
  </span>
);

export function SearchCaptureResult({
  capture,
  onClose,
}: {
  capture: SearchCaptureItem;
  onClose: () => void;
}): React.JSX.Element {
  const { t } = useTranslation("common");
  const navigate = useNavigate();
  const [expanded, setExpanded] = useState(false);

  return (
    <div className={`ch-search-result-wrap${expanded ? " expanded" : ""}`}>
      <button className="ch-sresult" onClick={() => setExpanded(!expanded)}>
        <ResultIcon type="capture" />
        <span className="s-body">
          <span className="s-title">{capture.preview || "—"}</span>
          <span className="s-sub">
            {capture.matchedField === "transcript"
              ? t("search.matchedTranscript")
              : capture.classifiedAs}
            {" · "}
            {new Date(capture.createdAt).toLocaleDateString()}
          </span>
        </span>
      </button>
      {expanded && (
        <div className="ch-search-preview">
          <Markdown>{capture.preview}</Markdown>
          <div className="ch-search-preview-meta">
            <span>{capture.source}</span>
            <span>{capture.mediaType}</span>
          </div>
          <button
            className="ch-btn ch-btn-primary ch-btn-sm"
            onClick={() => {
              void navigate({
                to: "/captures/context",
                search: { anchorId: capture.id },
              });
              onClose();
            }}
          >
            {t("search.openInContext")}
          </button>
        </div>
      )}
    </div>
  );
}

export function SearchTaskResult({
  task,
  onClose,
}: {
  task: SearchTaskItem;
  onClose: () => void;
}): React.JSX.Element {
  const navigate = useNavigate();
  return (
    <button
      className="ch-sresult"
      onClick={() => {
        void navigate({
          to: "/tasks/$taskId",
          params: { taskId: task.id },
        });
        onClose();
      }}
    >
      <ResultIcon type="task" />
      <span className="s-body">
        <span className="s-title">{task.title}</span>
        <span className="s-sub">{task.status}</span>
      </span>
    </button>
  );
}

export function SearchLogResult({
  entry,
  onClose,
}: {
  entry: SearchLogEntryItem;
  onClose: () => void;
}): React.JSX.Element {
  const { t } = useTranslation("common");
  const navigate = useNavigate();
  const [expanded, setExpanded] = useState(false);
  const taskId = entry.taskId;
  return (
    <div className={`ch-search-result-wrap${expanded ? " expanded" : ""}`}>
      <button className="ch-sresult" onClick={() => setExpanded(!expanded)}>
        <ResultIcon type="log" />
        <span className="s-body">
          <span className="s-title">{entry.preview}</span>
          <span className="s-sub">
            {new Date(entry.createdAt).toLocaleDateString()}
          </span>
        </span>
      </button>
      {expanded && (
        <div className="ch-search-preview">
          <Markdown>{entry.preview}</Markdown>
          {taskId && (
            <button
              className="ch-btn ch-btn-sm"
              onClick={() => {
                void navigate({
                  to: "/tasks/$taskId",
                  params: { taskId },
                });
                onClose();
              }}
            >
              {t("search.openTask")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
