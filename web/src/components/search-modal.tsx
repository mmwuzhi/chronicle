import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useListCapturePage, useListTasks, useSearch } from "../api";
import type { CaptureBody, TaskBody } from "../api";
import {
  SearchCaptureResult,
  SearchLogResult,
  SearchTaskResult,
} from "./SearchResults";

const SearchIcon = () => (
  <svg
    width="18"
    height="18"
    fill="none"
    stroke="currentColor"
    strokeWidth={2}
    viewBox="0 0 24 24"
  >
    <circle cx="11" cy="11" r="8" />
    <path d="m21 21-4.35-4.35" />
  </svg>
);

export function SearchModal({
  onClose,
}: {
  onClose: () => void;
}): React.JSX.Element {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const { data: recentTasks } = useListTasks();
  const { data: recentCapturePage } = useListCapturePage({ limit: 4 });
  const searchQuery = useSearch(
    { q: debouncedQuery },
    { query: { enabled: debouncedQuery.length > 0 } },
  );
  const captures = searchQuery.data?.captures ?? [];
  const tasks = searchQuery.data?.tasks ?? [];
  const logs = searchQuery.data?.logEntries ?? [];
  const hasResults = captures.length + tasks.length + logs.length > 0;

  useEffect(() => inputRef.current?.focus(), []);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim()), 300);
    return () => window.clearTimeout(timer);
  }, [query]);
  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [onClose]);

  const recentTaskItems = (recentTasks ?? [])
    .filter((task: TaskBody) => task.status !== "archived")
    .slice(0, 4);
  const recentCaptures = recentCapturePage?.items ?? [];

  return (
    <div className="ch-searchwrap">
      <div className="scrim" onMouseDown={onClose} />
      <div className="ch-searchpanel">
        <div className="ch-searchbar">
          <SearchIcon />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("search.placeholder")}
          />
          {searchQuery.isFetching && <span className="ch-meta">…</span>}
          <kbd>Esc</kbd>
          <button className="s-cancel" onClick={onClose}>
            {t("actions.cancel")}
          </button>
        </div>
        <div className="ch-searchresults">
          {debouncedQuery && !searchQuery.isFetching && !hasResults && (
            <div className="ch-empty ch-search-empty">
              <p>{t("search.noResults")}</p>
            </div>
          )}
          {!debouncedQuery && (
            <>
              {recentTaskItems.length > 0 && (
                <>
                  <div className="ch-sgroup">{t("search.recentTasks")}</div>
                  {recentTaskItems.map((task) => (
                    <button
                      key={task.id}
                      className="ch-sresult"
                      onClick={() => {
                        void navigate({
                          to: "/tasks/$taskId",
                          params: { taskId: task.id },
                        });
                        onClose();
                      }}
                    >
                      <span className="s-ico">✓</span>
                      <span className="s-body">
                        <span className="s-title">{task.title}</span>
                        <span className="s-sub">{task.status}</span>
                      </span>
                    </button>
                  ))}
                </>
              )}
              {recentCaptures.length > 0 && (
                <>
                  <div className="ch-sgroup">{t("search.recentCaptures")}</div>
                  {recentCaptures.map((capture: CaptureBody) => (
                    <button
                      key={capture.id}
                      className="ch-sresult"
                      onClick={() => {
                        void navigate({
                          to: "/captures/context",
                          search: { anchorId: capture.id },
                        });
                        onClose();
                      }}
                    >
                      <span className="s-ico">✦</span>
                      <span className="s-body">
                        <span className="s-title">
                          {capture.rawText ?? capture.transcript ?? "—"}
                        </span>
                        <span className="s-sub">
                          {new Date(capture.createdAt).toLocaleDateString()}
                        </span>
                      </span>
                    </button>
                  ))}
                </>
              )}
              {recentTaskItems.length === 0 && recentCaptures.length === 0 && (
                <div className="ch-empty ch-search-empty">
                  <p>{t("search.typeToSearch")}</p>
                </div>
              )}
            </>
          )}
          {tasks.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.tasks")}</div>
              {tasks.map((task) => (
                <SearchTaskResult key={task.id} task={task} onClose={onClose} />
              ))}
            </>
          )}
          {captures.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.captures")}</div>
              {captures.map((capture) => (
                <SearchCaptureResult
                  key={capture.id}
                  capture={capture}
                  onClose={onClose}
                />
              ))}
            </>
          )}
          {logs.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.logEntries")}</div>
              {logs.map((entry) => (
                <SearchLogResult
                  key={entry.id}
                  entry={entry}
                  onClose={onClose}
                />
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
